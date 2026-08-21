#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "=== 1. Container Status ==="
docker container inspect "$FLOCI_CONTAINER_NAME" --format '{{.State.Status}}'
echo "=== 2. Storage Mode ==="
docker exec "$FLOCI_CONTAINER_NAME" env | grep FLOCI_STORAGE_MODE || true
echo "=== 3. Data Directory ==="
du -sh "$FLOCI_HOST_DATA_DIR"
