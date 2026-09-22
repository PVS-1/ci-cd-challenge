#!/bin/bash
set -euo pipefail

APP_DIR="/opt/cmtr-msdta2zd-north-pole"
REGION="us-east-1"
IMAGE_URI="$(cat "$APP_DIR/image-uri.txt")"
ACCOUNT_ID="${IMAGE_URI%%.*}"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker pull "$IMAGE_URI"
