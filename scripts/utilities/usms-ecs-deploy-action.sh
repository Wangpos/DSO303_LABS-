#!/usr/bin/env bash
# Stand-in for the CodePipeline "Deploy / ECS" action, which Floci 2.1.0 does not provide
# ("Provider ECS is not available in Floci CodePipeline"). It performs the action's four
# documented steps, and nothing else, from a build-output zip:
#   1. read the service's CURRENT task definition
#   2. replace the image of each container named in imagedefinitions.json
#   3. register-task-definition  (a new revision)
#   4. update-service --task-definition <new revision>
# Usage: usms-ecs-deploy-action.sh <build-output.zip> [cluster] [service]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
ZIP="${1:?usage: $0 <build-output.zip> [cluster] [service]}"
CLUSTER="${2:-usms-ecs-cluster}"
SERVICE="${3:-usms-enrolment-svc}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

python3 - "$ZIP" "$WORK/imagedefinitions.json" << 'PY'
import sys, zipfile, json
z = zipfile.ZipFile(sys.argv[1])
if "imagedefinitions.json" not in z.namelist():
    sys.exit("imagedefinitions.json is not at the root of the artifact: %s" % z.namelist())
d = json.loads(z.read("imagedefinitions.json"))
if not isinstance(d, list):
    sys.exit("imagedefinitions.json must be a JSON array")
open(sys.argv[2], "w").write(json.dumps(d))
PY

CURRENT=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)
echo "1. current task definition : $CURRENT"
aws ecs describe-task-definition --task-definition "$CURRENT" --query taskDefinition --output json > "$WORK/td.json"

python3 - "$WORK/td.json" "$WORK/imagedefinitions.json" "$WORK/new.json" << 'PY'
import json, sys
td, defs = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
for f in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
          "registeredAt", "registeredBy", "deregisteredAt"):
    td.pop(f, None)
names = {c["name"]: c for c in td["containerDefinitions"]}
for d in defs:
    if d["name"] not in names:
        sys.exit("container %r from imagedefinitions.json is not in the task definition (%s)" % (d["name"], list(names)))
    print("2. %s: %s -> %s" % (d["name"], names[d["name"]]["image"], d["imageUri"]))
    names[d["name"]]["image"] = d["imageUri"]
json.dump(td, open(sys.argv[3], "w"))
PY

NEW=$(aws ecs register-task-definition --cli-input-json "file://$WORK/new.json" --query 'taskDefinition.taskDefinitionArn' --output text)
echo "3. registered              : $NEW"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW" \
  --query 'service.taskDefinition' --output text | sed 's/^/4. service now points at   : /'
