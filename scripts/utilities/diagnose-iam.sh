#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "=== IAM Summary Diagnostic ==="
echo "Users:"
aws iam list-users --query 'Users[*].UserName' --output text
echo "Groups:"
aws iam list-groups --query 'Groups[*].GroupName' --output text
echo "Roles:"
aws iam list-roles --query 'Roles[?contains(RoleName, `usms`)].RoleName' --output text
echo "Customer Managed Policies:"
aws iam list-policies --scope Local --query 'Policies[*].PolicyName' --output text
