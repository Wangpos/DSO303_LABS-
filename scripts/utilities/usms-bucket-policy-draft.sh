#!/usr/bin/env bash
# Draft the transcripts bucket's RESOURCE policy (Lab 09 Exercise 5). Applies nothing.
#
# Reads outputs/lab-09-identity-inventory.json and every customer-managed policy whose
# document names the transcripts bucket, finds every role granted any s3: action on it
# (list-entities-for-policy per policy, then merged), and writes
# outputs/lab-09-bucket-policy-draft.json with:
#   1. an Allow per set of holders, limited to the actions they ALREADY have;
#   2. a Deny for every principal when aws:SecureTransport is false;
#   3. a Deny for every principal other than those roles and the account root.
#
# Statement 3 uses Principal "*" with an ArnNotEquals aws:PrincipalArn condition, not
# NotPrincipal. A NotPrincipal list of role ARNs does not match the assumed-role session
# ARNs (arn:aws:sts::...:assumed-role/...) that actually make the requests, so it would
# deny the very roles it means to keep. aws:PrincipalArn resolves a session to its role.
#
# Works whether or not the bucket exists. Touches no credential material of any kind.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true

INVENTORY="outputs/lab-09-identity-inventory.json"
DRAFT="outputs/lab-09-bucket-policy-draft.json"
READY="outputs/lab-09-lab10-readiness.txt"
ACCOUNT="${USMS_ACCOUNT_ID:-000000000000}"
[ -f "$INVENTORY" ] || { echo "no $INVENTORY - run Lab 09 Step 4 part 2 first" >&2; exit 2; }

# The bucket ARN comes from Lab 1's policy document: the Resource without "/*".
RW_ARN="arn:aws:iam::${ACCOUNT}:policy/USMSStudentDataReadWrite"
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" --output json \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['PolicyVersion']['Document'];d=json.loads(d) if isinstance(d,str) else d
L=lambda x:x if isinstance(x,list) else [x]
print(sorted({r for s in L(d['Statement']) for r in L(s.get('Resource',[])) if r.startswith('arn:aws:s3:::') and '/' not in r})[0])")
# Shell parameter expansion: "##*:::" deletes the longest prefix ending in ":::",
# turning arn:aws:s3:::<name> into the bare bucket name with no extra process.
BUCKET="${BUCKET_ARN##*:::}"
[ -n "$BUCKET" ] || { echo "could not derive the bucket name from $RW_ARN" >&2; exit 2; }

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then EXISTS=yes; else EXISTS=no; fi

# Holders of every policy that names the bucket, merged (users and groups too, if any).
POLICIES=$(python3 - "$INVENTORY" "$BUCKET_ARN" << 'PY'
import json, sys
inv, b = json.load(open(sys.argv[1])), sys.argv[2]
names = set()
for r in inv:
    for p in r["attachedPolicies"]:
        if b in json.dumps(p.get("document")):
            names.add(p["name"])
print(" ".join(sorted(names)))
PY
)
: > "$REPO_ROOT/outputs/.bucket-holders.tsv"
for p in $POLICIES; do
  arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$p'].Arn | [0]" --output text)
  aws iam list-entities-for-policy --policy-arn "$arn" --output json \
    | python3 -c "import json,sys;d=json.load(sys.stdin)
for r in d.get('PolicyRoles',[]): print('$p\trole\t'+r['RoleName'])
for u in d.get('PolicyUsers',[]): print('$p\tuser\t'+u['UserName'])
for g in d.get('PolicyGroups',[]): print('$p\tgroup\t'+g['GroupName'])" >> "$REPO_ROOT/outputs/.bucket-holders.tsv"
done

python3 - "$INVENTORY" "$BUCKET_ARN" "$ACCOUNT" "outputs/.bucket-holders.tsv" "$DRAFT" "$READY" "$EXISTS" << 'PY'
import fnmatch, json, sys
inv_path, bucket_arn, account, holders_path, draft_path, ready_path, exists = sys.argv[1:8]
inv = {r["role"]: r for r in json.load(open(inv_path))}
L = lambda x: x if isinstance(x, list) else ([] if x is None else [x])
obj = bucket_arn + "/*"

