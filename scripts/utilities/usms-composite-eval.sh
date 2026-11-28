#!/usr/bin/env bash
# Evaluate a composite alarm's rule against the LIVE states of its children.
# For Floci builds without PutCompositeAlarm: tries the real composite first,
# otherwise reads templates/lab-13-composite-alarm.json and computes the rule.
# Supports ALARM(), OK(), INSUFFICIENT_DATA(), TRUE, FALSE, AND, OR, NOT, ().
# Prints the computed state; exit 0 = OK, 2 = ALARM.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
DOC="${1:-templates/lab-13-composite-alarm.json}"
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["AlarmName"])' "$DOC")

LIVE=$(aws cloudwatch describe-alarms --alarm-names "$NAME" --alarm-types CompositeAlarm \
         --query 'CompositeAlarms[0].StateValue' --output text 2>/dev/null)
if [ -n "$LIVE" ] && [ "$LIVE" != "None" ]; then
  echo "$NAME (real composite): $LIVE"; [ "$LIVE" = ALARM ] && exit 2 || exit 0
fi

STATES=$(aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]' --output json)
python3 - "$DOC" "$STATES" << 'PY'
import json, re, sys
doc = json.load(open(sys.argv[1]))
states = dict(json.loads(sys.argv[2]))
rule = doc["AlarmRule"]
def repl(m):
    want, name = m.group(1), m.group(2)
    if name not in states:
        sys.exit("child alarm %r does not exist - a real composite would reject this rule" % name)
    return str(states[name] == want)
expr = re.sub(r'(ALARM|OK|INSUFFICIENT_DATA)\("([^"]+)"\)', repl, rule)
expr = expr.replace("TRUE", "True").replace("FALSE", "False").replace("AND", "and").replace("OR", "or").replace("NOT", "not")
if not re.fullmatch(r'[\sA-Za-z()]*', expr) or set(re.findall(r'[A-Za-z]+', expr)) - {"True","False","and","or","not"}:
    sys.exit("unsupported token in rule: %s" % rule)
result = "ALARM" if eval(expr) else "OK"
for n in re.findall(r'\("([^"]+)"\)', rule):
    print("  child %-28s %s" % (n, states[n]))
print("%s (emulated from %s): %s" % (doc["AlarmName"], sys.argv[1], result))
sys.exit(2 if result == "ALARM" else 0)
PY
