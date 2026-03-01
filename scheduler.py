"""
APScheduler integration.

Two separate job pools:
  • Manual substitute-plan jobs  — stored in DB jobs table, shown in UI
  • Timetable reminder jobs      — ephemeral APScheduler jobs rebuilt from
                                   stored timetable on startup / after sync
"""
import re
import logging
from datetime import datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

import database as db
import scraper as sc
import notifier as nt

log = logging.getLogger(__name__)

_scheduler: BackgroundScheduler | None = None

# APScheduler day_of_week: 0 = Monday, …, 6 = Sunday
_DOW = {"Montag": 0, "Dienstag": 1, "Mittwoch": 2, "Donnerstag": 3, "Freitag": 4}
_REMINDER_ID_PREFIX = "reminder_"


# ── Startup / shutdown ────────────────────────────────────────────────────────

def start_scheduler():
    global _scheduler
    _scheduler = BackgroundScheduler(timezone="Europe/Berlin")
    _scheduler.start()
    _reload_jobs()

    # Weekly timetable auto-sync — every Sunday at 18:00
    _scheduler.add_job(
        sync_timetable,
        CronTrigger(day_of_week=6, hour=18, minute=0, timezone="Europe/Berlin"),
        id="timetable_weekly_sync",
        name="Wöchentliche Stundenplan-Sync",
        replace_existing=True,
    )

    # Load timetable from DB and schedule reminders if enabled
    stored = db.get_timetable()
    if stored:
        _schedule_timetable_reminders(stored["timetable"])

    log.info("Scheduler started")


def stop_scheduler():
    if _scheduler:
        _scheduler.shutdown(wait=False)


# ── Manual substitute-plan jobs ───────────────────────────────────────────────

def _reload_jobs():
    if not _scheduler:
        return
    # Only remove manual jobs (keep reminder + timetable-sync jobs)
    for job in _scheduler.get_jobs():
        if not job.id.startswith(_REMINDER_ID_PREFIX) and job.id != "timetable_weekly_sync":
            job.remove()
    for job in db.list_jobs():
        if job["enabled"]:
            _add_aps_job(job)


def _add_aps_job(job: dict):
    parts = job["cron"].split()
    if len(parts) != 5:
        log.warning("Invalid cron for job %s: %s", job["id"], job["cron"])
        return
    minute, hour, day, month, dow = parts
    _scheduler.add_job(
        _run_scrape,
        CronTrigger(minute=minute, hour=hour, day=day, month=month,
                    day_of_week=dow, timezone="Europe/Berlin"),
        id=str(job["id"]),
        name=job["name"],
        kwargs={"job_id": job["id"]},
        replace_existing=True,
    )


def reload_jobs():
    _reload_jobs()


def _run_scrape(job_id: int | None = None):
    """Core scrape-and-notify task."""
    settings = db.get_settings()
    missing = [k for k in ("base_url", "username", "password") if not settings.get(k)]
    has_discord = bool(settings.get("webhook_url"))
    has_gotify  = bool(settings.get("gotify_url")) and bool(settings.get("gotify_token"))
    if not has_discord and not has_gotify:
        missing.append("webhook_url or gotify_url+gotify_token")

    if missing:
        msg = f"Missing settings: {', '.join(missing)}"
        log.warning(msg)
        db.add_log("error", msg, job_id)
        return {"status": "error", "message": msg}

    include_empty = settings.get("notify_empty", "false").lower() == "true"

    try:
        s = sc.ElternPortalScraper(settings["base_url"], settings["username"], settings["password"])
        s.login()
        plan = s.get_substitute_plan()

        sent_to: list[str] = []
        if has_discord:
            nt.send_to_discord(settings["webhook_url"], plan, include_empty)
            sent_to.append("Discord")
        if has_gotify:
            nt.send_to_gotify(settings["gotify_url"], settings["gotify_token"],
                              plan, int(settings.get("gotify_priority") or 5), include_empty)
            sent_to.append("Gotify")

        msg = (f"Sent to {', '.join(sent_to)} — "
               f"class {plan.get('class_name','?')}, {len(plan.get('days',[]))} days")
        log.info(msg)
        db.add_log("success", msg, job_id)
        return {"status": "success", "message": msg, "plan": plan}
    except Exception as e:
        msg = str(e)
        log.error("Scrape failed: %s", msg)
        db.add_log("error", msg, job_id)
        return {"status": "error", "message": msg}


def run_now() -> dict:
    return _run_scrape(job_id=None)


# ── Timetable reminders ───────────────────────────────────────────────────────

def _parse_reminder_slots(timetable: dict) -> list[dict]:
    """Flatten timetable into (day, dow, period, notify_hour, notify_min, subject, room)."""
    days  = timetable.get("days", [])
    slots = timetable.get("slots", [])
    result = []

    for slot in slots:
        period     = slot.get("period", 0)
        start_time = slot.get("start_time", "")
        if not period or not start_time:
            continue

        # Parse start time "08:10" and subtract 5 min
        try:
            h, m = map(int, start_time.split(":"))
            t = datetime(2000, 1, 1, h, m) - timedelta(minutes=5)
            notify_h, notify_m = t.hour, t.minute
        except ValueError:
            continue

        for day_idx, cell in enumerate(slot.get("cells", [])):
            if day_idx >= len(days):
                break
            day_name = days[day_idx]
            dow = _DOW.get(day_name)
            if dow is None:
                continue

            subject = cell.get("subject", "") if isinstance(cell, dict) else str(cell)
            room    = cell.get("room", "")    if isinstance(cell, dict) else ""
            if not subject:
                continue

            result.append({
                "day":      day_name,
                "dow":      dow,
                "period":   period,
                "notify_h": notify_h,
                "notify_m": notify_m,
                "subject":  subject,
                "room":     room,
            })

    return result


