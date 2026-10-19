#!/usr/bin/env bash
# Print the decision table of every Application Load Balancer whose name starts with usms-:
# load balancer -> listeners -> rules in evaluation order -> target group health.
# Read-only. No arguments. Also writes outputs/lab-05-lb-report.json.
#
# set -uo pipefail WITHOUT -e, on purpose: one failing describe call (a listener deleted mid-run,
# a build that does not implement describe-rules) should cost one line of the report, not abort
# the whole report. Every AWS call below is checked and degrades to "(unavailable)" instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""
export USMS_LB_REPORT_JSON="$REPO_ROOT/outputs/lab-05-lb-report.json"

# Four levels of nested calls and a priority sort are much easier to get right in Python than in
# shell, so bash only resolves the repository and the environment, then hands over.
python3 - <<'PY'
import json, os, subprocess

def aws(*args):
    """Run one AWS CLI call and return parsed JSON, or None if the call failed."""
    try:
        r = subprocess.run(["aws", *args, "--output", "json"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "null")
    except ValueError:
        return None

def priority_key(rule):
    # Priority is a STRING ("10", "20", "default"). Sorting it as text would put "5" after "20",
    # so convert to int and map the default action to infinity: it is always evaluated last.
    p = rule.get("Priority", "default")
    return float("inf") if p == "default" else int(p)

def tg_name(arn):
    # arn:...:targetgroup/<name>/<id>
    return arn.split(":targetgroup/")[-1].split("/")[0] if arn else "?"

health_cache = {}
def tg_health(arn):
    if arn not in health_cache:
        d = aws("elbv2", "describe-target-health", "--target-group-arn", arn)
        if d is None:
            health_cache[arn] = None
        else:
            states = [t.get("TargetHealth", {}).get("State") for t in d.get("TargetHealthDescriptions", [])]
            health_cache[arn] = {"targets": len(states), "healthy": states.count("healthy")}
    return health_cache[arn]

def condition_summary(rule):
    conds = rule.get("Conditions") or []
    if not conds:
        return "-", "-"
    c = conds[0]
    field = c.get("Field", "?")
    # Floci fills only the typed config block (PathPatternConfig etc.); real AWS also fills Values.
    values = c.get("Values") or []
    for key in ("PathPatternConfig", "HostHeaderConfig", "HttpRequestMethodConfig", "SourceIpConfig"):
        values = values or (c.get(key) or {}).get("Values") or []
    return field, ",".join(values) or "-"

def action_summary(action):
    t = action.get("Type", "?")
    if t == "forward":
        arns = [action["TargetGroupArn"]] if action.get("TargetGroupArn") else \
               [g["TargetGroupArn"] for g in (action.get("ForwardConfig") or {}).get("TargetGroups", [])]
        parts = []
        for arn in arns:
            h = tg_health(arn)
            counts = "(unavailable)" if h is None else f"({h['targets']} targets, {h['healthy']} healthy)"
            parts.append(f"{tg_name(arn)} {counts}")
        return " + ".join(parts) or "forward (no target group)", arns
    if t == "fixed-response":
        return f"fixed-response {(action.get('FixedResponseConfig') or {}).get('StatusCode', '?')}", []
    if t == "redirect":
        cfg = action.get("RedirectConfig") or {}
        return f"redirect {cfg.get('StatusCode', '?')} -> {cfg.get('Protocol', '#{protocol}')}:{cfg.get('Port', '#{port}')}", []
    return t, []

report = []
lbs = aws("elbv2", "describe-load-balancers",
          "--query", "LoadBalancers[?starts_with(LoadBalancerName,'usms-')]")
if lbs is None:
    print("describe-load-balancers failed - is Floci up? (./scripts/utilities/whoami.sh)")
    lbs = []
if not lbs:
    print("no load balancers whose name starts with usms-")

for lb in sorted(lbs, key=lambda x: x.get("LoadBalancerName", "")):
    entry = {"name": lb.get("LoadBalancerName"), "scheme": lb.get("Scheme"), "type": lb.get("Type"),
             "state": (lb.get("State") or {}).get("Code"), "azs": len(lb.get("AvailabilityZones") or []),
             "security_groups": len(lb.get("SecurityGroups") or []), "listeners": []}
    print(f"{entry['name']:<22} {entry['scheme']:<16} {entry['type']:<12} {entry['state']:<8} "
          f"AZs={entry['azs']}  SGs={entry['security_groups']}")

    ls = aws("elbv2", "describe-listeners", "--load-balancer-arn", lb["LoadBalancerArn"])
    listeners = None if ls is None else ls.get("Listeners", [])
    if listeners is None:
        print("  (listeners unavailable)")
    elif not listeners:
        print("  (no listeners - this load balancer answers nothing)")

    for li in sorted(listeners or [], key=lambda x: x.get("Port", 0)):
        lentry = {"protocol": li.get("Protocol"), "port": li.get("Port"), "rules": []}
        print(f"  {lentry['protocol']}:{lentry['port']}")
        rs = aws("elbv2", "describe-rules", "--listener-arn", li["ListenerArn"])
        rules = None if rs is None else rs.get("Rules", [])
        if rules is None:
            print("    (rules unavailable)")
            rules = [{"Priority": "default", "Actions": li.get("DefaultActions", [])}]
        if not any(r.get("Priority") != "default" for r in rules):
            print("    (no rules other than the default action)")
        for r in sorted(rules, key=priority_key):
            field, values = condition_summary(r)
            actions = r.get("Actions") or [{"Type": "?"}]
            summary, arns = action_summary(actions[0])
            print(f"    prio  {r.get('Priority', '?'):<8} {field:<13} {values:<28} -> {summary}")
            lentry["rules"].append({"priority": r.get("Priority"), "field": field, "values": values,
                                    "action": actions[0].get("Type"), "summary": summary,
                                    "target_groups": [{"name": tg_name(a), **(tg_health(a) or {})} for a in arns]})
        entry["listeners"].append(lentry)
    report.append(entry)

with open(os.environ["USMS_LB_REPORT_JSON"], "w") as f:
    json.dump(report, f, indent=2)
PY
