#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "Stopping containers and removing persistent volume data..."
docker compose down -v
echo "Volume data successfully pruned."
