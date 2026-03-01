#!/usr/bin/env bash
# Start the Vertretungsplan scraper dashboard
set -e
cd "$(dirname "$0")"

VENV=".venv"

if [ ! -d "$VENV" ]; then
  echo "Creating virtual environment..."
  python3 -m venv "$VENV"
fi

source "$VENV/bin/activate"

# Install / upgrade deps silently if needed
pip install -q --upgrade pip
pip install -q -r requirements.txt

exec uvicorn main:app --host 0.0.0.0 --port 8080 --reload
