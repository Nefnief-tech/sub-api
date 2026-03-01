#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Vertretungsplan Scraper — Interactive Installer
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1;34m'
W='\033[1;37m' D='\033[2m' N='\033[0m'

header() {
  echo -e "\n${B}╔══════════════════════════════════════════════════╗${N}"
  echo -e "${B}║  ${W}📋  Vertretungsplan Scraper  —  Installer${B}       ║${N}"
  echo -e "${B}╚══════════════════════════════════════════════════╝${N}\n"
}

step()  { echo -e "\n${C}▶  $*${N}"; }
ok()    { echo -e "${G}✔  $*${N}"; }
warn()  { echo -e "${Y}⚠  $*${N}"; }
die()   { echo -e "${R}✘  $*${N}"; exit 1; }
ask()   { echo -en "${W}$*${N} "; }

header

# ── 1. Check python3-venv ─────────────────────────────────────────────────────
step "Checking dependencies..."
if ! python3 -m venv --help &>/dev/null; then
  warn "python3-venv not found — installing..."
  apt-get install -y python3-venv python3-full 2>/dev/null || \
    die "Could not install python3-venv. Run: apt install python3-venv"
fi
ok "python3-venv available"

# ── 2. Port ───────────────────────────────────────────────────────────────────
step "Port configuration"
DEFAULT_PORT=8080
while true; do
  ask "Port to run on [${DEFAULT_PORT}]:"
  read PORT
  PORT="${PORT:-$DEFAULT_PORT}"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    warn "Invalid port. Please enter a number between 1 and 65535."; continue
  fi
  if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || \
     lsof -i ":${PORT}" &>/dev/null 2>&1; then
    warn "Port ${PORT} is already in use."
    ask "  Kill the process using it? [y/N]:"
    read KILL_IT
    if [[ "$KILL_IT" =~ ^[Yy]$ ]]; then
      fuser -k "${PORT}/tcp" 2>/dev/null && ok "Killed process on port ${PORT}" || \
        warn "Could not kill — you may need to do this manually"
    fi
  fi
  ok "Using port ${PORT}"
  break
done

# ── 3. Host ───────────────────────────────────────────────────────────────────
step "Host binding"
ask "Bind host [0.0.0.0]:"
read HOST
HOST="${HOST:-0.0.0.0}"
ok "Binding to ${HOST}"

# ── 4. Systemd service ────────────────────────────────────────────────────────
step "Run mode"
echo -e "  ${D}1)${N} Systemd service ${D}(auto-start on boot, recommended)${N}"
echo -e "  ${D}2)${N} Run manually with ./run.sh"
ask "Choose [1/2]:"
read RUN_MODE
RUN_MODE="${RUN_MODE:-1}"

# ── 5. Create venv + install deps ─────────────────────────────────────────────
step "Setting up virtual environment..."
VENV=".venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  ok "Created .venv"
else
  ok ".venv already exists"
fi

source "$VENV/bin/activate"
pip install -q --upgrade pip
step "Installing Python dependencies..."
pip install -q -r requirements.txt
ok "Dependencies installed"

# ── 6. Write run.sh with chosen port/host ─────────────────────────────────────
step "Writing run.sh..."
cat > run.sh << RUNEOF
#!/usr/bin/env bash
set -e
cd "\$(dirname "\$0")"
source .venv/bin/activate
exec uvicorn main:app --host ${HOST} --port ${PORT} --reload
RUNEOF
chmod +x run.sh
ok "run.sh updated (host=${HOST}, port=${PORT})"

# ── 7. Systemd service ────────────────────────────────────────────────────────
if [ "$RUN_MODE" = "1" ]; then
  step "Creating systemd service..."

  SERVICE_NAME="vertretungsplan"
  WORK_DIR="$(pwd)"
  PYTHON="$(pwd)/.venv/bin/python3"
  UVICORN="$(pwd)/.venv/bin/uvicorn"

  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=Vertretungsplan Scraper
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORK_DIR}
ExecStart=${UVICORN} main:app --host ${HOST} --port ${PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"

  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Service '${SERVICE_NAME}' is running"
  else
    warn "Service may not have started — check: journalctl -u ${SERVICE_NAME} -n 30"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}╔══════════════════════════════════════════════════╗${N}"
echo -e "${B}║  ${G}✔  Installation complete!${B}                      ║${N}"
echo -e "${B}╠══════════════════════════════════════════════════╣${N}"
echo -e "${B}║  ${W}UI:${N}  http://${HOST}:${PORT}${B}"
if [ "$RUN_MODE" = "1" ]; then
echo -e "${B}║  ${D}systemctl status ${SERVICE_NAME}${N}${B}                 ║${N}"
echo -e "${B}║  ${D}journalctl -u ${SERVICE_NAME} -f${N}${B}                 ║${N}"
else
echo -e "${B}║  ${D}Run manually:  ./run.sh${N}${B}                       ║${N}"
fi
echo -e "${B}╚══════════════════════════════════════════════════╝${N}"
echo ""
