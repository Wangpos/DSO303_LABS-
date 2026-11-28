#!/usr/bin/env bash
# Lab 13 Exercise 5 - prepare (never apply) the alarm actions a future alerting
# lab will attach, validate the draft, capture a latency baseline, and write
# outputs/lab-13-alerting-readiness.txt. Re-runnable. Changes no alarm.
# Usage: usms-alerting-readiness.sh [--emit]   (--emit runs the emitter 6 times first)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env
# shellcheck disable=SC1091
source configs/lab-13.env
export AWS_PROFILE USMS_ACCOUNT_ID AWS_REGION_COURSE

if [ "${1:-}" = "--emit" ]; then
  ./scripts/utilities/usms-emit-telemetry.sh science     0.48 >/dev/null
  ./scripts/utilities/usms-emit-telemetry.sh engineering 1.72 >/dev/null
  ./scripts/utilities/usms-emit-telemetry.sh law         0.95 >/dev/null
  ./scripts/utilities/usms-emit-telemetry.sh science     2.85 >/dev/null
  ./scripts/utilities/usms-emit-telemetry.sh medicine    1.10 >/dev/null
  ./scripts/utilities/usms-emit-telemetry.sh engineering 0.63 >/dev/null
  echo "emitted 6 transcripts" >&2
fi

# 1. the draft - account id from configs/lab-01.env, never a literal
python3 - "$USMS_ACCOUNT_ID" "$AWS_REGION_COURSE" "$USMS_ALARM_COMPOSITE" "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE" \
  > outputs/lab-13-alarm-actions-draft.json << 'PY'
import json, sys
acct, region, comp, lag, sil = sys.argv[1:6]
topic = lambda t: "arn:aws:sns:%s:%s:usms-%s" % (region, acct, t)
print(json.dumps({"status": "DRAFT - not applied; put-metric-alarm replaces the whole alarm",
  "actions": [
    {"alarm": comp, "meaning": "transcript pipeline failing or silent - the one incident page",
     "urgency": "page", "alarm_actions": [topic("oncall-page")], "ok_actions": [topic("oncall-page")], "actions_enabled": True},
    {"alarm": lag, "meaning": "a transcript took > 2s to notify, 2 of 3 minutes",
     "urgency": "ticket", "alarm_actions": [topic("ops-tickets")], "actions_enabled": False},
    {"alarm": sil, "meaning": "no transcript notification for 15 minutes",
     "urgency": "ticket", "alarm_actions": [topic("ops-tickets")], "actions_enabled": False}]}, indent=2))
PY

# 2. validate: every alarm exists (metric alarm live, composite live or as document), every ARN well formed
VALIDATION=$(python3 - << 'PY'
import json, re, subprocess
d = json.load(open("outputs/lab-13-alarm-actions-draft.json"))
names = [a["alarm"] for a in d["actions"]]
live = json.loads(subprocess.run(["aws", "cloudwatch", "describe-alarms", "--alarm-names", *names, "--output", "json"],
                                 capture_output=True, text=True).stdout)
found = {a["AlarmName"] for a in live.get("MetricAlarms") or []} | {a["AlarmName"] for a in live.get("CompositeAlarms") or []}
comp_doc = json.load(open("templates/lab-13-composite-alarm.json"))["AlarmName"]
problems = []
for a in d["actions"]:
    if a["alarm"] not in found:
        problems.append("%s: not a live alarm%s" % (a["alarm"], " (exists only as templates/lab-13-composite-alarm.json - PutCompositeAlarm unsupported)" if a["alarm"] == comp_doc else ""))
    for arn in a["alarm_actions"] + a.get("ok_actions", []):
        if not re.fullmatch(r"arn:aws:sns:[a-z0-9-]+:\d{12}:[A-Za-z0-9_-]{1,256}", arn) or len(arn.split(":")) != 6:
            problems.append("%s: malformed ARN %s" % (a["alarm"], arn))
print("ok - %d alarms, %d ARNs well formed" % (len(names), sum(len(a["alarm_actions"]) + len(a.get("ok_actions", [])) for a in d["actions"]))
      if not problems else "MISMATCHES:\n  " + "\n  ".join(problems))
PY
)

