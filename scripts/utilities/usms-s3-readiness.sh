#!/usr/bin/env bash
# Lab 10 Exercise 5 - write outputs/lab-10-s3-readiness.txt: what the S3
# configuration lab inherits. Read-only against Floci; re-runnable.
# Validates (does NOT apply) outputs/lab-09-bucket-policy-draft.json.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env 2>/dev/null || true
# shellcheck disable=SC1091
source configs/lab-10.env 2>/dev/null || true

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
DRAFT=outputs/lab-09-bucket-policy-draft.json
OUT=outputs/lab-10-s3-readiness.txt
RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)

# 1. Locate the draft, or generate an equivalent from the policy's current holders.
if [ ! -f "$DRAFT" ]; then
  echo "draft missing - generating an equivalent from USMSStudentDataReadWrite holders" >&2
  aws iam list-entities-for-policy --policy-arn "$RW_ARN" --query 'PolicyRoles[].RoleName' --output text \
  | python3 -c '
import json,sys
roles=["arn:aws:iam::000000000000:role/"+r for r in sys.stdin.read().split()]
print(json.dumps({"Version":"2012-10-17","Id":"usms-student-data-draft-generated-lab10","Statement":[
 {"Sid":"HoldersGetObject","Effect":"Allow","Principal":{"AWS":roles},
  "Action":"s3:GetObject","Resource":"arn:aws:s3:::usms-student-data/*"}]},indent=2))' > "$DRAFT"
fi

ROLES_NOW=$(aws iam list-roles --query 'Roles[].Arn' --output text)
LAMBDA_ROLES=$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `usms-`)].Role' --output text)

{
echo "Lab 10 -> S3 configuration lab readiness"
echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/utilities/usms-s3-readiness.sh"
echo
echo "== Bucket"
echo "name            : $BUCKET"
echo "arn             : arn:aws:s3:::$BUCKET"
echo "region          : $(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text | sed 's/^None$/us-east-1 (S3 reports us-east-1 as None)/')"
echo "tags            : $(aws s3api get-bucket-tagging --bucket "$BUCKET" --query 'TagSet[].join(`=`,[Key,Value])' --output text)"
echo "objects under transcripts/ : $(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ --query 'length(Contents)' --output text)"
echo "all objects in the bucket (key, bytes):"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].[Key,Size]' --output text | sed 's/^/    /'
echo "versioning      : $(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null) (None = never enabled; the S3 lab enables it)"
if aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "bucket policy   : PRESENT - unexpected, Lab 10 must not apply one"
else
  echo "bucket policy   : none (NoSuchBucketPolicy) - correct, the S3 configuration lab applies it"
fi
echo
echo "== Notification (replace-only API: get-merge-put before adding SNS)"
aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output json | python3 -c '
import json,sys
for c in json.load(sys.stdin).get("LambdaFunctionConfigurations",[]):
    rules=",".join("%s=%s"%(r["Name"],r["Value"]) for r in c["Filter"]["Key"]["FilterRules"])
    print("id     :",c["Id"]); print("target :",c["LambdaFunctionArn"]); print("events :",",".join(c["Events"])); print("filter :",rules)'
echo
echo "== Functions and published versions"
for fn in usms-edge-viewer-request usms-edge-origin-response usms-transcript-notifier; do
  printf '%-28s versions=%-6s role=%s\n' "$fn" \
    "$(aws lambda list-versions-by-function --function-name "$fn" --query "Versions[?Version!='\$LATEST'].Version" --output text | tr '\t' ',')" \
    "$(aws lambda get-function-configuration --function-name "$fn" --query Role --output text | sed 's#.*/##')"
done
echo "notifier alias live -> $(aws lambda get-alias --function-name usms-transcript-notifier --name live --query FunctionVersion --output text)"
echo
echo "== CloudFront"
echo "supported       : ${USMS_CLOUDFRONT_SUPPORTED:-unknown}"
echo "distribution    : ${USMS_CLOUDFRONT_DIST_ID:-not-created} (${USMS_CLOUDFRONT_DOMAIN:-not-created})"
echo
echo "== Lab 09 bucket policy draft: $DRAFT (validated, NOT applied)"
python3 - "$DRAFT" "$BUCKET" "$ROLES_NOW" "$LAMBDA_ROLES" << 'PY'
import json, sys
draft, bucket, roles_now, lambda_roles = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), set(sys.argv[4].split())
p = json.load(open(draft))
ok_res = {'arn:aws:s3:::' + bucket, 'arn:aws:s3:::' + bucket + '/*'}
problems, principals = [], set()
for st in p['Statement']:
    res = st['Resource'] if isinstance(st['Resource'], list) else [st['Resource']]
    for r in res:
        if r not in ok_res: problems.append('%s: resource %s does not match the existing bucket' % (st['Sid'], r))
    pr = st.get('Principal')
    if isinstance(pr, dict):
        for a in (pr['AWS'] if isinstance(pr['AWS'], list) else [pr['AWS']]): principals.add(a)
    cond = st.get('Condition', {})
    for a in cond.get('ArnNotEquals', {}).get('aws:PrincipalArn', []): principals.add(a)
    if st['Effect'] == 'Deny' and 'ArnNotEquals' in cond:
        exempt = set(cond['ArnNotEquals']['aws:PrincipalArn'])
        for lr in sorted(lambda_roles - exempt):
            why = ('the notifier s3:GetObject/head_object breaks once applied - add this role to the exemption list'
                   if 'lambda-exec' in lr else 'harmless today (edge functions never touch the bucket), but listed so it is a decision')
            problems.append('%s: would DENY %s - %s' % (st['Sid'], lr, why))
for a in sorted(principals):
    if a.endswith(':root'): status = 'account root (always exists)'
    elif a in roles_now: status = 'exists'
    else: status = 'MISSING'; problems.append('principal %s does not exist' % a)
    print('  principal %-62s %s' % (a, status))
print('  resources all match arn:aws:s3:::%s[/*]: %s' % (bucket, 'yes' if not any('resource' in x for x in problems) else 'NO'))
print('  RESULT: %s' % ('valid - no mismatches' if not problems else '%d mismatch(es), reported not fixed:' % len(problems)))
for x in problems: print('    - ' + x)
PY
} > "$OUT"
cat "$OUT"
