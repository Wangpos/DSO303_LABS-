#!/usr/bin/env bash
# For every running instance tagged Project=USMS, print one line:
#   name  private-ip  public-ip  VERDICT  reason
# The verdict is computed from the subnet's route table, the instance's public
# address and its security groups - never from names or tags.
#
# No `set -e`: a None or a failed lookup for one instance must degrade that
# instance's line to UNKNOWN, not abort the report for every other instance.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{n:Tags[?Key==`Name`]|[0].Value,s:SubnetId,v:VpcId,pr:PrivateIpAddress,pu:PublicIpAddress,g:SecurityGroups[].GroupId}' \
  --output json |
jq -c 'sort_by(.n)[]' |
while read -r inst; do
  name=$(jq -r '.n // "-"' <<<"$inst")
  subnet=$(jq -r '.s // empty' <<<"$inst")
  vpc=$(jq -r '.v // empty' <<<"$inst")
  priv=$(jq -r '.pr // "-"' <<<"$inst")
  pub=$(jq -r '.pu // "-"' <<<"$inst")
  sgs=$(jq -r '.g // [] | join(" ")' <<<"$inst")

  # Route table: the subnet's explicit association, else the VPC's main table.
  # Scoped to the instance's VPC, so a stray cross-VPC association is ignored.
  igw=$(aws ec2 describe-route-tables \
          --filters "Name=association.subnet-id,Values=$subnet" "Name=vpc-id,Values=$vpc" \
          --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
          --output text 2>/dev/null)
  if [ -z "$igw" ] || [ "$igw" = "None" ]; then
    igw=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
            --output text 2>/dev/null)
  fi

  sg_open=no
  if [ -n "$sgs" ]; then
    # shellcheck disable=SC2086
    hits=$(aws ec2 describe-security-groups --group-ids $sgs \
             --query 'SecurityGroups[].IpPermissions[?(IpProtocol==`-1`) || (FromPort<=`80` && ToPort>=`80`)][].IpRanges[?CidrIp==`0.0.0.0/0`][]' \
             --output text 2>/dev/null)
    [ -n "$hits" ] && [ "$hits" != "None" ] && sg_open=yes
  fi

  if [ -z "$subnet" ] || [ -z "$vpc" ]; then
    verdict=UNKNOWN;     reason="instance has no subnet or VPC recorded"
  elif [[ "$igw" != igw-* ]]; then
    verdict=UNREACHABLE; reason="no igw route on subnet"
  elif [ "$pub" = "-" ]; then
    verdict=NO-ADDRESS;  reason="igw route present but no public address"
  elif [ "$sg_open" = no ]; then
    verdict=FILTERED;    reason="igw route + public address, but no sg allows 80/tcp from 0.0.0.0/0"
  else
    verdict=REACHABLE;   reason="igw route + sg allows 80/tcp from 0.0.0.0/0"
  fi

  printf '%-20s %-14s %-14s %-12s %s\n' "$name" "$priv" "$pub" "$verdict" "$reason"
done
