#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/codedeploy-flask"
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"