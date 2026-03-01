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
_DOW_TO_NAME = {v: k for k, v in _DOW.items()}
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

    # Schedule nightly alarm notification
    _schedule_alarm_job()

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

        # Check if early periods are cancelled and adjust alarm accordingly
        _check_alarm_adjustment(plan)

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


# ── Alarm notification ────────────────────────────────────────────────────────

_GERMAN_DAYS = ["Montag","Dienstag","Mittwoch","Donnerstag","Freitag","Samstag","Sonntag"]


def _parse_periods(period_str: str) -> list[int]:
    """Parse period string to list of ints: '1' → [1], '1-2' → [1,2]."""
    nums = re.findall(r'\d+', str(period_str))
    if len(nums) >= 2:
        return list(range(int(nums[0]), int(nums[-1]) + 1))
    return [int(nums[0])] if nums else []


def _check_alarm_adjustment(plan: dict):
    """After a scrape, check if today's early periods are cancelled and
    send an adjusted alarm push so Tasker can update the alarm in real time."""
    settings = db.get_settings()
    if settings.get("alarm_enabled", "false").lower() != "true":
        return
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        return

    stored = db.get_timetable()
    if not stored:
        return

    tt   = stored["timetable"]
    days = tt.get("days", [])

    today_wd   = datetime.now().weekday()   # 0=Mon … 4=Fri
    today_name = _GERMAN_DAYS[today_wd]
    if today_wd >= 5 or today_name not in days:
        return
    day_idx = days.index(today_name)

    # Collect cancelled periods from today's substitute plan entries
    cancelled: set[int] = set()
    for day in plan.get("days", []):
        label = day.get("date", "")
        # Match by weekday name in the label (e.g. "Donnerstag, 28.02.2026")
        if today_name.lower() not in label.lower():
            continue
        for entry in day.get("entries", []):
            if entry.get("empty"):
                continue
            info = entry.get("info", "")
            emoji, _color = nt._classify(info)
            if emoji == "🚫":
                for p in _parse_periods(entry.get("period", "")):
                    cancelled.add(p)

    if not cancelled:
        return  # nothing changed for early periods

    # Find first non-cancelled period from timetable for today
    slots_today = []
    for slot in sorted(tt.get("slots", []), key=lambda s: s.get("period", 99)):
        cells = slot.get("cells", [])
        if day_idx >= len(cells):
            continue
        cell    = cells[day_idx]
        subject = cell.get("subject", "") if isinstance(cell, dict) else str(cell)
        if not subject:
            continue
        slots_today.append({
            "period":     slot["period"],
            "start_time": slot.get("start_time", ""),
            "subject":    subject,
            "room":       cell.get("room", "") if isinstance(cell, dict) else "",
        })

    if not slots_today:
        return

    # Skip cancelled periods to find effective first class
    skipped = [s["period"] for s in slots_today if s["period"] in cancelled]
    effective = next((s for s in slots_today if s["period"] not in cancelled), None)
    if not effective or not skipped:
        return  # no change or everything cancelled

    # Calculate adjusted alarm time
    try:
        h, m = map(int, effective["start_time"].split(":"))
        offset = int(settings.get("alarm_offset") or 45)
        t = datetime(2000, 1, 1, h, m) - timedelta(minutes=offset)
        alarm_time = f"{t.hour:02d}:{t.minute:02d}"
    except ValueError:
        return

    try:
        nt.send_alarm_adjustment(
            settings["gotify_url"], settings["gotify_token"],
            alarm_time=alarm_time,
            skipped_periods=skipped,
            first_class=effective,
            priority=int(settings.get("alarm_priority") or 9),
        )
        log.info("Alarm adjusted to %s (skipped periods: %s)", alarm_time, skipped)
    except Exception as e:
        log.error("Alarm adjustment failed: %s", e)


def _get_next_school_day_first_class() -> dict | None:
    """Return the first non-empty class for the next school day (Mon–Fri)."""
    stored = db.get_timetable()
    if not stored:
        return None
    tt    = stored["timetable"]
    days  = tt.get("days", [])
    slots = tt.get("slots", [])

    now = datetime.now()
    for delta in range(1, 8):
        candidate = now + timedelta(days=delta)
        wd = candidate.weekday()        # 0=Mon … 6=Sun
        if wd >= 5:
            continue
        day_name = _DOW_TO_NAME.get(wd)
        if not day_name or day_name not in days:
            continue
        day_idx = days.index(day_name)
        for slot in sorted(slots, key=lambda s: s.get("period", 99)):
            cells = slot.get("cells", [])
            if day_idx >= len(cells):
                continue
            cell = cells[day_idx]
            subj = cell.get("subject", "") if isinstance(cell, dict) else str(cell)
            room = cell.get("room", "")    if isinstance(cell, dict) else ""
            if subj:
                return {
                    "day":        day_name,
                    "period":     slot["period"],
                    "start_time": slot.get("start_time", ""),
                    "subject":    subj,
                    "room":       room,
                }
        break
    return None