def _schedule_timetable_reminders(timetable: dict):
    """Clear all reminder jobs and rebuild from timetable if reminders are enabled."""
    if not _scheduler:
        return

    # Always clear existing reminder jobs first
    for job in list(_scheduler.get_jobs()):
        if job.id.startswith(_REMINDER_ID_PREFIX):
            job.remove()

    settings = db.get_settings()
    if settings.get("reminders_enabled", "false").lower() != "true":
        log.info("Timetable reminders disabled")
        return
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        log.warning("Gotify not configured — cannot schedule reminders")
        return

    slots = _parse_reminder_slots(timetable)
    count = 0
    for r in slots:
        job_id = f"{_REMINDER_ID_PREFIX}{r['dow']}_{r['period']}"
        _scheduler.add_job(
            _fire_class_reminder,
            CronTrigger(
                minute=r["notify_m"], hour=r["notify_h"],
                day_of_week=r["dow"], timezone="Europe/Berlin",
            ),
            id=job_id,
            name=f"{r['day']} · {r['period']}. Std · {r['subject']}",
            kwargs={k: r[k] for k in ("day", "period", "subject", "room")},
            replace_existing=True,
        )
        count += 1

    log.info("Scheduled %d class reminder jobs", count)


def _fire_class_reminder(day: str, period: int, subject: str, room: str):
    settings = db.get_settings()
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        return
    try:
        nt.send_class_reminder(
            settings["gotify_url"], settings["gotify_token"],
            subject=subject, room=room, day=day, period=period,
            priority=int(settings.get("reminder_priority") or 7),
        )
    except Exception as e:
        log.error("Class reminder failed (%s %s. Std): %s", day, period, e)


# ── Timetable sync ────────────────────────────────────────────────────────────

def sync_timetable() -> dict:
    """Fetch the timetable from the portal, store it, reschedule reminders."""
    settings = db.get_settings()
    missing = [k for k in ("base_url", "username", "password") if not settings.get(k)]
    if missing:
        msg = f"Missing settings: {', '.join(missing)}"
        db.add_log("error", msg)
        return {"status": "error", "message": msg}

    try:
        s = sc.ElternPortalScraper(settings["base_url"], settings["username"], settings["password"])
        s.login()
        timetable = s.get_timetable()
        db.save_timetable(timetable)
        _schedule_timetable_reminders(timetable)

        slot_count = sum(
            1 for slot in timetable.get("slots", [])
            for c in slot.get("cells", [])
            if (c.get("subject") if isinstance(c, dict) else c)
        )
        msg = f"Stundenplan synchronisiert — {slot_count} Stunden gefunden"
        db.add_log("success", msg)
        log.info(msg)
        return {"status": "success", "message": msg, "timetable": timetable}
    except Exception as e:
        msg = str(e)
        db.add_log("error", f"Stundenplan-Sync fehlgeschlagen: {msg}")
        log.error("Timetable sync failed: %s", msg)
        return {"status": "error", "message": msg}


def test_class_reminder() -> dict:
    """Fire a one-off class reminder using the first non-empty timetable slot."""
    settings = db.get_settings()
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        return {"status": "error", "message": "Gotify nicht konfiguriert"}

    stored = db.get_timetable()
    if not stored:
        return {"status": "error", "message": "Kein Stundenplan gespeichert – bitte zuerst synchronisieren"}

    tt = stored["timetable"]
    days  = tt.get("days", [])
    slots = tt.get("slots", [])

    # Find first non-empty cell
    sample = None
    for slot in slots:
        for idx, cell in enumerate(slot.get("cells", [])):
            subj = cell.get("subject", "") if isinstance(cell, dict) else str(cell)
            room = cell.get("room", "")    if isinstance(cell, dict) else ""
            if subj and idx < len(days):
                sample = {
                    "day":    days[idx],
                    "period": slot["period"],
                    "subject": subj,
                    "room":   room,
                }
                break
        if sample:
            break

    if not sample:
        return {"status": "error", "message": "Keine Stunden im Stundenplan gefunden"}

    try:
        nt.send_class_reminder(
            settings["gotify_url"], settings["gotify_token"],
            subject=sample["subject"], room=sample["room"],
            day=sample["day"], period=sample["period"],
            priority=int(settings.get("reminder_priority") or 7),
        )
        return {"status": "success", "message": f"Test-Erinnerung gesendet: {sample['subject']} · {sample['day']} {sample['period']}. Std"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def get_reminder_jobs() -> list[dict]:
    """Return currently scheduled reminder jobs for display in UI."""
    if not _scheduler:
        return []
    return [
        {
            "id":   job.id,
            "name": job.name,
            "next": job.next_run_time.isoformat() if job.next_run_time else None,
        }
        for job in _scheduler.get_jobs()
        if job.id.startswith(_REMINDER_ID_PREFIX)
    ]
