#!/usr/bin/env bash
# Apply templates/lab-13-metric-filters.json the way CloudWatch Logs would, for a
# Floci build that has no PutMetricFilter. For each filter it tries the real API
# first; if that is unsupported it reads the matching events from the last N
# minutes and publishes what the filter WOULD have published:
#   metricValue "1"        -> one data point, Value = number of matches (or defaultValue)
#   metricValue "$.field"  -> one data point per matching event, Value = that field
# Text patterns (single terms) are matched server-side with filter-log-events;
# JSON patterns ({ $.k = "v" } / { $.k > n }) are matched here, because this
# build's filter-log-events does not implement the JSON dialect.
#
# A STAND-IN, not ingestion-time evaluation: it is retroactive over the window,
# and running it twice over the same window double-counts.
#
# Usage: usms-metric-filter-emulate.sh [window-minutes] [filter-name]
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
export AWS_PROFILE
python3 - "${1:-15}" "${2:-}" << 'PY'
import json, re, subprocess, sys, time

window_min, only = int(sys.argv[1]), sys.argv[2]

def aws(*args, check=True):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r

def json_match(pattern, message):
    m = re.fullmatch(r'\{\s*\$\.(\w+)\s*(=|!=|>|<|>=|<=)\s*("?)([^"]*)\3\s*\}', pattern.strip())
    if not m:
        raise ValueError("unsupported JSON pattern: " + pattern)
    try:
        doc = json.loads(message)
    except ValueError:
        return False                      # JSON dialect never matches a non-JSON line
    key, op, quoted, want = m.group(1), m.group(2), m.group(3), m.group(4)
    if key not in doc:
        return False
    have = doc[key]
    if quoted:
        return (str(have) == want) if op == "=" else (str(have) != want) if op == "!=" else False
    have, want = float(have), float(want)
    return {"=": have == want, "!=": have != want, ">": have > want,
            "<": have < want, ">=": have >= want, "<=": have <= want}[op]

start_ms = int((time.time() - window_min * 60) * 1000)
for f in json.load(open("templates/lab-13-metric-filters.json")):
    if only and f["filterName"] != only:
        continue
    t = f["metricTransformations"][0]
    name, group, pattern = f["filterName"], f["logGroupName"], f["filterPattern"]
    ns, metric, value = t["metricNamespace"], t["metricName"], str(t["metricValue"])
    real = aws("logs", "put-metric-filter", "--log-group-name", group, "--filter-name", name,
               "--filter-pattern", pattern, "--metric-transformations", json.dumps([t]), check=False)
    if real.returncode == 0:
        print("  %-24s deployed as a real metric filter on %s" % (name, group)); continue

    is_json = pattern.strip().startswith("{")
    args = ["logs", "filter-log-events", "--log-group-name", group, "--start-time", str(start_ms)]
    if not is_json:
        args += ["--filter-pattern", pattern]
    events = json.loads(aws(*args).stdout)["events"]
    if is_json:
        events = [e for e in events if json_match(pattern, e["message"])]

    if value == "1":
        n = len(events)
        if n == 0 and "defaultValue" not in t:
            print("  %-24s 0 matches, no defaultValue -> no data point" % name); continue
        data = [{"MetricName": metric, "Unit": t.get("unit", "Count"), "Value": n or t.get("defaultValue", 0)}]
        note = "%d match(es)" % n
    elif value.startswith("$."):
        field = value[2:]
        data = []
        for e in events:
            v = json.loads(e["message"]).get(field)
            if isinstance(v, (int, float)):
                data.append({"MetricName": metric, "Unit": t.get("unit", "None"), "Value": v,
                             "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e["timestamp"] / 1000))})
        note = "%d value(s) %s" % (len(data), [d["Value"] for d in data])
        if not data:
            print("  %-24s no extractable values" % name); continue
    else:
        raise ValueError("unsupported metricValue " + value)
    for i in range(0, len(data), 20):
        aws("cloudwatch", "put-metric-data", "--namespace", ns, "--metric-data", json.dumps(data[i:i+20]))
    print("  %-24s emulated: %s in %s over %sm -> %s/%s" % (name, note, group, window_min, ns, metric))
PY