def _fire_alarm_notification():
    settings = db.get_settings()
    if settings.get("alarm_enabled", "false").lower() != "true":
        return
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        log.warning("Alarm notification: Gotify not configured")
        return

    first = _get_next_school_day_first_class()
    if not first or not first["start_time"]:
        log.info("Alarm notification: no class found for next school day")
        return

    try:
        h, m = map(int, first["start_time"].split(":"))
        offset = int(settings.get("alarm_offset") or 45)
        t = datetime(2000, 1, 1, h, m) - timedelta(minutes=offset)
        alarm_time = f"{t.hour:02d}:{t.minute:02d}"
    except ValueError:
        log.error("Alarm notification: could not parse start_time %s", first["start_time"])
        return

    try:
        nt.send_alarm_notification(
            settings["gotify_url"], settings["gotify_token"],
            alarm_time=alarm_time,
            subject=first["subject"], room=first["room"],
            day=first["day"], period=first["period"],
            priority=int(settings.get("alarm_priority") or 9),
        )
        log.info("Alarm notification sent: %s for %s", alarm_time, first["day"])
    except Exception as e:
        log.error("Alarm notification failed: %s", e)


def _schedule_alarm_job(settings: dict | None = None):
    if not _scheduler:
        return
    if settings is None:
        settings = db.get_settings()
    send_time = settings.get("alarm_send_time", "22:00")
    try:
        sh, sm = map(int, send_time.split(":"))
    except ValueError:
        sh, sm = 22, 0
    _scheduler.add_job(
        _fire_alarm_notification,
        CronTrigger(hour=sh, minute=sm, day_of_week="0-4", timezone="Europe/Berlin"),
        id="alarm_nightly",
        name=f"Wecker-Benachrichtigung ({send_time} Uhr)",
        replace_existing=True,
    )
    log.info("Alarm job scheduled at %s", send_time)


def test_alarm_notification() -> dict:
    settings = db.get_settings()
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        return {"status": "error", "message": "Gotify nicht konfiguriert"}
    first = _get_next_school_day_first_class()
    if not first:
        return {"status": "error", "message": "Kein Stundenplan / keine Stunden für morgen"}
    try:
        h, m = map(int, (first["start_time"] or "08:00").split(":"))
        offset = int(settings.get("alarm_offset") or 45)
        t = datetime(2000, 1, 1, h, m) - timedelta(minutes=offset)
        alarm_time = f"{t.hour:02d}:{t.minute:02d}"
        nt.send_alarm_notification(
            settings["gotify_url"], settings["gotify_token"],
            alarm_time=alarm_time,
            subject=first["subject"], room=first["room"],
            day=first["day"], period=first["period"],
            priority=int(settings.get("alarm_priority") or 9),
        )
        return {"status": "success", "message": f"Test-Wecker gesendet: {alarm_time} Uhr ({first['day']})"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def simulate_alarm_adjustment(cancel_periods: list[int]) -> dict:
    """Simulate N cancelled periods and send the adjusted alarm notification."""
    settings = db.get_settings()
    if not settings.get("gotify_url") or not settings.get("gotify_token"):
        return {"status": "error", "message": "Gotify nicht konfiguriert"}

    stored = db.get_timetable()
    if not stored:
        return {"status": "error", "message": "Kein Stundenplan – bitte zuerst synchronisieren"}

    tt   = stored["timetable"]
    days = tt.get("days", [])

    # Use next school day for simulation
    first = _get_next_school_day_first_class()
    if not first:
        return {"status": "error", "message": "Keine Stunden im Stundenplan"}

    day_name = first["day"]
    if day_name not in days:
        return {"status": "error", "message": f"Tag '{day_name}' nicht im Stundenplan"}
    day_idx = days.index(day_name)

    cancelled = set(cancel_periods)

    # Collect all slots for that day, sorted by period
    slots_day = []
    for slot in sorted(tt.get("slots", []), key=lambda s: s.get("period", 99)):
        cells = slot.get("cells", [])
        if day_idx >= len(cells):
            continue
        cell = cells[day_idx]
        subj = cell.get("subject", "") if isinstance(cell, dict) else str(cell)
        if not subj:
            continue
        slots_day.append({
            "period":     slot["period"],
            "start_time": slot.get("start_time", ""),
            "subject":    subj,
            "room":       cell.get("room", "") if isinstance(cell, dict) else "",
            "day":        day_name,
        })

    if not slots_day:
        return {"status": "error", "message": "Keine Stunden für diesen Tag"}

    effective = next((s for s in slots_day if s["period"] not in cancelled), None)
    if not effective:
        return {"status": "error", "message": "Alle Stunden wären entfallen – kein Wecker möglich"}

    skipped = [s["period"] for s in slots_day if s["period"] in cancelled]
    if not skipped:
        return {"status": "error", "message": "Keine der simulierten Stunden existiert im Stundenplan"}

    try:
        h, m = map(int, (effective["start_time"] or "08:00").split(":"))
        offset = int(settings.get("alarm_offset") or 45)
        t = datetime(2000, 1, 1, h, m) - timedelta(minutes=offset)
        alarm_time = f"{t.hour:02d}:{t.minute:02d}"
        nt.send_alarm_adjustment(
            settings["gotify_url"], settings["gotify_token"],
            alarm_time=alarm_time,
            skipped_periods=skipped,
            first_class=effective,
            priority=int(settings.get("alarm_priority") or 9),
        )
        label = f"Std. {', '.join(str(p) for p in sorted(skipped))} entfallen"
        return {
            "status": "success",
            "message": f"Simulation: {label} → Wecker auf {alarm_time} Uhr angepasst ({effective['subject']})",
            "alarm_time": alarm_time,
            "skipped": skipped,
            "first_class": effective,
        }
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
