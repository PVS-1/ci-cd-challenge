$ErrorActionPreference = "Stop"

# OBJECTIVE 2: create CodeDeploy appspec.yml and lifecycle scripts.

$TaskRoot = $PSScriptRoot
$ScriptsDirectory = Join-Path $TaskRoot "scripts"
$AppSpecPath = Join-Path $TaskRoot "appspec.yml"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $ScriptsDirectory -Force | Out-Null

$AppSpecContent = @'
version: 0.0
os: linux
files:
  - source: /
    destination: /opt/codedeploy-flask
    overwrite: true
file_exists_behavior: OVERWRITE
hooks:
  ApplicationStop:
    - location: scripts/stop-application.sh
      timeout: 60
      runas: root
  AfterInstall:
    - location: scripts/install-dependencies.sh
      timeout: 300
      runas: root
  ApplicationStart:
    - location: scripts/start-application.sh
      timeout: 60
      runas: root
'@

$InstallDependencies = @'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/codedeploy-flask"
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"
'@

$StopApplication = @'
#!/usr/bin/env bash
set -Eeuo pipefail

systemctl stop codedeploy-flask.service || true
'@

$StartApplication = @'
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
'@

[System.IO.File]::WriteAllText($AppSpecPath, $AppSpecContent.Replace("`r`n", "`n"), $Utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $ScriptsDirectory "install-dependencies.sh"), $InstallDependencies.Replace("`r`n", "`n"), $Utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $ScriptsDirectory "stop-application.sh"), $StopApplication.Replace("`r`n", "`n"), $Utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $ScriptsDirectory "start-application.sh"), $StartApplication.Replace("`r`n", "`n"), $Utf8NoBom)

Write-Output "Objective 2 complete. Created:"
Write-Output $AppSpecPath
Get-ChildItem -LiteralPath $ScriptsDirectory -File | Select-Object -ExpandProperty FullName
