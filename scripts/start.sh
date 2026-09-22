#!/bin/bash
set -euo pipefail

systemctl enable cmtr-msdta2zd-app.service
systemctl restart cmtr-msdta2zd-app.service