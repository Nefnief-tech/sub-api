"""
Discord webhook notifier — rich multi-embed formatting.

Structure per message:
  • 1 header embed   — title, weekly summary, color-coded status
  • N day embeds     — one per day that has changes (inline field card-grid)
  • 1 all-clear      — single celebratory embed when nothing changed
"""
import re
from datetime import datetime, timezone
import requests

# ── Subject maps ──────────────────────────────────────────────────────────────

SUBJECT_NAMES: dict[str, str] = {
    "D": "Deutsch",        "E": "Englisch",           "M": "Mathematik",
    "Ph": "Physik",        "C": "Chemie",              "Bio": "Biologie",
    "Geo": "Geographie",   "G": "Geschichte",          "Ku": "Kunst",
    "Mu": "Musik",         "Spo": "Sport",             "Inf": "Informatik",
    "F": "Französisch",    "L": "Latein",              "WR": "Wirtschaft & Recht",
    "PuG": "Politik & Gesellschaft", "Eth": "Ethik",  "Ev": "Ev. Religionslehre",
    "K": "Kath. Religionslehre",     "Sm": "Schwimmen", "Sw": "Schwimmen",
    "P-S": "P-Seminar",    "W-S": "W-Seminar",
}

SUBJECT_EMOJI: dict[str, str] = {
    "Deutsch": "📖",        "Englisch": "🇬🇧",         "Mathematik": "📐",
    "Physik": "⚛️",          "Chemie": "🧪",             "Biologie": "🧬",
    "Geographie": "🌍",     "Geschichte": "🏛️",          "Kunst": "🎨",
    "Musik": "🎵",          "Sport": "⚽",               "Informatik": "💻",
    "Französisch": "🇫🇷",   "Latein": "📜",              "Wirtschaft & Recht": "💼",
    "Politik & Gesellschaft": "🗳️", "Ethik": "⚖️",       "Ev. Religionslehre": "✝️",
    "Kath. Religionslehre": "⛪",   "P-Seminar": "🔬",   "W-Seminar": "📊",
}

# ── Colors ────────────────────────────────────────────────────────────────────

COLOR_ALL_CLEAR  = 0x57F287   # Discord Green
COLOR_HAS_CHANGE = 0xFF6B35   # Orange
COLOR_CANCELLED  = 0xED4245   # Discord Red
COLOR_SUBSTITUTE = 0xFEE75C   # Discord Yellow
COLOR_ROOM       = 0x5865F2   # Discord Blurple
COLOR_TASK       = 0xEB459E   # Discord Fuchsia


# ── Helpers ───────────────────────────────────────────────────────────────────

def _subject_full(abbr: str) -> str:
    parts = re.split(r"[/,]", abbr)
    return " / ".join(SUBJECT_NAMES.get(p.strip(), p.strip()) for p in parts)


def _subject_display(abbr: str) -> str:
    full  = _subject_full(abbr) if abbr else "–"
    first = _subject_full(abbr.split("/")[0].split(",")[0].strip()) if abbr else ""
    return f"{SUBJECT_EMOJI.get(first, '📚')} {full}"


def _classify(info: str) -> tuple[str, int]:
    """Return (emoji, color) for an info string."""
    low = info.lower()
    if any(k in low for k in ("entfällt", "fällt aus", "ausfall")):
        return "🚫", COLOR_CANCELLED
    if any(k in low for k in ("aufgabe", "aufg.", "selbst")):
        return "📝", COLOR_TASK
    if "raum" in low:
        return "🚪", COLOR_ROOM
    if any(k in low for k in ("vertretung", "vertr.")):
        return "🔄", COLOR_SUBSTITUTE
    if "frei" in low:
        return "🎉", COLOR_ALL_CLEAR
    if "verschoben" in low:
        return "⏩", COLOR_SUBSTITUTE
    return "ℹ️", COLOR_SUBSTITUTE


def _day_color(entries: list[dict]) -> int:
    priority = {COLOR_CANCELLED: 4, COLOR_TASK: 3, COLOR_SUBSTITUTE: 2, COLOR_ROOM: 1}
    best = (COLOR_SUBSTITUTE, 0)
    for e in entries:
        if e.get("empty"):
            continue
        _, color = _classify(e.get("info", ""))
        if priority.get(color, 0) > best[1]:
            best = (color, priority.get(color, 0))
    return best[0]


def _extract_kw(days: list[dict]) -> str:
    for d in days:
        m = re.search(r"KW\s*(\d+)", d.get("date", ""), re.IGNORECASE)
        if m:
            return f"KW {m.group(1)}"
    return ""


