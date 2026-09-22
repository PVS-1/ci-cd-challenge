#!/bin/bash
set -euo pipefail

systemctl stop cmtr-msdta2zd-app.service 2>/dev/null || true