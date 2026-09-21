#!/usr/bin/env bash
set -Eeuo pipefail

systemctl stop codedeploy-flask.service || true