# 4. baseline from real observations over the session
python3 - << 'PY'
import datetime, json, subprocess
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
r = subprocess.run(["aws", "cloudwatch", "get-metric-statistics", "--namespace", "USMS/Application",
    "--metric-name", "TranscriptLagSeconds", "--dimensions", "Name=Stage,Value=notify",
    "--start-time", (now - datetime.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "--end-time", (now + datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "--period", "60", "--statistics", "SampleCount", "Minimum", "Average", "Maximum", "--output", "json"],
    capture_output=True, text=True, check=True)
pts = sorted(json.loads(r.stdout)["Datapoints"], key=lambda p: p["Timestamp"])
json.dump({"metric": "USMS/Application TranscriptLagSeconds {Stage=notify}", "period": 60, "window_hours": 6,
           "datapoints": pts,
           "overall_max": max((p["Maximum"] for p in pts), default=None),
           "samples": int(sum(p["SampleCount"] for p in pts))},
          open("outputs/lab-13-latency-baseline.json", "w"), indent=2, default=str)
PY
MAXLAT=$(python3 -c 'import json; print(json.load(open("outputs/lab-13-latency-baseline.json"))["overall_max"])')

# 5. the readiness report
{
  printf 'USMS Lab 13 -> alerting lab readiness - %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '== alarms and missing-data policy (service value, else deployed document) ==\n'
  for a in "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE"; do
    md=$(aws cloudwatch describe-alarms --alarm-names "$a" --query 'MetricAlarms[0].TreatMissingData' --output text)
    [ "$md" = None ] && md="$(python3 -c 'import json,sys; print(next(x["TreatMissingData"] for x in json.load(open("templates/lab-13-alarms.json")) if x["AlarmName"]==sys.argv[1]))' "$a") (document)"
    printf '  %-32s %s\n' "$a" "$md"
  done
  printf '  %-32s composite, no missing-data policy\n' "$USMS_ALARM_COMPOSITE"
  printf '\n== composite rule ==\n  %s\n' "$(python3 -c 'import json; print(json.load(open("templates/lab-13-composite-alarm.json"))["AlarmRule"])')"
  printf '\n== namespace and metrics ==\n  %s\n' "$USMS_METRIC_NAMESPACE"
  for m in "$USMS_METRIC_NOTIFY_COUNT" "$USMS_METRIC_ERROR_COUNT" "$USMS_METRIC_PROCESSED" "$USMS_METRIC_LAG" "$USMS_METRIC_EDGE_DENY"; do printf '    %s\n' "$m"; done
  printf '\n== notifier ==\n  alias live -> %s, tracing %s\n' \
    "$(aws lambda get-alias --function-name usms-transcript-notifier --name live --query FunctionVersion --output text)" \
    "$(aws lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live --query TracingConfig.Mode --output text)"
  printf '\n== build support ==\n  X-Ray: %s   Logs Insights: %s\n' "$USMS_XRAY_SUPPORTED" "$USMS_INSIGHTS_SUPPORTED"
  printf '\n== draft validation (outputs/lab-13-alarm-actions-draft.json) ==\n  %s\n' "$VALIDATION"
  printf '\n== AlarmActions currently applied (must be empty) ==\n'
  for a in "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE"; do
    printf '  %-32s %s\n' "$a" "$(aws cloudwatch describe-alarms --alarm-names "$a" --query 'MetricAlarms[0].AlarmActions' --output json | tr -d ' \n')"
  done
  printf '\n== observed latency baseline ==\n  max TranscriptLagSeconds over the session: %s s (threshold 2 s)\n' "$MAXLAT"
} | tee outputs/lab-13-alerting-readiness.txt
