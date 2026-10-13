#!/usr/bin/env bash
# Lab 04 Exercise 3 - one line per ECS service in the course cluster, with computed verdicts.
# Also writes outputs/lab-04-ecs-inventory.json. Read-only.
#
# set -e is deliberately OFF: one service that fails to describe (deleted mid-run, emulator gap)
# must not abort the report and silently hide every service after it. Each call is checked
# explicitly instead, and a failure is printed as an ERROR line for that service.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
OUT="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"

arns=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text) || {
  echo "ERROR: cannot list services in $CLUSTER" >&2; exit 1; }

records="[]"
for arn in $arns; do
  svc_json=$(aws ecs describe-services --cluster "$CLUSTER" --services "$arn" \
               --query 'services[0]' --output json 2>/dev/null)
  if [ -z "$svc_json" ] || [ "$svc_json" = "null" ]; then
    printf '%-20s ERROR could not describe %s\n' "${arn##*/}" "$arn"; continue
  fi

  name=$(jq -r '.serviceName'          <<< "$svc_json")
  desired=$(jq -r '.desiredCount // "N/A"' <<< "$svc_json")
  running=$(jq -r '.runningCount // "N/A"' <<< "$svc_json")
  td_arn=$(jq -r '.taskDefinition // ""'   <<< "$svc_json")
  public=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "NONE"' <<< "$svc_json")

  case "$public" in
    DISABLED) publicip=OK ;;
    ENABLED)  publicip=RISK ;;
    *)        publicip=N/A ;;     # no networkConfiguration (e.g. EC2 launch type)
  esac

  taskdef="N/A"; roles="N/A"
  if [ -n "$td_arn" ]; then
    taskdef="${td_arn##*/}"
    td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" \
                --query 'taskDefinition.{e:executionRoleArn,t:taskRoleArn}' --output json 2>/dev/null)
    if [ -n "$td_json" ]; then
      exec_r=$(jq -r '.e // ""' <<< "$td_json"); task_r=$(jq -r '.t // ""' <<< "$td_json")
      if   [ -z "$exec_r" ] || [ -z "$task_r" ]; then roles=MISSING
      elif [ "$exec_r" = "$task_r" ];          then roles=SAME
      else                                          roles=SEPARATE; fi
    else
      roles=ERROR
    fi
  fi

  printf '%-20s desired=%-3s running=%-3s taskdef=%-22s roles=%-9s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  records=$(jq --arg n "$name" --arg d "$desired" --arg r "$running" --arg t "$taskdef" \
               --arg ro "$roles" --arg p "$publicip" \
    '. + [{service:$n, desired:$d, running:$r, taskdef:$t, roles:$ro, publicip:$p}]' <<< "$records")
done

mkdir -p "$(dirname "$OUT")"
jq --arg c "$CLUSTER" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '{cluster:$c, generatedAt:$at, services:.}' <<< "$records" > "$OUT"
echo "JSON written to $OUT"
