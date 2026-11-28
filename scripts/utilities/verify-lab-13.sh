#!/usr/bin/env bash
# Verify every Lab 13 artefact exists AND is configured as the lab requires.
# Exit 1 if anything is missing. Read-only: this script changes nothing.
#
# Floci adaptation: where this build does not implement a feature (metric filters,
# composite alarms, returning TreatMissingData), the check asks the live API first
# and falls back to the committed document in templates/ that was deployed. The
# label says "[doc]" when the document answered rather than the service.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

CENTRAL="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
FN_LOG="${USMS_LOG_GROUP_NOTIFIER:-/aws/lambda/usms-transcript-notifier}"
ECS_LOG="${USMS_LOG_GROUP_ECS:-/usms/ecs/enrolment}"
NS="${USMS_METRIC_NAMESPACE:-USMS/Application}"
NOTIFIER="${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}"
ROLE_LAMBDA="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_EC2="${USMS_ROLE_EC2:-usms-ec2-app-role}"
A_LAG="${USMS_ALARM_LAG_HIGH:-usms-transcript-lag-high}"
A_SILENCE="${USMS_ALARM_NOTIFY_SILENCE:-usms-notify-silence}"
A_COMP="${USMS_ALARM_COMPOSITE:-usms-transcript-pipeline-down}"
DASH="${USMS_DASHBOARD:-usms-overview}"
MF_DOC=templates/lab-13-metric-filters.json
ALARM_DOC=templates/lab-13-alarms.json
COMP_DOC=templates/lab-13-composite-alarm.json

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ✔ %s\n" "$1"; PASS=$((PASS+1))
  else                               printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# --- capability probes ----------------------------------------------------
MF_LIVE=no;   aws logs describe-metric-filters --limit 1 >/dev/null 2>&1 && MF_LIVE=yes
COMP_LIVE=no; aws cloudwatch describe-alarms --alarm-types CompositeAlarm --query 'length(CompositeAlarms || `[]`)' --output text 2>/dev/null \
                | grep -qE '^[1-9]' && COMP_LIVE=yes
src() { [ "$1" = yes ] && echo "" || echo " [doc]"; }

