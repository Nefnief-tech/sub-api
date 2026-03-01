# 📋 Vertretungsplan Scraper

A web scraper for the **Eltern-Portal** school substitute plan, with a dark web UI, Discord/Gotify notifications, cron job scheduling, and timetable-based class reminders.

## Features

- 🔐 **Automatic login** — handles CSRF-protected Eltern-Portal authentication
- 📣 **Discord webhooks** — rich multi-embed messages with color-coded per-day cards
- 🔔 **Gotify notifications** — markdown-formatted substitute plan + class reminders
- ⏰ **Class reminders** — Gotify push 5 minutes before each class (based on your timetable)
- 🗓 **Timetable sync** — fetches & stores your weekly schedule, auto-refreshes every Sunday
- 🕐 **Cron scheduler** — APScheduler with configurable jobs via the UI
- 🖥 **Web UI** — dark "Night Ops Console" interface with settings, jobs, logs & timetable tabs

## Setup

### Requirements

```bash
pip install -r requirements.txt
```

### Run

```bash
./run.sh
# or
uvicorn main:app --host 0.0.0.0 --port 8080 --reload
```

Open `http://localhost:8080` in your browser.

## Configuration

All settings are managed through the web UI (**Einstellungen** tab):

| Setting | Description |
|---|---|
| Base URL | Your Eltern-Portal URL (e.g. `https://evbspar.eltern-portal.org/`) |
| Username | Portal login username |
| Password | Portal login password |
| Discord Webhook | Discord webhook URL for substitute plan notifications |
| Gotify URL | Your Gotify server URL |
| Gotify Token | App token from Gotify |
| Gotify Priority | Notification priority (1–10, default 5) |
| Leere Tage melden | Send notification even when no substitutions exist |
| Stunden-Erinnerungen | Enable 5-min class reminders via Gotify |
| Erinnerungs-Priorität | Priority for class reminder notifications (default 7) |

## Timetable Reminders

1. Go to the **📅 Stundenplan** tab
2. Click **Jetzt synchronisieren** to fetch your timetable
3. Enable **Stunden-Erinnerungen** in the Einstellungen tab and save
4. Reminders are auto-scheduled — use **Test-Erinnerung senden** to preview

The timetable is re-synced automatically every **Sunday at 18:00**.

## Project Structure

```
├── main.py          # FastAPI app & API routes
├── scraper.py       # Portal login + HTML parsing
├── notifier.py      # Discord embeds & Gotify messages
├── scheduler.py     # APScheduler cron jobs & timetable reminders
├── database.py      # SQLite (settings, jobs, logs, timetable)
├── requirements.txt
├── run.sh
└── static/
    └── index.html   # Single-page web UI
```

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/settings` | Get current settings |
| `POST` | `/api/settings` | Save settings |
| `GET` | `/api/jobs` | List cron jobs |
| `POST` | `/api/jobs` | Create cron job |
| `PATCH` | `/api/jobs/{id}` | Enable/disable job |
| `DELETE` | `/api/jobs/{id}` | Delete job |
| `POST` | `/api/scrape/run` | Manual scrape & notify |
| `GET` | `/api/timetable` | Get stored timetable |
| `POST` | `/api/timetable/sync` | Fetch & store timetable |
| `POST` | `/api/timetable/test-reminder` | Send test class reminder |
| `GET` | `/api/logs` | Get recent logs |
