"""
Scraper for the Eltern-Portal substitute plan.
Handles CSRF-protected login, then parses the Vertretungsplan and Stundenplan.
"""
import re
import requests
from bs4 import BeautifulSoup


class ElternPortalScraper:
    def __init__(self, base_url: str, username: str, password: str):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (compatible; SubstituteScraper/1.0)",
        })

    def _url(self, path: str) -> str:
        return f"{self.base_url}/{path.lstrip('/')}"

    def login(self) -> bool:
        """Fetch login page, extract CSRF token, POST credentials."""
        resp = self.session.get(self._url("/"), timeout=15)
        resp.raise_for_status()

        soup = BeautifulSoup(resp.text, "html.parser")
        csrf_input = soup.find("input", {"name": "csrf"})
        if not csrf_input:
            raise ValueError("Could not find CSRF token on login page")
        csrf = csrf_input["value"]

        payload = {
            "csrf": csrf,
            "username": self.username,
            "password": self.password,
            "go_to": "",
        }
        login_resp = self.session.post(
            self._url("/includes/project/auth/login.php"),
            data=payload,
            timeout=15,
            allow_redirects=True,
        )
        login_resp.raise_for_status()

        # Verify we're logged in by checking for logout link
        if "logout" not in login_resp.text.lower() and "vertretungsplan" not in login_resp.text.lower():
            # Try fetching start page
            start = self.session.get(self._url("/start"), timeout=15)
            if "logout" not in start.text.lower():
                raise ValueError("Login failed – check credentials")
        return True

    def get_substitute_plan(self) -> dict:
        """Fetch and parse the Vertretungsplan (substitute plan)."""
        resp = self.session.get(self._url("/service/vertretungsplan"), timeout=15)
        resp.raise_for_status()
        return self._parse_substitute(resp.text)

    def get_timetable(self) -> dict:
        """Fetch and parse the Stundenplan (timetable)."""
        resp = self.session.get(self._url("/service/stundenplan"), timeout=15)
        resp.raise_for_status()
        return self._parse_timetable(resp.text)

    # ------------------------------------------------------------------
    # Parsers
    # ------------------------------------------------------------------

    def _parse_substitute(self, html: str) -> dict:
        soup = BeautifulSoup(html, "html.parser")
        content = soup.find("div", id="asam_content")
        if not content:
            content = soup

        # Class name from heading
        heading = content.find("h2")
        class_name = ""
        if heading:
            m = re.search(r"Klasse\s+(\S+)", heading.get_text())
            if m:
                class_name = m.group(1)

        days: list[dict] = []
        day_labels = content.find_all("div", class_="list bold full_width text_center")
        tables = content.find_all("table", class_="table")

        # Stand (last update) info
        stand_div = content.find("div", class_="list full_width")
        stand = stand_div.get_text(strip=True) if stand_div else ""

        for i, label_div in enumerate(day_labels):
            day_label = label_div.get_text(strip=True)
            entries = []
            if i < len(tables):
                table = tables[i]
                rows = table.find_all("tr")
                for row in rows[1:]:  # skip header
                    cols = [td.get_text(strip=True) for td in row.find_all("td")]
                    if len(cols) == 1:
                        # "Keine Vertretungen" message
                        entries.append({"empty": True, "message": cols[0]})
                    elif len(cols) >= 5:
                        entries.append({
                            "empty": False,
                            "period": cols[0],
                            "substitute": cols[1],
                            "subject": cols[2],
                            "room": cols[3],
                            "info": cols[4],
                        })
            days.append({"date": day_label, "entries": entries})

        return {"class_name": class_name, "days": days, "stand": stand}

    def _parse_timetable(self, html: str) -> dict:
        soup = BeautifulSoup(html, "html.parser")
        content = soup.find("div", id="asam_content")
        if not content:
            content = soup

        table = content.find("table", class_="table-bordered")
        if not table:
            return {"slots": [], "days": []}

        rows = table.find_all("tr")
        if not rows:
            return {"slots": [], "days": []}

        header_cols = rows[0].find_all("th")
        days = [th.get_text(strip=True) for th in header_cols[1:]]

        slots = []
        for row in rows[1:]:
            cells = row.find_all("td")
            if not cells:
                continue

            slot_raw = cells[0].get_text(separator="\n", strip=True)

            # Extract period number and start time  e.g. "1.\n08.10 - 08.55"
            pm = re.search(r"^(\d+)\.", slot_raw)
            tm = re.search(r"(\d{2})\.(\d{2})\s*[-–]", slot_raw)
            period     = int(pm.group(1)) if pm else 0
            start_time = f"{tm.group(1)}:{tm.group(2)}" if tm else ""

            period_cells = []
            for cell in cells[1:]:
                spans = cell.find_all("span")
                if spans and len(spans) >= 2:
                    # Inner span contains "Subject\nRoom" separated by <br>
                    parts = [p.strip() for p in spans[1].get_text(separator="\n").split("\n") if p.strip()]
                    subject = parts[0] if parts else ""
                    room    = parts[1] if len(parts) > 1 else ""
                else:
                    subject, room = "", ""
                period_cells.append({"subject": subject, "room": room})

            slots.append({
                "period":     period,
                "start_time": start_time,
                "slot":       slot_raw,
                "cells":      period_cells,
            })

        return {"days": days, "slots": slots}
