# Copilot Instructions

## Running the App

```bash
./run.sh                        # start server (creates .venv, installs deps, runs uvicorn)
./install.sh                    # interactive installer (port picker + optional systemd setup)
```

The server runs on `http://localhost:8080` by default with `--reload` enabled.

**Install/update dependencies:**
```bash
source .venv/bin/activate
pip install -r requirements.txt
```

There are no automated tests or linters configured.

## Architecture

Five Python modules + one static HTML frontend:

| File | Role |
|---|---|
| `main.py` | FastAPI app — all API routes + WebSocket `/stream` endpoint |
| `scraper.py` | `ElternPortalScraper` — CSRF login, HTML parsing of Vertretungsplan & Stundenplan |
| `notifier.py` | Discord webhook (rich embeds) + Gotify push message builders |
| `scheduler.py` | APScheduler integration — cron jobs + timetable reminders + alarm job |
| `database.py` | SQLite via raw `sqlite3` — settings, jobs, logs, timetable |
| `push.py` | In-process WebSocket manager for the `/stream` endpoint |

The **Flutter app** (`flutter_app/`) is a companion mobile client; it connects to `/stream` using the Gotify-compatible WebSocket protocol.

### Data Flow

1. APScheduler fires a cron job → `scheduler.py` calls `ElternPortalScraper`
2. Scraper logs into Eltern-Portal with CSRF auth, parses HTML with BeautifulSoup
3. Plan hash is compared to last run — only notifies on change
4. On change: `notifier.py` sends to Discord webhook and/or Gotify; `push.py` broadcasts to WebSocket clients
5. After a cron fire, a **burst polling** phase runs: every 1 min for 15 min, then every 5 min for 15 min

### Scheduler Job Pools

There are two distinct job pools in APScheduler:
- **DB-backed jobs** — user-defined cron schedules stored in the `jobs` table, managed via `/api/jobs`
- **Ephemeral reminder jobs** — rebuilt in memory from the stored timetable on every startup/sync; prefixed with `reminder_` in APScheduler

### Settings Storage

All settings are stored as key/value strings in the `settings` SQLite table. The `DEFAULT_SETTINGS` dict in `database.py` defines fallback values. Boolean settings are stored as the string `"true"` / `"false"` — not actual booleans.

The password is masked as `"••••••••"` in GET responses; a `POST /api/settings` with that placeholder value will not overwrite the stored password.

### WebSocket Push (`/stream`)

`push.py`'s `WebSocketManager` is a singleton (`push.manager`). The scheduler runs in a background thread, so it uses `broadcast_sync()` which calls `asyncio.run_coroutine_threadsafe()` to safely push into the async event loop. The event loop reference is stored via `ws_manager.set_loop(...)` in the FastAPI lifespan.

## Key Conventions

- **Subject abbreviations** are mapped in `notifier.SUBJECT_NAMES` (e.g. `"D"` → `"Deutsch"`). Add new subjects there.
- **Alarm notifications** use the title format `"⏰ Wecker: HH:MM"` — this is intentional; the Flutter/Tasker integration regex-matches on this exact string.
- **Timetable** is stored as a single JSON blob in the `timetable` table (id=1, always upserted).
- The scraper targets `div#asam_content` as the main content wrapper; fall back to full `soup` if absent.
- Cron strings are standard 5-field format (`minute hour day month weekday`); validated at the API layer.
- Timezone is hardcoded to `"Europe/Berlin"` in the scheduler.
