#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "Starting Lab 01 Resource Teardown..."

# 1. Remove Access Keys
aws iam delete-access-key --user-name usms-dev-01 --access-key-id $(aws iam list-access-keys --user-name usms-dev-01 --query 'AccessKeyMetadata[0].AccessKeyId' --output text 2>/dev/null) 2>/dev/null || true

# 2. Detach Group Policies & Delete Groups
for group in usms-admins usms-developers usms-auditors; do
  for policy in $(aws iam list-attached-group-policies --group-name "$group" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-group-policy --group-name "$group" --policy-arn "$policy" || true
  done
  for inline in $(aws iam list-group-policies --group-name "$group" --query 'PolicyNames[*]' --output text 2>/dev/null); do
    aws iam delete-group-policy --group-name "$group" --policy-name "$inline" || true
  done
  for user in $(aws iam get-group --group-name "$group" --query 'Users[*].UserName' --output text 2>/dev/null); do
    aws iam remove-user-from-group --group-name "$group" --user-name "$user" || true
  done
  aws iam delete-group --group-name "$group" 2>/dev/null || true
done

# 3. Delete Users
for user in usms-admin-01 usms-dev-01 usms-audit-01; do
  aws iam delete-user --user-name "$user" 2>/dev/null || true
done

# 4. Instance Profiles & Roles
aws iam remove-role-from-instance-profile --instance-profile-name usms-ec2-app-profile --role-name usms-ec2-app-role 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name usms-ec2-app-profile 2>/dev/null || true

for role in usms-ec2-app-role usms-lambda-exec-role usms-developer-role; do
  for policy in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" || true
  done
  aws iam delete-role --role-name "$role" 2>/dev/null || true
done

# 5. Customer Managed Policies
for policy_arn in $(aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `USMS`)].Arn' --output text 2>/dev/null); do
  aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || true
done

echo "[ok] Lab 01 IAM teardown complete."
