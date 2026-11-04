#!/usr/bin/env bash
# Lab 06 Exercise 3 - print the scaling decision table for every USMS ECS service.
# Read-only. No arguments. Discovers every scalable target in the ecs namespace whose
# resource ID names a cluster beginning "usms-", and writes outputs/lab-06-scaling-report.json.
#
# -e is deliberately NOT set: several calls are expected to fail on some builds
# (describe-scheduled-actions is UnsupportedOperation on Floci 2.0.1, and
# describe-scaling-activities may be unimplemented). A report that aborts on the first
# missing feature tells you less than one that prints "none recorded" and carries on.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
OUT="$REPO_ROOT/outputs/lab-06-scaling-report.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Safe JSON fetch: on failure write the given fallback document instead.
fetch() { local file="$1" fallback="$2"; shift 2
  "$@" --output json > "$WORK/$file" 2>/dev/null || echo "$fallback" > "$WORK/$file"; }

fetch targets.json '{"ScalableTargets":[]}' \
  aws application-autoscaling describe-scalable-targets --service-namespace ecs

RIDS=$(python3 -c '
import json,sys
for t in json.load(open(sys.argv[1])).get("ScalableTargets",[]):
    p=t["ResourceId"].split("/")
    if len(p)==3 and p[0]=="service" and p[1].startswith("usms-"): print(t["ResourceId"])
' "$WORK/targets.json")

i=0
for rid in $RIDS; do
  i=$((i+1)); cluster=$(echo "$rid" | cut -d/ -f2); svc=$(echo "$rid" | cut -d/ -f3)
  fetch "pol$i.json"  '{"ScalingPolicies":[]}'   aws application-autoscaling describe-scaling-policies   --service-namespace ecs --resource-id "$rid"
  fetch "sch$i.json"  '{"ScheduledActions":[]}'  aws application-autoscaling describe-scheduled-actions  --service-namespace ecs --resource-id "$rid"
  fetch "act$i.json"  '{"ScalingActivities":[]}' aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$rid" --max-items 1
  fetch "svc$i.json"  '{"services":[]}'          aws ecs describe-services --cluster "$cluster" --services "$svc"
  # All alarms in ONE call: step policy alarms are not always back-linked in the policy's
  # Alarms list (Floci), so the report matches alarms to policies by AlarmActions instead.
  fetch "alm$i.json" '{"MetricAlarms":[]}' aws cloudwatch describe-alarms
  printf '%s\n' "$rid" > "$WORK/rid$i"
done

python3 - "$WORK" "$i" "$OUT" << 'PY'
import json, sys, os
work, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
L = lambda f, k: json.load(open(os.path.join(work, f))).get(k, []) or []
targets = {t["ResourceId"]: t for t in L("targets.json", "ScalableTargets")}
report = []

def verdict(t, desired, npol):
    # Order matters. PINNED first: if min == max nothing can move, whatever else is true.
    # FROZEN outranks AT-CEILING/AT-FLOOR: a suspended target sitting at the ceiling is not
    # "at the ceiling because of load" - it is stuck because someone switched scaling off,
    # and that is the condition an operator must act on first. Position verdicts only mean
    # something for a target that is actually free to move.
    s = t.get("SuspendedState", {}) or {}
    if t["MinCapacity"] == t["MaxCapacity"]: return "PINNED"
    if any(s.values()): return "FROZEN"
    if desired == t["MaxCapacity"]: return "AT-CEILING"
    if desired == t["MinCapacity"] and npol > 1: return "AT-FLOOR"
    return "ELASTIC"

for k in range(1, n + 1):
    rid = open(os.path.join(work, f"rid{k}")).read().strip()
    t = targets[rid]
    pols = L(f"pol{k}.json", "ScalingPolicies")
    schs = L(f"sch{k}.json", "ScheduledActions")
    acts = L(f"act{k}.json", "ScalingActivities")
    svcs = L(f"svc{k}.json", "services")
    alarms = {a["AlarmName"]: a for a in L(f"alm{k}.json", "MetricAlarms")}
    svc = svcs[0] if svcs else {}
    desired, running = svc.get("desiredCount", "?"), svc.get("runningCount", "?")
    v = verdict(t, desired, len(pols))
    susp = [k2.replace("Suspended", "") for k2, val in (t.get("SuspendedState") or {}).items() if val]
    print(f"{rid}   {t['ScalableDimension']}")
    print(f"  bounds       min={t['MinCapacity']}  max={t['MaxCapacity']}   desired={desired}   running={running}   {v}")
    print(f"  suspended    {', '.join(susp) if susp else 'none'}")
    prow = []
    for p in sorted(pols, key=lambda x: x["PolicyName"]):
        if p["PolicyType"] == "TargetTrackingScaling":
            c = p["TargetTrackingScalingPolicyConfiguration"]
            m = (c.get("PredefinedMetricSpecification") or {}).get("PredefinedMetricType", "custom")
            short = {"ECSServiceAverageCPUUtilization": "CPU", "ECSServiceAverageMemoryUtilization": "MEM",
                     "ALBRequestCountPerTarget": "ALBReq"}.get(m, m)
            print(f"  target-track {p['PolicyName']:<42} {short}/{c['TargetValue']:<9} out={c.get('ScaleOutCooldown','-')}  in={c.get('ScaleInCooldown','-')}"
                  + ("  scale-in DISABLED" if c.get("DisableScaleIn") else ""))
            st = []
            for a in p.get("Alarms") or []:
                kind = "AlarmHigh" if "AlarmHigh" in a["AlarmName"] else "AlarmLow" if "AlarmLow" in a["AlarmName"] else a["AlarmName"]
                st.append(f"{kind}={alarms.get(a['AlarmName'], {}).get('StateValue', 'MISSING')}")
            print(f"                 alarms  {'  '.join(st) if st else 'none created'}")
        else:
            c = p["StepScalingPolicyConfiguration"]
            steps = " / ".join(f"{s['ScalingAdjustment']:+d}" for s in c.get("StepAdjustments", []))
            print(f"  step         {p['PolicyName']:<42} {steps:<15} cooldown={c.get('Cooldown','-')}")
            drv = [a for a in alarms.values() if any(p["PolicyARN"] == x for x in a.get("AlarmActions", []))]
            for a in drv:
                print(f"                 alarm   {a['AlarmName']} = {a['StateValue']}  ({a.get('Namespace')} {a.get('MetricName')} "
                      f"{ {'GreaterThanOrEqualToThreshold':'>=','GreaterThanThreshold':'>','LessThanThreshold':'<','LessThanOrEqualToThreshold':'<='}.get(a.get('ComparisonOperator'),'?') } {a.get('Threshold')})")
            if not drv: print("                 alarm   none drives this policy")
        prow.append(p)
    for s in sorted(schs, key=lambda x: x["ScheduledActionName"]):
        print(f"  scheduled    {s['ScheduledActionName']:<34} {s['Schedule']}  {s.get('Timezone','UTC')}  min={s.get('ScalableTargetAction',{}).get('MinCapacity','-')}")
    if not schs: print("  scheduled    none recorded (or unsupported on this build)")
    if acts:
        a = acts[0]; print(f"  last activity  {a.get('StartTime')}  {a.get('StatusCode')}  {a.get('Description')}")
    else:
        print("  last activity  none recorded")
    report.append({"resourceId": rid, "target": t, "verdict": v, "desiredCount": desired, "runningCount": running,
                   "policies": prow, "scheduledActions": schs, "lastActivity": acts[0] if acts else None})
    print()
if not report: print("no usms- scalable targets found in the ecs namespace")
json.dump(report, open(out, "w"), indent=2, default=str)
PY
