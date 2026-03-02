"""
FastAPI backend for the Eltern-Portal substitute plan scraper.
Serves the frontend and exposes a JSON API.
"""
import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Query
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel

import database as db
import scheduler as sched
from push import manager as ws_manager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s – %(message)s",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    ws_manager.set_loop(asyncio.get_event_loop())
    sched.start_scheduler()
    yield
    sched.stop_scheduler()


app = FastAPI(title="Vertretungsplan Scraper", lifespan=lifespan)

# Serve static frontend
static_dir = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.get("/", include_in_schema=False)
async def root():
    return FileResponse(static_dir / "index.html")


# ── Settings ──────────────────────────────────────────────────────────────────

class SettingsIn(BaseModel):
    base_url:          str = ""
    username:          str = ""
    password:          str = ""
    webhook_url:       str = ""
    gotify_url:        str = ""
    gotify_token:      str = ""
    gotify_priority:   str = "5"
    push_token:        str = ""
    notify_empty:      str = "false"
    reminders_enabled: str = "false"
    reminder_priority: str = "7"
    alarm_enabled:     str = "false"
    alarm_offset:      str = "45"
    alarm_send_time:   str = "22:00"
    alarm_priority:    str = "9"


@app.get("/api/settings")
def get_settings():
    s = db.get_settings()
    # Mask password in response
    if s.get("password"):
        s["password"] = "••••••••"
    return s


@app.post("/api/settings")
def save_settings(body: SettingsIn):
    data = body.model_dump()
    # Don't overwrite password if placeholder was sent back
    if data.get("password") == "••••••••":
        data.pop("password")
    db.save_settings(data)
    sched.reload_jobs()
    # Re-apply reminder schedule when gotify/reminders settings change
    stored = db.get_timetable()
    if stored:
        sched._schedule_timetable_reminders(stored["timetable"])
    sched._schedule_alarm_job()
    return {"ok": True}


# ── Jobs ──────────────────────────────────────────────────────────────────────

class JobIn(BaseModel):
    name: str
    cron: str  # standard 5-part cron: "0 7 * * 1-5"


class JobToggle(BaseModel):
    enabled: bool


@app.get("/api/jobs")
def list_jobs():
    return db.list_jobs()


@app.post("/api/jobs")
def create_job(body: JobIn):
    # Validate cron format
    if len(body.cron.split()) != 5:
        raise HTTPException(400, "cron must have 5 fields: minute hour day month weekday")
    job = db.create_job(body.name, body.cron)
    sched.reload_jobs()
    return job


@app.patch("/api/jobs/{job_id}")
def toggle_job(job_id: int, body: JobToggle):
    db.update_job(job_id, body.enabled)
    sched.reload_jobs()
    return {"ok": True}


@app.delete("/api/jobs/{job_id}")
def remove_job(job_id: int):
    db.delete_job(job_id)
    sched.reload_jobs()
    return {"ok": True}


# ── Manual trigger ────────────────────────────────────────────────────────────

@app.post("/api/scrape/run")
def run_scrape():
    result = sched.run_now()
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


# ── Logs ──────────────────────────────────────────────────────────────────────

@app.get("/api/logs")
def get_logs(limit: int = 50):
    return db.get_logs(limit)


# ── Timetable / class reminders ───────────────────────────────────────────────

@app.post("/api/timetable/sync")
def sync_timetable():
    result = sched.sync_timetable()
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


@app.post("/api/timetable/test-reminder")
def test_reminder():
    result = sched.test_class_reminder()
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


@app.post("/api/timetable/test-alarm")
def test_alarm():
    result = sched.test_alarm_notification()
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


class SimulateIn(BaseModel):
    cancel_periods: list[int] = [1]


class CustomAlarmIn(BaseModel):
    hour: int
    minute: int


@app.post("/api/test/alarm")
def test_custom_alarm(body: CustomAlarmIn):
    result = sched.send_custom_alarm(body.hour, body.minute)
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


@app.post("/api/timetable/simulate-adjustment")
def simulate_adjustment(body: SimulateIn):
    result = sched.simulate_alarm_adjustment(body.cancel_periods)
    if result["status"] == "error":
        raise HTTPException(500, result["message"])
    return result


@app.get("/api/timetable")
def get_timetable():
    stored = db.get_timetable()
    settings = db.get_settings()
    return {
        "timetable":        stored["timetable"] if stored else None,
        "last_sync":        stored["updated"]   if stored else None,
        "reminders_enabled": settings.get("reminders_enabled", "false"),
        "reminder_priority": settings.get("reminder_priority", "7"),
        "reminder_jobs":    sched.get_reminder_jobs(),
    }


# ── Built-in push stream (Gotify-compatible WebSocket) ────────────────────────

@app.websocket("/stream")
async def push_stream(ws: WebSocket, token: str = Query(default="")):
    settings = db.get_settings()
    push_token = settings.get("push_token", "")
    if push_token and token != push_token:
        await ws.close(code=4001)
        return
    await ws_manager.connect(ws)
    try:
        while True:
            await ws.receive_text()   # keep connection alive, ignore client messages
    except WebSocketDisconnect:
        pass
    finally:
        ws_manager.disconnect(ws)
