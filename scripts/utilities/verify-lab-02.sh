#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then 
    printf "  %-50s [ OK ]\n" "$1"
    PASS=$((PASS+1))
  else 
    printf "  %-50s [FAIL]\n" "$1"
    FAIL=$((FAIL+1))
  fi
}

echo "== Environment Checks =="
check "Floci container running" "docker ps --format '{{.Names}}' | grep -q '^floci$'"
check "Storage mode hybrid" "docker inspect floci | grep -q 'FLOCI_STORAGE_MODE=hybrid'"

echo "== Lab 02 Network Checks =="
check "VPC exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "Public Subnet A mapped to IGW" "aws ec2 describe-route-tables --route-table-ids $USMS_PUBLIC_RT | grep -q $USMS_IGW_ID"
check "Private Subnet A mapped to NAT" "aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT | grep -q $USMS_NAT_GW"
check "DB SG references APP SG" "aws ec2 describe-security-groups --group-ids $USMS_DB_SG | grep -q $USMS_APP_SG"

echo "Results: $PASS Passed, $FAIL Failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
