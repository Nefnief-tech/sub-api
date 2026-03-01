<p align="center">
  <img src="https://img.shields.io/badge/Python-3.10+-3776AB?style=for-the-badge&logo=python&logoColor=white"/>
  <img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white"/>
  <img src="https://img.shields.io/badge/Discord-Webhooks-5865F2?style=for-the-badge&logo=discord&logoColor=white"/>
  <img src="https://img.shields.io/badge/Gotify-Push-FF6B35?style=for-the-badge&logo=gotify&logoColor=white"/>
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge"/>
</p>

<h1 align="center">📋 Vertretungsplan Scraper</h1>
<p align="center">
  Automated substitute plan notifications for the <strong>Eltern-Portal</strong> school system.<br/>
  Rich Discord embeds · Gotify push · Class reminders · Dark web UI · Cron scheduling
</p>

---

## ✨ Features

| | Feature | Description |
|---|---|---|
| 🔐 | **Auto Login** | CSRF-protected Eltern-Portal authentication handled automatically |
| 📣 | **Discord Webhooks** | Rich multi-embed messages with color-coded per-day cards |
| 🔔 | **Gotify Notifications** | Markdown-formatted substitute plan pushed to your Gotify server |
| ⏰ | **Class Reminders** | Gotify push 5 minutes before each class, based on your timetable |
| 🗓 | **Timetable Sync** | Fetches & stores your weekly schedule, auto-refreshes every Sunday |
| 🕐 | **Cron Scheduler** | APScheduler with fully configurable jobs managed through the UI |
| 🖥 | **Web UI** | Dark "Night Ops Console" — settings, jobs, logs & timetable tabs |
| ⚙️ | **Easy Install** | Interactive installer with port picker + systemd service setup |

---

## 🚀 Quick Start

### 1. Clone & Install

```bash
git clone https://github.com/Nefnief-tech/sub-api.git
cd sub-api
./install.sh
```

The installer will interactively ask you:

```
▶  Port to run on [8080]:  █
▶  Bind host [0.0.0.0]:    █
▶  Run mode:
     1) Systemd service (auto-start on boot, recommended)
     2) Run manually with ./run.sh
```

It automatically:
- Creates a Python virtual environment (`.venv`)
- Installs all dependencies
- Detects & optionally kills port conflicts
- Optionally registers a systemd service

### 2. Run Manually (alternative)

```bash
./run.sh
```

Open `http://localhost:8080` in your browser.

---

## ⚙️ Configuration

All settings are managed through the **Einstellungen** tab in the web UI.

### 🏫 Portal Access

| Setting | Description |
|---|---|
| `Base URL` | Your Eltern-Portal URL, e.g. `https://evbspar.eltern-portal.org/` |
| `Username` | Portal login username |
| `Password` | Portal login password (stored locally, never transmitted elsewhere) |

### 📣 Discord

| Setting | Description |
|---|---|
| `Webhook URL` | Discord channel webhook URL |

### 🔔 Gotify

| Setting | Description |
|---|---|
| `Gotify URL` | Your Gotify server URL |
| `App Token` | Token from Gotify → Apps |
| `Priorität` | Notification priority 1–10 (default `5`) |

### ⚙️ Notifications

| Setting | Default | Description |
|---|---|---|
| `Leere Tage melden` | off | Send notification even when no substitutions exist |
| `Stunden-Erinnerungen` | off | Enable 5-min class reminders via Gotify |
| `Erinnerungs-Priorität` | `7` | Priority for class reminder pushes |

---

## 📅 Timetable & Class Reminders

1. Open the **📅 Stundenplan** tab
2. Click **🔄 Jetzt synchronisieren** to fetch your timetable from the portal
3. Enable **Stunden-Erinnerungen** in the Einstellungen tab → Save
4. Click **🔔 Test-Erinnerung senden** to preview a notification

Reminders are automatically rescheduled every **Sunday at 18:00**. Each reminder fires **5 minutes before** the period start time and includes the subject, room number, day and period.

---

## 🗂 Project Structure

```
sub-api/
├── main.py           # FastAPI app & all API routes
├── scraper.py        # Portal login + HTML parsing
├── notifier.py       # Discord rich embeds & Gotify messages
├── scheduler.py      # APScheduler cron jobs & timetable reminders
├── database.py       # SQLite — settings, jobs, logs, timetable
├── requirements.txt  # Python dependencies
├── install.sh        # Interactive installer
├── run.sh            # Venv-aware start script (written by installer)
└── static/
    └── index.html    # Single-page web UI
```

---

## 🔌 API Reference

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/settings` | Get current settings |
| `POST` | `/api/settings` | Save settings |
| `GET` | `/api/jobs` | List cron jobs |
| `POST` | `/api/jobs` | Create cron job |
| `PATCH` | `/api/jobs/{id}` | Enable / disable a job |
| `DELETE` | `/api/jobs/{id}` | Delete a job |
| `POST` | `/api/scrape/run` | Manual scrape & notify |
| `GET` | `/api/timetable` | Get stored timetable + reminder jobs |
| `POST` | `/api/timetable/sync` | Fetch & store timetable from portal |
| `POST` | `/api/timetable/test-reminder` | Send a test class reminder |
| `GET` | `/api/logs` | Get recent run logs |

---

## 🛠 Systemd Commands

If you chose the systemd install option:

```bash
# Status
systemctl status vertretungsplan

# Live logs
journalctl -u vertretungsplan -f

# Restart
systemctl restart vertretungsplan

# Stop
systemctl stop vertretungsplan
```

---

## 📦 Dependencies

- [FastAPI](https://fastapi.tiangolo.com/) — API framework
- [Uvicorn](https://www.uvicorn.org/) — ASGI server
- [Requests](https://requests.readthedocs.io/) — HTTP client for scraping
- [BeautifulSoup4](https://www.crummy.com/software/BeautifulSoup/) — HTML parsing
- [APScheduler](https://apscheduler.readthedocs.io/) — Cron job scheduling

---

<p align="center">
  Made for <strong>Emil-von-Behring-Gymnasium Spardorf</strong> · Eltern-Portal compatible
</p>
