#!/usr/bin/env bash
# Lab 11 Exercise 5 - write outputs/lab-11-lab08b-readiness.txt, which Lab 12 Step 1 reads.
# Finds the newest build artifact, prefers the pipeline's BuildOutput, and records where
# imagedefinitions.json sits and what it says. Read-only against Floci; re-runnable.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
BUCKET=usms-pipeline-artifacts
OUT=outputs/lab-11-lab08b-readiness.txt
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix usms-enrolment-pipeline/BuildOutput/ \
      --query 'sort_by(Contents || `[]`, &LastModified)[-1].Key' --output text 2>/dev/null)
ORIGIN="pipeline BuildOutput"
if [ -z "$KEY" ] || [ "$KEY" = None ]; then
  # Floci 2.1.0 never hands SourceOutput to CodeBuild, so no BuildOutput exists. Fall back to
  # the newest artifact CodeBuild itself produced from source/usms-enrolment-src.zip.
  KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
        --query 'sort_by(Contents[?starts_with(Key, `usms-lab11-s3-check-`) || starts_with(Key, `usms-enrolment-build-`)], &LastModified)[-1].Key' \
        --output text)
  ORIGIN="standalone CodeBuild artifact (no pipeline BuildOutput exists on this Floci build)"
fi
aws s3api get-object --bucket "$BUCKET" --key "$KEY" "$TMP/a.zip" >/dev/null

{
  echo "Lab 11 -> Lab 12 readiness: the deployment contract"
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/utilities/usms-imagedefs-readiness.sh"
  echo
  echo "artifact bucket : $BUCKET"
  echo "artifact key    : $KEY"
  echo "artifact origin : $ORIGIN"
  echo "source version  : $(aws s3api head-object --bucket "$BUCKET" --key source/usms-enrolment-src.zip --query VersionId --output text)"
  python3 - "$TMP/a.zip" << 'PY'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = sorted(z.namelist())
print("artifact files  :", ", ".join(names))
at_root = "imagedefinitions.json" in names
print("imagedefinitions.json at artifact root:", "yes" if at_root else "NO")
if at_root:
    raw = z.read("imagedefinitions.json").decode()
    d = json.loads(raw)
    print("imagedefinitions.json contents:", raw.strip())
    print("is a JSON array :", isinstance(d, list), "| entries:", len(d))
    meta = json.loads(z.read("build-metadata.json"))
    print("built release   :", meta["release"], "| buildId:", meta["buildId"])
PY
  echo "ECS service container (Lab 04): $(aws ecs describe-task-definition --task-definition "$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text)" --query 'taskDefinition.containerDefinitions[0].name' --output text)"
} > "$OUT"
cat "$OUT"