def _clean_date(raw: str) -> str:
    """Strip the ' - KW XX' suffix from a date label."""
    return re.sub(r"\s*[-–]\s*KW\s*\d+", "", raw, flags=re.IGNORECASE).strip()


# ── Discord embed builders ────────────────────────────────────────────────────

def _build_header_embed(plan: dict) -> dict:
    class_name = plan.get("class_name", "?")
    days       = plan.get("days", [])
    stand      = plan.get("stand", "")
    kw         = _extract_kw(days)
    year       = datetime.now().year

    all_entries   = [e for d in days for e in d["entries"] if not e.get("empty")]
    cancelled_cnt = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_CANCELLED)
    sub_cnt       = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_SUBSTITUTE)
    room_cnt      = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_ROOM)
    task_cnt      = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_TASK)
    affected_days = sum(1 for d in days if any(not e.get("empty") for e in d["entries"]))
    total         = len(all_entries)
    has_changes   = total > 0

    if has_changes:
        kw_str = f"{kw} · " if kw else ""
        desc_lines = [
            f"{kw_str}{year}  —  **{affected_days} Tag{'e' if affected_days != 1 else ''}** betroffen",
            "",
        ]
        if cancelled_cnt: desc_lines.append(f"🚫 **{cancelled_cnt}×** entfällt")
        if sub_cnt:       desc_lines.append(f"🔄 **{sub_cnt}×** Vertretungslehrer")
        if room_cnt:      desc_lines.append(f"🚪 **{room_cnt}×** Raumänderung")
        if task_cnt:      desc_lines.append(f"📝 **{task_cnt}×** Aufgaben")
        if stand:
            desc_lines += ["", f"> {stand}"]
    else:
        kw_str = f"in {kw} " if kw else ""
        desc_lines = [
            f"Für Klasse **{class_name}** sind {kw_str}keine Vertretungen eingetragen.",
            "",
            "Schöne Woche! 🎉",
        ]
        if stand:
            desc_lines += ["", f"> {stand}"]

    return {
        "author":      {"name": "Eltern-Portal · Emil-von-Behring-Gymnasium"},
        "title":       f"{'📋' if has_changes else '✅'}  Vertretungsplan · Klasse {class_name}",
        "description": "\n".join(desc_lines),
        "color":       COLOR_HAS_CHANGE if has_changes else COLOR_ALL_CLEAR,
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "footer":      {"text": "Eltern-Portal · Automatischer Abruf"},
    }


def _build_day_embed(day: dict) -> dict | None:
    entries = [e for e in day["entries"] if not e.get("empty")]
    if not entries:
        return None

    fields = []
    # Use inline cards only when there are multiple entries (looks cleaner)
    use_inline = len(entries) >= 2

    for e in entries:
        period   = e.get("period", "?")
        subject  = e.get("subject", "")
        room     = e.get("room") or "–"
        sub_name = e.get("substitute") or "–"
        info_raw = e.get("info") or "–"

        emoji, _ = _classify(info_raw)
        subj_disp = _subject_display(subject) if subject else "📚 –"

        value_lines = [
            f"{emoji} {info_raw}",
            f"🚪 Raum: `{room}`",
            f"👤 Vertretung: `{sub_name}`",
        ]

        fields.append({
            "name":   f"{period} Stunde · {subj_disp}",
            "value":  "\n".join(value_lines),
            "inline": use_inline,
        })

    # Pad to full row of 3 only when using inline layout
    if use_inline:
        remainder = len(fields) % 3
        if remainder == 2:
            fields.append({"name": "\u200b", "value": "\u200b", "inline": True})
        elif remainder == 1 and len(fields) > 1:
            fields.append({"name": "\u200b", "value": "\u200b", "inline": True})
            fields.append({"name": "\u200b", "value": "\u200b", "inline": True})

    return {
        "title":  f"📅 {_clean_date(day['date'])}",
        "color":  _day_color(entries),
        "fields": fields,
    }


def _build_empty_day_field(day: dict) -> dict:
    return {
        "name":   f"📅 {_clean_date(day['date'])}",
        "value":  "✅ Keine Vertretungen",
        "inline": True,
    }


# ── Public Discord API ────────────────────────────────────────────────────────

def build_embeds(plan: dict, include_empty_days: bool = False) -> list[dict]:
    days   = plan.get("days", [])
    embeds = [_build_header_embed(plan)]

    empty_day_fields = []
    for day in days:
        has_changes = any(not e.get("empty") for e in day["entries"])
        if has_changes:
            day_embed = _build_day_embed(day)
            if day_embed and len(embeds) < 10:
                embeds.append(day_embed)
        elif include_empty_days:
            empty_day_fields.append(_build_empty_day_field(day))

    if empty_day_fields and len(embeds) < 10:
        embeds.append({
            "title":  "✅ Tage ohne Vertretungen",
            "color":  COLOR_ALL_CLEAR,
            "fields": empty_day_fields,
        })

    return embeds


