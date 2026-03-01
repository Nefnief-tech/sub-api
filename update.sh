#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Vertretungsplan Scraper — Update (non-interactive)
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

R='\033[0;31m' G='\033[0;32m' C='\033[0;36m' B='\033[1;34m' W='\033[1;37m' N='\033[0m'

step() { echo -e "\n${C}▶  $*${N}"; }
ok()   { echo -e "${G}✔  $*${N}"; }
die()  { echo -e "${R}✘  $*${N}"; exit 1; }

echo -e "\n${B}╔══════════════════════════════════════════════════╗${N}"
echo -e "${B}║  ${W}📋  Vertretungsplan Scraper  —  Update${B}          ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════╝${N}"

# ── Pull latest code ──────────────────────────────────────────────────────────
step "Pulling latest code..."
git pull --ff-only || die "git pull failed — resolve conflicts manually"
ok "Code up to date"

# ── Update Python dependencies ────────────────────────────────────────────────
step "Updating Python dependencies..."
[ -d ".venv" ] || die ".venv not found — run ./install.sh first"
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
ok "Dependencies updated"

# ── Restart service if running ────────────────────────────────────────────────
SERVICE_NAME="vertretungsplan"
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  step "Restarting systemd service..."
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Service restarted"
  else
    die "Service failed to restart — check: journalctl -u ${SERVICE_NAME} -n 30"
  fi
else
  ok "Service not running — start manually with ./run.sh or systemctl start ${SERVICE_NAME}"
fi

echo ""
echo -e "${B}╔══════════════════════════════════════════════════╗${N}"
echo -e "${B}║  ${G}✔  Update complete!${B}                             ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════╝${N}"
echo ""
