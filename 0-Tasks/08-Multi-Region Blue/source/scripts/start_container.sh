#!/bin/bash
set -euo pipefail

APP_DIR="/opt/cmtr-msdta2zd-north-pole"
IMAGE_URI="$(cat "$APP_DIR/image-uri.txt")"
REGION="us-east-1"

docker run -d \
  --name cmtr-msdta2zd-north-pole \
  --restart unless-stopped \
  -e AWS_REGION="$REGION" \
  -e AWS_DEFAULT_REGION="$REGION" \
  -p 8080:8080 \
  "$IMAGE_URI"