def send_to_discord(webhook_url: str, plan: dict, include_empty_days: bool = False) -> bool:
    embeds = build_embeds(plan, include_empty_days)
    resp = requests.post(
        webhook_url,
        json={
            "username":   "Vertretungsplan",
            "avatar_url": "https://cdn.discordapp.com/embed/avatars/0.png",
            "embeds":     embeds,
        },
        timeout=10,
    )
    resp.raise_for_status()
    return True


# ── Gotify ────────────────────────────────────────────────────────────────────

def build_gotify_message(plan: dict, include_empty_days: bool = False) -> tuple[str, str]:
    """Return (title, markdown_body) for a Gotify notification."""
    class_name  = plan.get("class_name", "?")
    days        = plan.get("days", [])
    stand       = plan.get("stand", "")
    kw          = _extract_kw(days)

    all_entries = [e for d in days for e in d["entries"] if not e.get("empty")]
    total       = len(all_entries)
    has_changes = total > 0

    title = f"📚 Vertretungsplan · Klasse {class_name}"
    lines: list[str] = []

    if not has_changes:
        kw_str = f"in {kw} " if kw else ""
        lines += [
            f"Für Klasse **{class_name}** sind {kw_str}keine Vertretungen eingetragen.",
            "",
            "Schöne Woche! 🎉",
        ]
    else:
        cancelled  = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_CANCELLED)
        substitute = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_SUBSTITUTE)
        room       = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_ROOM)
        task       = sum(1 for e in all_entries if _classify(e.get("info",""))[1] == COLOR_TASK)
        affected   = sum(1 for d in days if any(not e.get("empty") for e in d["entries"]))

        kw_str = f"{kw} · " if kw else ""
        lines.append(f"**{kw_str}{affected} Tag{'e' if affected != 1 else ''} betroffen**")
        lines.append("")
        if cancelled:  lines.append(f"🚫 {cancelled}× entfällt")
        if substitute: lines.append(f"🔄 {substitute}× Vertretungslehrer")
        if room:       lines.append(f"🚪 {room}× Raumänderung")
        if task:       lines.append(f"📝 {task}× Aufgaben")

        for day in days:
            day_entries = [e for e in day["entries"] if not e.get("empty")]
            if not day_entries:
                if include_empty_days:
                    lines += ["", f"**{_clean_date(day['date'])}**", "✅ Keine Vertretungen"]
                continue

            lines += ["", f"---", f"**{_clean_date(day['date'])}**", ""]
            for e in day_entries:
                emoji, _ = _classify(e.get("info", ""))
                subj    = _subject_full(e.get("subject", "")) or "–"
                period  = e.get("period", "?")
                room_v  = e.get("room") or "–"
                sub_v   = e.get("substitute") or "–"
                info_v  = e.get("info") or "–"
                lines.append(f"{emoji} **{period} Stunde** · {subj}")
                lines.append(f"   🚪 Raum: {room_v}  ·  👤 {sub_v}  ·  {info_v}")

    if stand:
        lines += ["", "---", f"*{stand}*"]

    return title, "\n".join(lines)


def send_to_gotify(gotify_url: str, token: str, plan: dict,
                   priority: int = 5, include_empty_days: bool = False) -> bool:
    title, message = build_gotify_message(plan, include_empty_days)
    resp = requests.post(
        f"{gotify_url.rstrip('/')}/message",
        json={
            "title":    title,
            "message":  message,
            "priority": priority,
            "extras":   {"client::display": {"contentType": "text/markdown"}},
        },
        params={"token": token},
        timeout=10,
    )
    resp.raise_for_status()
    return True


def send_class_reminder(gotify_url: str, token: str, subject: str, room: str,
                        day: str, period: int, priority: int = 7) -> bool:
    """Send a 5-minute class start reminder to Gotify."""
    full  = _subject_full(subject) if subject else subject
    emoji = SUBJECT_EMOJI.get(full, "📚")

    resp = requests.post(
        f"{gotify_url.rstrip('/')}/message",
        json={
            "title":   f"⏰ In 5 Minuten: {full}",
            "message": f"{emoji} **{full}**\n🚪 Raum: {room or '–'}\n📅 {day} · {period}. Stunde",
            "priority": priority,
            "extras":  {"client::display": {"contentType": "text/markdown"}},
        },
        params={"token": token},
        timeout=10,
    )
    resp.raise_for_status()
    return True

