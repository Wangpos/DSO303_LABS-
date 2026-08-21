#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/configs/course.env"
export AWS_PROFILE=floci

echo "=== Verifying Lab 01 IAM Setup ==="

aws iam get-user --user-name usms-admin-01 >/dev/null
aws iam get-user --user-name usms-dev-01 >/dev/null
aws iam get-user --user-name usms-audit-01 >/dev/null

aws iam get-group --group-name usms-admins >/dev/null
aws iam get-group --group-name usms-developers >/dev/null
aws iam get-group --group-name usms-auditors >/dev/null

aws iam get-role --role-name usms-developer-role >/dev/null
aws iam get-role --role-name usms-ec2-app-role >/dev/null
aws iam get-role --role-name usms-lambda-exec-role >/dev/null

aws iam get-instance-profile --instance-profile-name usms-ec2-app-profile >/dev/null

echo "[SUCCESS] Lab 1 verification passed completely!"