holders = [l.rstrip("\n").split("\t") for l in open(holders_path) if l.strip()]
policies = sorted({h[0] for h in holders})
roles = sorted({h[2] for h in holders if h[1] == "role"})
others = sorted({f"{h[1]}:{h[2]}" for h in holders if h[1] != "role"})

def actions_for(role):
    """s3 actions the role is allowed on the bucket / its objects, net of its own explicit Denies."""
    allow = {"bucket": set(), "object": set()}; deny = set()
    r = inv[role]
    for p in r["attachedPolicies"] + r["inlinePolicies"]:
        d = p.get("document") or {}
        d = json.loads(d) if isinstance(d, str) else d
        for s in L(d.get("Statement")):
            acts = [a for a in L(s.get("Action")) if a.startswith("s3:")]
            for res in L(s.get("Resource")):
                kind = "object" if res == obj or fnmatch.fnmatchcase(obj, res) and "/" in res else \
                       "bucket" if res == bucket_arn else None
                if res == "*":
                    kind = None
                if not kind:
                    continue
                if s["Effect"] == "Allow":
                    allow[kind].update(acts)
                elif s["Effect"] == "Deny":
                    deny.update(acts)
    return {k: sorted(v - deny) for k, v in allow.items()}

arn = lambda r: f"arn:aws:iam::{account}:role/{r}"
groups = {}
for r in roles:
    a = actions_for(r)
    groups.setdefault((tuple(a["bucket"]), tuple(a["object"])), []).append(arn(r))

statements = []
for i, ((b_acts, o_acts), principals) in enumerate(sorted(groups.items()), 1):
    if b_acts:
        statements.append({"Sid": f"HoldersSet{i}Bucket", "Effect": "Allow",
                           "Principal": {"AWS": sorted(principals)}, "Action": list(b_acts), "Resource": bucket_arn})
    if o_acts:
        statements.append({"Sid": f"HoldersSet{i}Objects", "Effect": "Allow",
                           "Principal": {"AWS": sorted(principals)}, "Action": list(o_acts), "Resource": obj})
statements.append({"Sid": "DenyAnyRequestNotOverTLS", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
                   "Resource": [bucket_arn, obj], "Condition": {"Bool": {"aws:SecureTransport": "false"}}})
keep = sorted(arn(r) for r in roles) + [f"arn:aws:iam::{account}:root"]
statements.append({"Sid": "DenyEveryoneButTheHoldersAndTheAccountRoot", "Effect": "Deny", "Principal": "*",
                   "Action": "s3:*", "Resource": [bucket_arn, obj],
                   "Condition": {"ArnNotEquals": {"aws:PrincipalArn": keep}}})
draft = {"Version": "2012-10-17", "Id": bucket_arn.split(":::", 1)[1] + "-draft-lab09", "Statement": statements}
json.dump(draft, open(draft_path, "w"), indent=2)

bucket = bucket_arn.split(":::", 1)[1]
with open(ready_path, "w") as f:
    f.write(f"bucket name (read from USMSStudentDataReadWrite's document): {bucket}\n")
    f.write(f"bucket exists now: {exists}\n")
    f.write(f"policies naming the bucket ({len(policies)}): {', '.join(policies)}\n")
    for p in policies:
        f.write(f"  {p:<28} -> {', '.join(arn(h[2]) for h in holders if h[0] == p and h[1] == 'role')}\n")
    f.write(f"non-role holders: {', '.join(others) or 'none'}\n")
    f.write(f"principal count (distinct roles in the Allow statements): {len(roles)}\n")
    f.write(f"draft: {draft_path} ({len(statements)} statements; applied by nobody yet)\n")
    f.write("what changes when Lab 10 runs create-bucket: the four roles above stop being granted access to "
            "nothing and can read (all four) and write (the three USMSStudentDataReadWrite holders) real transcripts, "
            "with no resource policy yet - so until the S3 configuration lab applies this draft, identity policies alone decide.\n")
print(f"draft written: {draft_path}  ({len(statements)} statements, {len(roles)} role principals)")
print(f"readiness written: {ready_path}")
PY
rc=$?
rm -f "$REPO_ROOT/outputs/.bucket-holders.tsv"
exit $rc
