#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "Running Lab 01 cleanup procedures..."
rm -f "$REPO_ROOT/outputs/"*.json
echo "Lab 01 temporary outputs cleaned up."