# --- helpers -------------------------------------------------------------
lg_retention() {
  aws logs describe-log-groups --log-group-name-prefix "$1" \
    --query "logGroups[?logGroupName=='$1'].retentionInDays | [0]" --output text
}
lg_any_unset() {
  aws logs describe-log-groups \
    --query 'logGroups[?retentionInDays==null].logGroupName' --output text \
    | tr '\t' '\n' | grep -E '^/usms/|^/aws/lambda/usms-'
}
mf_group() {   # $1 = filter name -> its log group (live, else document)
  if [ "$MF_LIVE" = yes ]; then
    aws logs describe-metric-filters --query "metricFilters[?filterName=='$1'].logGroupName | [0]" --output text
  else
    python3 -c 'import json,sys; print(next((f["logGroupName"] for f in json.load(open(sys.argv[1])) if f["filterName"]==sys.argv[2]), ""))' "$MF_DOC" "$1"
  fi
}
metric_dims() {
  aws cloudwatch list-metrics --namespace "$NS" --metric-name "$1" \
    --query 'Metrics[].[join(`,`, Dimensions[].Name) || `NONE`][]' --output text | tr '\t' '\n'
}
obs_policy_arn() {
  aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text
}
obs_policy_doc() {
  local arn ver
  arn=$(obs_policy_arn)
  ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json
}
role_has_obs() {
  aws iam list-attached-role-policies --role-name "$1" --output text | grep -q USMSObservabilityWrite
}
alias_version() {
  aws lambda get-alias --function-name "$NOTIFIER" --name live --query 'FunctionVersion' --output text
}
alarm_field() {   # $1 = alarm name, $2 = field; live value, else the deployed document's
  local v
  v=$(aws cloudwatch describe-alarms --alarm-names "$1" --query "MetricAlarms[0].$2" --output text)
  if [ -z "$v" ] || [ "$v" = None ]; then
    v=$(python3 -c 'import json,sys; print(next((a.get(sys.argv[3],"") for a in json.load(open(sys.argv[1])) if a["AlarmName"]==sys.argv[2]), ""))' "$ALARM_DOC" "$1" "$2")
  fi
  printf '%s' "$v"
}
alarm_live_matches_doc() {   # the fields Floci does return agree with the document
  local live
  live=$(aws cloudwatch describe-alarms --alarm-names "$1" --query 'MetricAlarms[0].[MetricName,Statistic,Period,Threshold]' --output json)
  python3 -c 'import json,sys
live = json.loads(sys.argv[3])
doc = next(a for a in json.load(open(sys.argv[1])) if a["AlarmName"] == sys.argv[2])
sys.exit(0 if live == [doc["MetricName"], doc["Statistic"], doc["Period"], float(doc["Threshold"])] else 1)' "$ALARM_DOC" "$1" "$live"
}
not_forced_alarm() {   # fail only if left in ALARM by a forced Lab 13 set-alarm-state
  local s r
  s=$(aws cloudwatch describe-alarms --alarm-names "$1" --query 'MetricAlarms[0].StateValue' --output text)
  r=$(aws cloudwatch describe-alarms --alarm-names "$1" --query 'MetricAlarms[0].StateReason' --output text)
  [ "$s" != ALARM ] || ! printf '%s' "$r" | grep -q '^Lab 13 Step'
}
composite_rule() {
  if [ "$COMP_LIVE" = yes ]; then
    aws cloudwatch describe-alarms --alarm-names "$A_COMP" --alarm-types CompositeAlarm \
      --query 'CompositeAlarms[0].AlarmRule' --output text
  else
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["AlarmRule"] if d["AlarmName"]==sys.argv[2] else "")' "$COMP_DOC" "$A_COMP"
  fi
}
alarm_exists() {
  aws cloudwatch describe-alarms --alarm-names "$1" --query "length(MetricAlarms)" --output text | grep -qv "^0$"
}
dashboard_body() {
  aws cloudwatch get-dashboard --dashboard-name "$DASH" --query 'DashboardBody' --output text
}
dashboard_widgets() {
  dashboard_body | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["widgets"]))'
}
dashboard_no_overlap() {
  dashboard_body | python3 -c '
import json, sys
w = json.load(sys.stdin)["widgets"]
boxes = [(x["x"], x["y"], x["x"]+x["width"], x["y"]+x["height"]) for x in w]
for i, a in enumerate(boxes):
    for b in boxes[i+1:]:
        if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
            sys.exit(1)
sys.exit(0)'
}
sampling_rule_complete() {
  python3 -c '
import json, sys
r = json.load(open("templates/lab-13-sampling-rule.json"))
need = {"RuleName","ResourceARN","Priority","FixedRate","ReservoirSize",
        "ServiceName","ServiceType","Host","HTTPMethod","URLPath","Version"}
sys.exit(0 if need.issubset(r) else 1)'
}
segments_consistent() {
  python3 -c '
import json, re, sys
d = {n: json.load(open("templates/lab-13-segment-%s.json" % n))
     for n in ("parent", "subsegments", "downstream")}
tid = d["parent"]["trace_id"]
ok = (re.fullmatch(r"1-[0-9a-f]{8}-[0-9a-f]{24}", tid)
      and all(x["trace_id"] == tid for x in d.values())
      and all(re.fullmatch(r"[0-9a-f]{16}", x["id"]) for x in d.values())
      and d["downstream"].get("parent_id") == d["parent"]["id"]
      and all(x["end_time"] > x["start_time"] for x in d.values()))
sys.exit(0 if ok else 1)'
}

echo "== Environment =="
check "Floci container running" \
  'test "$(docker container inspect $FLOCI_CONTAINER_NAME --format "{{.State.Running}}")" = true'
check "Storage mode is NOT memory" \
  'docker container inspect $FLOCI_CONTAINER_NAME --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -qE "^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$"'
check "AWS CLI reaches Floci" \
  'aws sts get-caller-identity --query Account --output text | grep -q "^000000000000$"'

echo "== Log layer =="
check "central log group $CENTRAL exists" \
  'aws logs describe-log-groups --log-group-name-prefix "$CENTRAL" --query "length(logGroups)" --output text | grep -qv "^0$"'
check "central log group retention is 30 days" \
  'test "$(lg_retention "$CENTRAL")" = "30"'
check "notifier log group has a retention policy" \
  'lg_retention "$FN_LOG" | grep -qE "^[0-9]+$"'
check "ECS log group has a retention policy" \
  'lg_retention "$ECS_LOG" | grep -qE "^[0-9]+$"'
check "NO USMS log group is left on never-expire" \
  '! lg_any_unset | grep -q .'
check "central log group has at least one stream" \
  'test "$(aws logs describe-log-streams --log-group-name "$CENTRAL" --query "length(logStreams)" --output text)" != "0"'

echo "== Metric filters =="
check "usms-notify-count exists$(src $MF_LIVE)" \
  'test -n "$(mf_group usms-notify-count)" && test "$(mf_group usms-notify-count)" != None'
check "usms-notify-count is attached to the NOTIFIER log group$(src $MF_LIVE)" \
  'test "$(mf_group usms-notify-count)" = "$FN_LOG"'
check "usms-central-errors is attached to the CENTRAL log group$(src $MF_LIVE)" \
  'test "$(mf_group usms-central-errors)" = "$CENTRAL"'

echo "== Metrics =="
check "namespace $NS has metrics" \
  'test "$(aws cloudwatch list-metrics --namespace "$NS" --query "length(Metrics)" --output text)" != "0"'
