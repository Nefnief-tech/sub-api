import sqlite3
import json
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).parent / "data.db"


def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_conn()
    cur = conn.cursor()
    cur.executescript("""
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS timetable (
            id      INTEGER PRIMARY KEY CHECK (id = 1),
            data    TEXT NOT NULL,
            updated TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS jobs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT NOT NULL,
            cron        TEXT NOT NULL,
            enabled     INTEGER NOT NULL DEFAULT 1,
            created_at  TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS logs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id      INTEGER,
            status      TEXT NOT NULL,
            message     TEXT,
            created_at  TEXT DEFAULT (datetime('now'))
        );
    """)
    conn.commit()
    conn.close()


# --- Settings ---

DEFAULT_SETTINGS = {
    "base_url": "",
    "username": "",
    "password": "",
    "webhook_url": "",
    "gotify_url": "",
    "gotify_token": "",
    "gotify_priority": "5",
    "reminders_enabled": "false",
    "reminder_priority": "7",
    "notify_empty": "false",
}


def get_settings() -> dict:
    conn = get_conn()
    rows = conn.execute("SELECT key, value FROM settings").fetchall()
    conn.close()
    result = dict(DEFAULT_SETTINGS)
    for row in rows:
        result[row["key"]] = row["value"]
    return result


def save_settings(data: dict):
    conn = get_conn()
    for k, v in data.items():
        conn.execute(
            "INSERT INTO settings(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (k, str(v)),
        )
    conn.commit()
    conn.close()


# --- Jobs ---

def list_jobs() -> list[dict]:
    conn = get_conn()
    rows = conn.execute("SELECT * FROM jobs ORDER BY id").fetchall()
    conn.close()
    return [dict(r) for r in rows]


def create_job(name: str, cron: str) -> dict:
    conn = get_conn()
    cur = conn.execute("INSERT INTO jobs(name, cron) VALUES(?,?)", (name, cron))
    conn.commit()
    job_id = cur.lastrowid
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    conn.close()
    return dict(row)


def update_job(job_id: int, enabled: bool):
    conn = get_conn()
    conn.execute("UPDATE jobs SET enabled=? WHERE id=?", (1 if enabled else 0, job_id))
    conn.commit()
    conn.close()


def delete_job(job_id: int):
    conn = get_conn()
    conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))
    conn.commit()
    conn.close()


# --- Logs ---

def add_log(status: str, message: str, job_id: int | None = None):
    conn = get_conn()
    conn.execute(
        "INSERT INTO logs(job_id, status, message) VALUES(?,?,?)",
        (job_id, status, message),
    )
    conn.commit()
    conn.close()


def get_logs(limit: int = 50) -> list[dict]:
    conn = get_conn()
    rows = conn.execute(
        "SELECT * FROM logs ORDER BY id DESC LIMIT ?", (limit,)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


# ── Timetable ─────────────────────────────────────────────────────────────────

def get_timetable() -> dict | None:
    conn = get_conn()
    row = conn.execute("SELECT data, updated FROM timetable WHERE id=1").fetchone()
    conn.close()
    if not row:
        return None
    return {"timetable": json.loads(row["data"]), "updated": row["updated"]}


def save_timetable(data: dict):
    conn = get_conn()
    conn.execute(
        "INSERT INTO timetable(id, data, updated) VALUES(1,?,datetime('now'))"
        " ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated=excluded.updated",
        (json.dumps(data),),
    )
    conn.commit()
    conn.close()
