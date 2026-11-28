#!/usr/bin/env bash
# Generate templates/lab-13-dashboard.json from configuration rather than literals
# (Lab 13 Exercise 2). Re-runnable; the output contains values, not commands.
#   account <- USMS_ACCOUNT_ID   (configs/lab-01.env)
#   region  <- AWS_REGION_COURSE (configs/course.env)
# Usage: usms-dashboard-generate.sh [--put]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env
# shellcheck disable=SC1091
source configs/lab-13.env 2>/dev/null || true
: "${USMS_ACCOUNT_ID:?USMS_ACCOUNT_ID unset - source configs/lab-01.env}"
: "${AWS_REGION_COURSE:?AWS_REGION_COURSE unset - source configs/course.env}"

python3 - "$USMS_ACCOUNT_ID" "$AWS_REGION_COURSE" "${USMS_METRIC_NAMESPACE:-USMS/Application}" \
  "${USMS_ALARM_COMPOSITE:-usms-transcript-pipeline-down}" "${USMS_ALARM_LAG_HIGH:-usms-transcript-lag-high}" \
  "${USMS_ALARM_NOTIFY_SILENCE:-usms-notify-silence}" > templates/lab-13-dashboard.json << 'PY'
import json, sys
account, region, ns, a_comp, a_lag, a_sil = sys.argv[1:7]
ERROR_THRESHOLD = 5   # proposed, not yet alarmed: 5 failures / 5 min is well above the 1 seen in this lab
arn = lambda name: "arn:aws:cloudwatch:%s:%s:alarm:%s" % (region, account, name)
widgets = [
    {"type": "text", "x": 0, "y": 0, "width": 24, "height": 2, "properties": {
        "markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."}},
    {"type": "metric", "x": 0, "y": 2, "width": 12, "height": 6, "properties": {
        "title": "Transcripts processed, by faculty", "region": region, "stat": "Sum", "period": 300,
        "view": "timeSeries", "stacked": False, "metrics": [
            [ns, "TranscriptsProcessed", "Faculty", "science", "Stage", "notify"],
            [ns, "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify"]]}},
    {"type": "metric", "x": 12, "y": 2, "width": 12, "height": 6, "properties": {
        "title": "Notification latency - max and average", "region": region, "period": 60, "view": "timeSeries",
        "metrics": [
            [ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Maximum", "label": "max"}],
            [ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Average", "label": "avg"}]],
        "annotations": {"horizontal": [{"label": "alarm threshold", "value": 2}]}}},
    {"type": "metric", "x": 0, "y": 8, "width": 8, "height": 4, "properties": {
        "title": "Notifications in the last 5 minutes", "region": region, "stat": "Sum", "period": 300,
        "view": "singleValue", "metrics": [[ns, "NotifyCount"], [ns, "CentralErrorCount"]]}},
    {"type": "alarm", "x": 8, "y": 8, "width": 16, "height": 4, "properties": {
        "title": "Pipeline alarms", "alarms": [arn(a_comp), arn(a_lag), arn(a_sil)]}},
    {"type": "metric", "x": 0, "y": 12, "width": 24, "height": 6, "properties": {
        "title": "Central application errors - last 3 hours", "region": region, "stat": "Sum", "period": 300,
        "view": "timeSeries", "start": "-PT3H", "end": "P0D",
        "metrics": [[ns, "CentralErrorCount", {"label": "errors / 5 min"}]],
        "annotations": {"horizontal": [{"label": "proposed alarm threshold", "value": ERROR_THRESHOLD}]}}},
]
print(json.dumps({"widgets": widgets}, indent=2))
PY
python3 -m json.tool templates/lab-13-dashboard.json > /dev/null && echo "generated templates/lab-13-dashboard.json ($(python3 -c 'import json;print(len(json.load(open("templates/lab-13-dashboard.json"))["widgets"]))') widgets)"
if [ "${1:-}" = "--put" ]; then
  aws cloudwatch put-dashboard --dashboard-name "${USMS_DASHBOARD:-usms-overview}" \
    --dashboard-body file://templates/lab-13-dashboard.json --query 'DashboardValidationMessages' --output json
fi
