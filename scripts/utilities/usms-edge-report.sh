#!/usr/bin/env bash
# Emit one JSON document describing every usms- Lambda function and whether it
# could be associated with CloudFront as Lambda@Edge.
#   stdout: valid JSON only        stderr: diagnostics
# Usage: usms-edge-report.sh            (works from any directory)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "listing usms- functions..." >&2
aws lambda list-functions \
  --query 'Functions[?starts_with(FunctionName, `usms-`)]' --output json > "$WORK/functions.json"

# Versions and aliases are not in list-functions; fetch them per function.
python3 -c 'import json,sys; [print(f["FunctionName"]) for f in json.load(open(sys.argv[1]))]' \
  "$WORK/functions.json" | while read -r fn; do
    echo "  reading versions and aliases of $fn" >&2
    aws lambda list-versions-by-function --function-name "$fn" \
      --query "length(Versions[?Version!='\$LATEST'])" --output text > "$WORK/$fn.versions"
    aws lambda list-aliases --function-name "$fn" \
      --query 'length(Aliases)' --output text > "$WORK/$fn.aliases"
done

python3 - "$WORK" << 'PY'
import json, os, sys
work = sys.argv[1]
out = []
for f in sorted(json.load(open(os.path.join(work, 'functions.json'))), key=lambda f: f['FunctionName']):
    name = f['FunctionName']
    runtime = f.get('Runtime') or ''          # container images have no Runtime
    memory = int(f.get('MemorySize', 128))
    timeout = int(f.get('Timeout', 3))
    env = bool((f.get('Environment') or {}).get('Variables'))
    vpc = bool((f.get('VpcConfig') or {}).get('SubnetIds'))
    versions = int(open(os.path.join(work, name + '.versions')).read().strip() or 0)
    aliases = int(open(os.path.join(work, name + '.aliases')).read().strip() or 0)
    mem_cap, t_cap = (128, 5) if 'viewer' in name else (10240, 30)
    reasons = []
    if not runtime.startswith(('nodejs', 'python')): reasons.append('runtime %s not allowed at the edge' % (runtime or 'container image'))
    if env:            reasons.append('has environment variables')
    if vpc:            reasons.append('has VPC configuration')
    if versions < 1:   reasons.append('no published version')
    if memory > mem_cap: reasons.append('memory %d > %d' % (memory, mem_cap))
    if timeout > t_cap:  reasons.append('timeout %d > %d' % (timeout, t_cap))
    out.append({'name': name, 'runtime': runtime, 'memory': memory, 'timeout': timeout,
                'versions': versions, 'aliases': aliases, 'env_vars': env,
                'edge_eligible': not reasons, 'reasons': reasons})
print(json.dumps(out, indent=2))
PY
