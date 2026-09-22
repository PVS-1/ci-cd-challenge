#!/bin/bash
set -euo pipefail

APP_DIR=/opt/cmtr-msdta2zd-app
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"

cat >/etc/systemd/system/cmtr-msdta2zd-app.service <<'EOF'
[Unit]
Description=cmtr-msdta2zd Flask application
After=network.target

[Service]
WorkingDirectory=/opt/cmtr-msdta2zd-app
ExecStart=/opt/cmtr-msdta2zd-app/.venv/bin/python /opt/cmtr-msdta2zd-app/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload