#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

echo "Cleaning up Lab 02 resources..."
[ -n "${USMS_S3_ENDPOINT:-}" ] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$USMS_S3_ENDPOINT" || true
[ -n "${USMS_NAT_GW:-}" ] && aws ec2 delete-nat-gateway --nat-gateway-id "$USMS_NAT_GW" || true
[ -n "${USMS_NAT_EIP_ALLOC:-}" ] && aws ec2 release-address --allocation-id "$USMS_NAT_EIP_ALLOC" || true
[ -n "${USMS_DB_SG:-}" ] && aws ec2 delete-security-group --group-id "$USMS_DB_SG" || true
[ -n "${USMS_APP_SG:-}" ] && aws ec2 delete-security-group --group-id "$USMS_APP_SG" || true
[ -n "${USMS_PUBLIC_SUBNET_A:-}" ] && aws ec2 delete-subnet --subnet-id "$USMS_PUBLIC_SUBNET_A" || true
[ -n "${USMS_PRIVATE_SUBNET_A:-}" ] && aws ec2 delete-subnet --subnet-id "$USMS_PRIVATE_SUBNET_A" || true
[ -n "${USMS_IGW_ID:-}" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$USMS_IGW_ID" --vpc-id "$USMS_VPC_ID" && aws ec2 delete-internet-gateway --internet-gateway-id "$USMS_IGW_ID" || true
[ -n "${USMS_VPC_ID:-}" ] && aws ec2 delete-vpc --vpc-id "$USMS_VPC_ID" || true
echo "Cleanup complete."