check "TranscriptsProcessed published WITH dimensions" \
  'metric_dims TranscriptsProcessed | grep -q Faculty'
check "TranscriptsProcessed ALSO published with none  (the total)" \
  'metric_dims TranscriptsProcessed | grep -q NONE'
check "TranscriptLagSeconds exists" \
  'test "$(aws cloudwatch list-metrics --namespace "$NS" --metric-name TranscriptLagSeconds --query "length(Metrics)" --output text)" != "0"'

echo "== IAM =="
check "USMSObservabilityWrite exists" \
  'obs_policy_arn | grep -q "policy/USMSObservabilityWrite"'
check "attached to $ROLE_LAMBDA" \
  'role_has_obs "$ROLE_LAMBDA"'
check "attached to $ROLE_EC2" \
  'role_has_obs "$ROLE_EC2"'
check "PutMetricData is scoped by a cloudwatch:namespace condition" \
  'obs_policy_doc | grep -q "cloudwatch:namespace"'
check "log group ARNs end in :*  (streams, not just the group)" \
  'obs_policy_doc | grep -qE "log-group:/usms/\*:\*"'

echo "== The instrumented notifier =="
check "$NOTIFIER exists" \
  'aws lambda get-function-configuration --function-name "$NOTIFIER"'
check "alias live points at a numbered version" \
  'alias_version | grep -qE "^[0-9]+$"'
check "alias live has MOVED PAST Lab 10 version 1" \
  'test "$(alias_version)" -ge 2'
check "tracing mode on the alias is Active" \
  'test "$(aws lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live --query "TracingConfig.Mode" --output text)" = "Active"'
check "instrumented handler source emits USMS_SUMMARY" \
  'grep -q "USMS_SUMMARY" labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py'

echo "== Alarms =="
check "$A_LAG exists and matches its deployed document" \
  'alarm_exists "$A_LAG" && alarm_live_matches_doc "$A_LAG"'
check "$A_LAG uses the Maximum statistic, not Average" \
  'test "$(alarm_field "$A_LAG" Statistic)" = "Maximum"'
check "$A_LAG treats missing data as notBreaching" \
  'test "$(alarm_field "$A_LAG" TreatMissingData)" = "notBreaching"'
check "$A_SILENCE exists and matches its deployed document" \
  'alarm_exists "$A_SILENCE" && alarm_live_matches_doc "$A_SILENCE"'
check "$A_SILENCE treats missing data as BREACHING  (it watches an absence)" \
  'test "$(alarm_field "$A_SILENCE" TreatMissingData)" = "breaching"'
check "composite alarm $A_COMP exists$(src $COMP_LIVE)" \
  'composite_rule | grep -q ALARM'
check "composite rule names BOTH child alarms, and both exist" \
  'composite_rule | grep -q "\"$A_LAG\"" && composite_rule | grep -q "\"$A_SILENCE\"" && alarm_exists "$A_LAG" && alarm_exists "$A_SILENCE"'
check "no alarm is left stuck in a FORCED ALARM from Step 20 or 21" \
  'not_forced_alarm "$A_LAG" && not_forced_alarm "$A_SILENCE"'

echo "== Dashboard =="
check "dashboard $DASH exists" \
  'aws cloudwatch list-dashboards --query "DashboardEntries[].DashboardName" --output text | grep -q "$DASH"'
check "dashboard body is valid JSON" \
  'dashboard_body | python3 -m json.tool'
check "dashboard has 6 widgets  (Exercise 2 added one)" \
  'test "$(dashboard_widgets)" -eq 6'
check "no two widgets overlap" \
  'dashboard_no_overlap'

echo "== X-Ray documents =="
check "sampling rule document is valid JSON" \
  'python3 -m json.tool templates/lab-13-sampling-rule.json'
check "sampling rule declares every required field" \
  'sampling_rule_complete'
check "segment documents share one trace id and are well formed" \
  'segments_consistent'

echo "== Files and Git hygiene =="
check "configs/lab-13.env exists" \
  'test -f configs/lab-13.env'
check "configs/lab-13.env has 28 exports" \
  'test "$(grep -c "^export" configs/lab-13.env)" -eq 28'
check "configs/lab-13.env has no empty values" \
  '! grep -qE "^export [A-Z_]+=$" configs/lab-13.env'
check "usms-emit-telemetry.sh is executable and valid bash" \
  'test -x scripts/utilities/usms-emit-telemetry.sh && bash -n scripts/utilities/usms-emit-telemetry.sh'
check "observability policy document is valid JSON" \
  'python3 -m json.tool policies/usms-observability-write-policy.json'
check "dashboard template is committed, not only deployed" \
  'test -f templates/lab-13-dashboard.json'
check "no secret is tracked" \
  '! git ls-files | grep -q "^outputs/[^.]"'
check "no deployment archive is tracked" \
  '! git ls-files | grep -q "\.zip$"'

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
