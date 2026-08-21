#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
docker compose stop
echo "Floci stopped. State preserved in $FLOCI_HOST_DATA_DIR"
