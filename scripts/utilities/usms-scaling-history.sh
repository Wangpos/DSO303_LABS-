#!/usr/bin/env bash
# Lab 06 Exercise 5 - export the enrolment service's complete scaling configuration and
# history as ONE JSON document: outputs/lab-06-scaling-history.json (Lab 10's first object).
# Read-only against the cloud. Works from any directory. Every identifier is discovered.
# No -e: unsupported calls (scheduled actions on Floci 2.0.1) must degrade to [], not abort.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
OUT="${1:-$REPO_ROOT/outputs/lab-06-scaling-history.json}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

j() { local f="$1" fb="$2"; shift 2; "$@" --output json > "$WORK/$f" 2>/dev/null || echo "$fb" > "$WORK/$f"; }

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
            --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

j target.json     '{"ScalableTargets":[]}'   aws application-autoscaling describe-scalable-targets  --service-namespace ecs --resource-ids "$RID"
j policies.json   '{"ScalingPolicies":[]}'   aws application-autoscaling describe-scaling-policies  --service-namespace ecs --resource-id "$RID"
j scheduled.json  '{"ScheduledActions":[]}'  aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID"
j activities.json '{"ScalingActivities":[]}' aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID" --include-not-scaled-activities
j alarms.json     '{"MetricAlarms":[]}'      aws cloudwatch describe-alarms

python3 - "$WORK" "$RID" "$SVC_ARN" "$OUT" << 'PY'
import json, sys, os, datetime
work, rid, svc_arn, out = sys.argv[1:5]
L = lambda f, k: json.load(open(os.path.join(work, f))).get(k, []) or []
policies = L("policies.json", "ScalingPolicies")
arns = {p["PolicyARN"] for p in policies}
named = {a["AlarmName"] for p in policies for a in (p.get("Alarms") or [])}
# Involved alarms: named by a policy (managed) OR whose actions invoke one of its policies (yours).
alarms = [a for a in L("alarms.json", "MetricAlarms")
          if a["AlarmName"] in named or arns.intersection(a.get("AlarmActions", []))]
doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": rid,
    "serviceArn": svc_arn,
    "scalableTarget": (L("target.json", "ScalableTargets") or [None])[0],
    "scalingPolicies": policies,
    "scheduledActions": L("scheduled.json", "ScheduledActions"),
    "alarms": alarms,
    "scalingActivities": L("activities.json", "ScalingActivities"),
}
json.dump(doc, open(out, "w"), indent=2, default=str)
print(f"wrote {out}: {len(policies)} policies, {len(alarms)} alarms, "
      f"{len(doc['scheduledActions'])} scheduled actions, {len(doc['scalingActivities'])} activities")
PY
