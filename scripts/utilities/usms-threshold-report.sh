#!/usr/bin/env bash
# For every alarm whose name begins usms-, emit its configuration plus what its
# metric actually did over the last 24 hours (Lab 13 Exercise 3).
# stdout: one JSON document. stderr: diagnostics. Runs from any directory.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
export AWS_PROFILE
python3 - << 'PY'
import datetime, json, operator, os, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode:
        print("warning: aws %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()), file=sys.stderr)
        return None
    return json.loads(r.stdout or "null")

# This Floci build accepts but does not return TreatMissingData / DatapointsToAlarm;
# fall back to the deployed documents and say so.
docs = {}
for path in ("templates/lab-13-alarms.json", "templates/lab-13-composite-alarm.json"):
    if os.path.exists(path):
        d = json.load(open(path))
        for a in (d if isinstance(d, list) else [d]):
            docs[a["AlarmName"]] = a

now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = (now - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
end = (now + datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
ops = {"GreaterThanThreshold": operator.gt, "GreaterThanOrEqualToThreshold": operator.ge,
       "LessThanThreshold": operator.lt, "LessThanOrEqualToThreshold": operator.le}

resp = aws("cloudwatch", "describe-alarms", "--alarm-name-prefix", "usms-") or {}
report = []
for a in resp.get("MetricAlarms") or []:
    name, doc = a["AlarmName"], docs.get(a["AlarmName"], {})
    def field(k):
        v = a.get(k)
        return v if v is not None else doc.get(k)
    dims = []
    for d in a.get("Dimensions") or []:
        dims += ["Name=%s,Value=%s" % (d["Name"], d["Value"])]
    base = ["cloudwatch", "get-metric-statistics", "--namespace", a["Namespace"], "--metric-name", a["MetricName"],
            "--start-time", start, "--end-time", end]
    if dims:
        base += ["--dimensions", *dims]
    obs = aws(*base, "--period", "3600", "--statistics", "Minimum", "Maximum", "Sum", "SampleCount") or {}
    pts = obs.get("Datapoints") or []
    samples = sum(p["SampleCount"] for p in pts)
    observed = {"min": min((p["Minimum"] for p in pts), default=None),
                "avg": round(sum(p["Sum"] for p in pts) / samples, 4) if samples else None,
                "max": max((p["Maximum"] for p in pts), default=None),
                "samples": int(samples)}
    # Breach test at the alarm's own period and statistic, as CloudWatch would evaluate it.
    per = aws(*base, "--period", str(a["Period"]), "--statistics", a["Statistic"]) or {}
    vals = [p[a["Statistic"]] for p in per.get("Datapoints") or []]
    cmp = ops.get(a["ComparisonOperator"])
    breached = bool(cmp and any(cmp(v, a["Threshold"]) for v in vals))
    if not vals:
        print("note: %s has no data in 24h - threshold_ever_breached reflects data only, not missing-data policy" % name, file=sys.stderr)
    report.append({
        "alarm": name, "type": "metric", "namespace": a["Namespace"], "metric": a["MetricName"],
        "dimensions": {d["Name"]: d["Value"] for d in a.get("Dimensions") or []},
        "statistic": a["Statistic"], "period": a["Period"], "evaluation_periods": a["EvaluationPeriods"],
        "datapoints_to_alarm": field("DatapointsToAlarm"), "threshold": a["Threshold"],
        "operator": a["ComparisonOperator"], "missing_data": field("TreatMissingData"),
        "missing_data_source": "service" if a.get("TreatMissingData") else ("document" if doc.get("TreatMissingData") else "unset"),
        "state": a.get("StateValue"), "observed": observed, "threshold_ever_breached": breached})

composites = (resp.get("CompositeAlarms") or [])
if not composites:
    composites = [dict(d, _from_doc=True) for n, d in docs.items() if "AlarmRule" in d and n.startswith("usms-")]
for c in composites:
    report.append({"alarm": c["AlarmName"], "type": "composite", "rule": c["AlarmRule"],
                   "source": "document (PutCompositeAlarm unsupported)" if c.get("_from_doc") else "service",
                   "namespace": None, "metric": None, "statistic": None, "period": None,
                   "evaluation_periods": None, "datapoints_to_alarm": None, "threshold": None,
                   "operator": None, "missing_data": None, "observed": None, "threshold_ever_breached": None})
json.dump(report, sys.stdout, indent=2)
print()
PY
