#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
aws sts get-caller-identity --output table
acct="$(aws sts get-caller-identity --query Account --output text)"
if [ "$acct" = "$ACCOUNT_ID" ]; then
    echo "[ok] Account $acct — this is Floci, not real AWS."
else
    echo "[DANGER] Connected to Real AWS! Stopping."
    exit 1
fi
