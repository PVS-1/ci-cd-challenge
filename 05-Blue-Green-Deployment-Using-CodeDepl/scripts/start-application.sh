#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/codedeploy-flask"
SERVICE_FILE="/etc/systemd/system/codedeploy-flask.service"

cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=CodeDeploy Flask application
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/application.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

chmod 755 "$APP_DIR/application.py"
chmod 755 "$APP_DIR/scripts"/*.sh
systemctl daemon-reload
systemctl enable codedeploy-flask.service
systemctl restart codedeploy-flask.service