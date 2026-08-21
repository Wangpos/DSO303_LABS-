#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

mkdir -p "$FLOCI_HOST_DATA_DIR"
cat > "$REPO_ROOT/.env" <<ENVEOF
FLOCI_HOST_DATA_DIR=$FLOCI_HOST_DATA_DIR
FLOCI_STORAGE_MODE=$FLOCI_STORAGE_MODE
ENVEOF

docker compose up -d
echo "Waiting for Floci endpoint..."
until curl -sf "http://localhost:4566/_floci/health" >/dev/null 2>&1; do sleep 2; done
echo "Floci is up at $FLOCI_ENDPOINT"
