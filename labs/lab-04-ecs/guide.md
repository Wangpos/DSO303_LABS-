# Lab 04 - Amazon ECS: Complete Working Guide

**Course:** DSO303 - Cloud Infrastructure & Services
**Project:** University Student Management System (USMS)
**Location:** `./labs/lab-04-ecs/guide.md`

This is a working guide for Lab 04. It reorders nothing. It follows the lab's Steps 1-13, Section 9 (verification and cleanup), the Section 13 exercises and the Section 15 review questions. Every command is complete; several commands in the PDF are cut off at the page edge, and they are reconstructed in full here. It is also adapted to this repository, which differs from the handout in a few places. Those places are marked **[repo note]**.

> **Goal of the lab, in one sentence:** deploy the USMS enrolment service on ECS Fargate in Lab 2's
> private subnets, with a correct execution role, a correct task role, a group-referenced security group
> and a service that holds `desiredCount = 2`, then record it all for Lab 05 and Lab 06.
> No auto scaling and no load balancer. Those belong to Lab 06 and Lab 05.

---

## 0. What "done" looks like

| Area | Must be true at the end |
|---|---|
| AWS resources | `usms-ecs-cluster` ACTIVE, `/usms/ecs/enrolment` (7-day retention), `usms-ecs-exec-role` + `USMSECSTaskExecution`, `usms-ecs-task-role` + Lab 1's `USMSStudentDataReadWrite`, `usms-enrolment-sg`, `usms-enrolment:1` (and `:2` after Exercise 2), `usms-enrolment-svc` desired 2 |
| Files (committed) | `policies/trust-ecs-tasks.json`, `policies/usms-ecs-task-execution-policy.json`, `policies/usms-enrolment-sg-ingress.json`, `templates/lab-04-taskdef.json`, `configs/lab-04.env` (17 exports), `scripts/utilities/verify-lab-04.sh`, `scripts/cleanup/lab-04-cleanup.sh`, `scripts/utilities/lab-04-ecs-inventory.sh`, `labs/lab-04-ecs/exercises.md` |
| Notes | `notes/lab-04-notes.md`: support path (A/B/C) at the top, the 6 review answers, and the Floci limitations hit |
| Evidence | Screenshots for Checkpoints 2, 3, 4 in `screenshots/`; `outputs/lab-04-lab03-linkage.txt` (ignored by git, see Exercise 5) |
| Verification | `./scripts/utilities/verify-lab-04.sh` reports `PASS=38 FAIL=0` (or documented benign failures) |
| Not done | `lab-04-cleanup.sh` exists and passes `bash -n`, and has **never** been run |

---

## 0.1 Screenshot plan (for the report)

Save every screenshot in `screenshots/lab-4/`, using the same naming pattern as Lab 3 (`lab4-NN-short-name.png`).
Each step that needs one is marked in the guide with **📸 Screenshot NN**: take it right after running the commands shown there.
The lab **requires** screenshots for Checkpoints 2, 3 and 4. The others are recommended, because they are the evidence a report reader will look for.

| # | File name | Taken at | What must be visible | Required? |
|---|---|---|---|---|
| 01 | `lab4-01-env-loaded.png` | Step 1 | `whoami.sh` `[ok] Account 000000000000` and all eight printed values | Recommended |
| 02 | `lab4-02-verify-lab02-lab03.png` | Step 2 | Both `PASS=.. FAIL=0` lines | Recommended |
| 03 | `lab4-03-support-probe.png` | Step 3 | Full probe output (path A/B/C evidence) | Recommended |
| 04 | `lab4-04-assumed-role.png` | Step 4 part 1 | `get-caller-identity` with `assumed-role/usms-developer-role/lab04-ecs-build` | Recommended |
| 05 | `lab4-05-cluster.png` | Step 4 verify | `describe-clusters` JSON: ACTIVE, containerInsights | Recommended |
| 06 | `lab4-06-log-group.png` | Step 5 | Log-group table with Retention 7 | Recommended |
| 07 | `lab4-07-exec-role.png` | Step 6 verify | Trust principal `ecs-tasks.amazonaws.com` + `USMSECSTaskExecution` attached | Recommended |
| 08 | `lab4-08-task-role-policy.png` | Step 7 verify | Task role attached-policies table + policy document | Recommended |
| 09 | `lab4-09-checkpoint2.png` | After Step 7 | Checkpoint 2 summary command output | **REQUIRED (Checkpoint 2)** |
| 10 | `lab4-10-enrolment-sg.png` | Step 8 verify | Inbound rule FromGroup = usms-app-sg, FromCIDR null | Recommended |
| 11 | `lab4-11-checkpoint3-taskdef.png` | Step 9 verify | Task definition JSON: awsvpc, FARGATE, 256/512, Exec ≠ Task | **REQUIRED (Checkpoint 3)** |
| 12 | `lab4-12-checkpoint4-service.png` | Step 11 | Service JSON: ACTIVE, desired 2, two subnets, DISABLED | **REQUIRED (Checkpoint 4)** |
| 13 | `lab4-13-manual-scaling.png` | Step 11 "Your turn" | desiredCount 3 then 2, plus the events list | Recommended (assessed evidence) |
| 14 | `lab4-14-lab-04-env.png` | Step 12 verify | Eight printed values + `17` | Recommended |
| 15 | `lab4-15-git-hygiene.png` | Step 13 | `git check-ignore -v` result + commit line | Recommended |
| 16 | `lab4-16-verify-lab-04.png` | Section 9.2 | `PASS=38  FAIL=0` | Recommended |
| 17 | `lab4-17-cleanup-syntax.png` | Section 9.3 | `syntax OK - do NOT run it` | Recommended |
| 18 | `lab4-18-ex1-results-svc.png` | Exercise 1 | Two ACTIVE services, desired 2 and 1 | Recommended |
| 19 | `lab4-19-ex2-revision2.png` | Exercise 2 | Service on `:2`, revision 1 still ACTIVE | Recommended |
| 20 | `lab4-20-ex3-inventory.png` | Exercise 3 | Inventory lines + "identical output from both directories" | Recommended |
| 21 | `lab4-21-ex4-delete-results.png` | Exercise 4 | `usms-results-svc` deleted + verify `FAIL=0` | Recommended |
| 22 | `lab4-22-ex5-linkage.png` | Exercise 5 | Linkage file with LOOP CLOSED (or MISMATCH) + tag audit | Recommended |

Tips: run `export AWS_PAGER=""` first, so output prints straight to the terminal instead of a pager showing `(END)`. Clear the screen (`clear`) before each command, so one screenshot shows exactly one piece of evidence.
On macOS, press `Cmd+Shift+4` and then `Space` to capture a single window.

---

## 1. Repository-specific notes (read once)

1. **[repo note] `USMS_POLICY_S3_RW` is not defined** in this repo's `configs/lab-01.env`, and Step 7 depends on it.
   Without it the policy ARN becomes `arn:aws:iam::000000000000:policy/`, and the attach fails. Define it once per terminal (Step 1 below does this):
   ```bash
   export USMS_POLICY_S3_RW="${USMS_POLICY_S3_RW:-USMSStudentDataReadWrite}"
   ```
   Optionally, append it permanently to `configs/lab-01.env`:
   ```bash
   grep -q USMS_POLICY_S3_RW configs/lab-01.env || \
     echo 'export USMS_POLICY_S3_RW="USMSStudentDataReadWrite"' >> configs/lab-01.env
   ```
2. **Repository root.** The handout says `cd ~/aws-floci-course`. That is correct for this machine. Every path below is relative to the repo root.
3. The assume-role step uses the **`usms-dev`** profile. It exists in `~/.aws/credentials`. The developer role name comes from `$USMS_ROLE_DEVELOPER` (`usms-developer-role`).
4. `lab-02.env` exports `USMS_PRIVATE_RT`, so the verify script's "private rt has NO igw route" check is a real check, not a pass against `none`.
5. The bucket name `usms-student-data` is already in `lab-03.env` as `USMS_BUCKET_NAME`.

---

## 2. Before you start - Steps 1 to 3

### Step 1 - Resume the environment and load the env files

```bash
cd ~/aws-floci-course
mkdir -p labs/lab-04-ecs screenshots notes

./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
export USMS_POLICY_S3_RW="${USMS_POLICY_S3_RW:-USMSStudentDataReadWrite}"   # [repo note] 1

./scripts/utilities/whoami.sh

printf '%-26s %s\n' \
  "private subnet a"   "$USMS_PRIVATE_SUBNET_A" \
  "private subnet b"   "$USMS_PRIVATE_SUBNET_B" \
  "app security group" "$USMS_APP_SG" \
  "vpc"                "$USMS_VPC_ID" \
  "nat gateway"        "$USMS_NAT_GW" \
  "web instance"       "$USMS_WEB_INSTANCE" \
  "region"             "$AWS_REGION_COURSE" \
  "account"            "$ACCOUNT_ID"
```

**Pass condition:** `whoami.sh` prints `[ok] Account 000000000000`, and all eight values are non-empty.
If `private subnet b` is empty, finish Lab 2 Exercise 5 first, because Step 10 needs two subnets.

> 📸 **Screenshot 01** - `screenshots/lab-4/lab4-01-env-loaded.png`: the `whoami.sh` `[ok]` line and the eight printed values.

> Every shell variable below (`CLUSTER_NAME`, `EXEC_ROLE_ARN`, ...) lives only in this terminal.
> If you close it part-way through, re-run Step 1, then `source configs/lab-04.env` (once it exists),
> or re-derive the variables you need. The **re-derive** snippets are given in Appendix C.

### Step 2 - Confirm Labs 2 and 3 are intact

```bash
./scripts/utilities/verify-lab-02.sh
./scripts/utilities/verify-lab-03.sh
```

**Pass condition:** both report `FAIL=0`. Fix any failure under `== Environment ==` first; resource failures below it are usually consequences. If the network has drifted, `scripts/utilities/repair-lab-02-network.sh` exists from Lab 03.

> 📸 **Screenshot 02** - `screenshots/lab-4/lab4-02-verify-lab02-lab03.png`: both summary lines with `FAIL=0`.

### Step 3 - Probe what this Floci build supports

```bash
probe() {
  printf '%-46s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "== ECS =="
probe "ecs list-clusters"                "aws ecs list-clusters"
probe "ecs register-task-definition"     "aws ecs register-task-definition --generate-cli-skeleton"
probe "ecs describe-services"            "aws ecs describe-services --cluster probe --services probe"

echo "== Application Auto Scaling =="
probe "describe-scalable-targets"        "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
probe "describe-scaling-policies"        "aws application-autoscaling describe-scaling-policies --service-namespace ecs"
probe "describe-scheduled-actions"       "aws application-autoscaling describe-scheduled-actions --service-namespace ecs"

echo "== CloudWatch =="
probe "cloudwatch put-metric-data"       "aws cloudwatch put-metric-data --namespace USMS/Probe --metric-name Probe --value 1"
probe "cloudwatch describe-alarms"       "aws cloudwatch describe-alarms"
probe "cloudwatch set-alarm-state"       "aws cloudwatch describe-alarms --max-items 1"

echo "== CloudWatch Logs =="
probe "logs describe-log-groups"         "aws logs describe-log-groups"
```

`describe-services --cluster probe` fails on its *argument* (`ClusterNotFoundException`). That still means ECS answered. A missing service returns a connection error or `InvalidAction` instead. If a line says `not available`, run its command without `>/dev/null` to see which error you got.

> 📸 **Screenshot 03** - `screenshots/lab-4/lab4-03-support-probe.png`: the full probe output (all four `==` sections). It is the evidence for your A/B/C path.

Decide your path and start the notes file:

| Path | Condition | Effect |
|---|---|---|
| **A** | ECS **and** Application Auto Scaling supported | Do everything as written |
| **B** | ECS supported, App Auto Scaling not | This lab is unaffected; Lab 06 uses its fallback |
| **C** | ECS not supported | Stop, tell the instructor, do Exercise 4 on paper |

```bash
cat > notes/lab-04-notes.md << 'EOF'
# Lab 04 - ECS - Notes

**Support path:** A / B / C   <-- keep the one that applies, and paste the probe output below

## Step 3 probe output

## Floci limitations hit (and what real AWS would do)

## Review questions
EOF
```

**Checkpoint 1:** Floci running under Compose (hybrid), four env files sourced, both verify scripts `FAIL=0`, path recorded.

---

## 3. Concepts you must be able to explain

**The four ECS objects**

| Object | What it is | Analogy |
|---|---|---|
| Cluster | A namespace. On Fargate it has no servers and costs nothing | A folder |
| Task definition | Versioned, **immutable** blueprint (`usms-enrolment:1`, `:2`, ...) | Lab 3's AMI |
| Task | One running copy of a revision; when it dies it is gone | A running instance |
| Service | Controller that keeps `runningCount == desiredCount` | The thing auto scaling writes to |

Auto scaling (Lab 06) changes **only the service's `desiredCount`**. It never touches the task definition.

**Execution role vs task role**

| | Execution role (`usms-ecs-exec-role`) | Task role (`usms-ecs-task-role`) |
|---|---|---|
| Used by | ECS/Fargate agent, **before** the container starts | Your application code, **inside** the container |
| Does | Pulls the image, writes log streams, reads secrets | S3 / DynamoDB / SQS calls |
| Field | `executionRoleArn` | `taskRoleArn` |
| Symptom when wrong | Task **never starts**; `stoppedReason` mentions image pull or logs | Task starts; app gets **AccessDenied** at runtime |
| Trust principal | `ecs-tasks.amazonaws.com` | `ecs-tasks.amazonaws.com` (same) |

**Fargate:** removes the instances (no patching, no capacity of your own, pay per task-second).
It does **not** remove Lab 2: each task in `awsvpc` mode gets its own ENI in your subnet, carries your security group, and obeys your route tables.

**Valid Fargate CPU/memory (strings in JSON):** 256 → 512/1024/2048; 512 → 1024-4096; 1024 → 2048-8192; 2048 → 4096-16384; 4096 → 8192-30720 (steps of 1024).

**Tag syntax differs per service:**

| Service | Syntax |
|---|---|
| EC2 | `--tag-specifications 'ResourceType=x,Tags=[{Key=K,Value=V}]'` |
| ECS | `--tags key=K,value=V` (lower case) |
| IAM | `--tags Key=K,Value=V` |
| CloudWatch Logs | `--tags K=V,K2=V2` (map) |

---

## 4. Build - Steps 4 to 11

### Step 4 - Create the cluster while holding the developer role

**Part 1 - assume the role**

```bash
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${USMS_ROLE_DEVELOPER}"

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "lab04-ecs-build" \
  --profile usms-dev \
  > outputs/lab-04-assumed-role.json

chmod 600 outputs/lab-04-assumed-role.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-04-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-04-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-04-assumed-role.json)

aws sts get-caller-identity --no-cli-pager
```

**Pass condition:** `Arn` contains `assumed-role/usms-developer-role/lab04-ecs-build`.

> 📸 **Screenshot 04** - `screenshots/lab-4/lab4-04-assumed-role.png`: the `get-caller-identity` JSON showing `assumed-role`.
> Capture only the identity output. **Never** show `outputs/lab-04-assumed-role.json`, because it contains the secret key and session token.

> These three variables now override every `--profile`. Part 3 **must** unset them; otherwise you will see
> `ExpiredToken` errors an hour from now that look unrelated.

**Part 2 - create the cluster**

```bash
CLUSTER_NAME="usms-ecs-cluster"

CLUSTER_ARN=$(aws ecs create-cluster \
  --cluster-name "$CLUSTER_NAME" \
  --settings name=containerInsights,value=enabled \
  --tags key=Name,value=usms-ecs-cluster key=Project,value=USMS key=Tier,value=app \
  --query 'cluster.clusterArn' \
  --output text)

echo "CLUSTER_ARN = $CLUSTER_ARN"
```

Expected: `arn:aws:ecs:us-east-1:000000000000:cluster/usms-ecs-cluster`.
If the developer role is denied `ecs:CreateCluster`, write that in your notes as a finding. Then unset the credentials (part 3) and create the cluster as your normal identity.

**Part 3 - restore your normal identity**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
```

**Verify**

```bash
aws ecs describe-clusters \
  --clusters "$CLUSTER_NAME" \
  --include SETTINGS \
  --query 'clusters[0].{Name:clusterName,Status:status,Services:activeServicesCount,Tasks:runningTasksCount,Settings:settings}' \
  --output json
```

**Pass condition:** `Status` `ACTIVE`, `Services` 0, `Tasks` 0, and `Settings` contains `containerInsights` = `enabled`.
If `Settings` is empty, record it as a Floci limitation: Lab 06 will then have no CPU metric to track.

> 📸 **Screenshot 05** - `screenshots/lab-4/lab4-05-cluster.png`: the `describe-clusters` JSON (ACTIVE, 0/0, containerInsights).

### Step 5 - Log group with retention

```bash
LOG_GROUP="/usms/ecs/enrolment"

aws logs create-log-group \
  --log-group-name "$LOG_GROUP" \
  --tags Project=USMS,Name=usms-enrolment-logs,Tier=app

aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP" \
  --retention-in-days 7

aws logs describe-log-groups \
  --log-group-name-prefix /usms \
  --query 'logGroups[].{Name:logGroupName,Retention:retentionInDays,Bytes:storedBytes}' \
  --output table
```

**Pass condition:** one row, `Retention` = `7`. If it shows `None`, re-run `put-retention-policy`. If it stays `None`, record it as a limitation.

> 📸 **Screenshot 06** - `screenshots/lab-4/lab4-06-log-group.png`: the `DescribeLogGroups` table with Retention `7`.

### Step 6 - Task execution role

**Part 1 - trust policy** (quoted heredoc: nothing must be expanded)

```bash
cat > policies/trust-ecs-tasks.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEcsTasksToAssumeThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

python3 -m json.tool policies/trust-ecs-tasks.json > /dev/null && echo "valid JSON"
```

**Part 2 - the role**

```bash
EXEC_ROLE_NAME="usms-ecs-exec-role"

EXEC_ROLE_ARN=$(aws iam create-role \
  --role-name "$EXEC_ROLE_NAME" \
  --assume-role-policy-document file://policies/trust-ecs-tasks.json \
  --description "ECS task execution role: pulls images and writes log streams for USMS tasks" \
  --tags Key=Name,Value=usms-ecs-exec-role Key=Project,Value=USMS Key=Tier,Value=app \
  --query 'Role.Arn' \
  --output text)

echo "EXEC_ROLE_ARN = $EXEC_ROLE_ARN"
```

**Part 3 - least-privilege permissions**

```bash
cat > policies/usms-ecs-task-execution-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PullContainerImages",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteTaskLogsToItsOwnGroupOnly",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:000000000000:log-group:/usms/ecs/enrolment:*"
    }
  ]
}
EOF

python3 -m json.tool policies/usms-ecs-task-execution-policy.json > /dev/null && echo "valid JSON"

EXEC_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSECSTaskExecution \
  --policy-document file://policies/usms-ecs-task-execution-policy.json \
  --description "Least-privilege ECS execution role permissions for the USMS enrolment service" \
  --query 'Policy.Arn' \
  --output text)

aws iam attach-role-policy \
  --role-name "$EXEC_ROLE_NAME" \
  --policy-arn "$EXEC_POLICY_ARN"

echo "EXEC_POLICY_ARN = $EXEC_POLICY_ARN"
```

Why this policy has this shape:
- `ecr:GetAuthorizationToken` must use `"Resource": "*"`. It is an account-level call with no resource.
- The logs statement is scoped to **one** log group, plus `:*` to cover its streams. AWS's managed `AmazonECSTaskExecutionRolePolicy` allows writing to *every* log group.

**Verify**

```bash
aws iam get-role --role-name "$EXEC_ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal' --output json

aws iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
  --query 'AttachedPolicies[].PolicyName' --output text
```

**Pass condition:** principal is `ecs-tasks.amazonaws.com` (**not** `ecs.amazonaws.com`), and `USMSECSTaskExecution` is attached.

> 📸 **Screenshot 07** - `screenshots/lab-4/lab4-07-exec-role.png`: the trust principal JSON and the attached policy name.

### Step 7 - Task role, reusing Lab 1's policy

```bash
TASK_ROLE_NAME="usms-ecs-task-role"

TASK_ROLE_ARN=$(aws iam create-role \
  --role-name "$TASK_ROLE_NAME" \
  --assume-role-policy-document file://policies/trust-ecs-tasks.json \
  --description "USMS enrolment container identity: reads and writes student transcripts in S3" \
  --tags Key=Name,Value=usms-ecs-task-role Key=Project,Value=USMS Key=Tier,Value=app \
  --query 'Role.Arn' \
  --output text)

echo "TASK_ROLE_ARN = $TASK_ROLE_ARN"

echo "policy = ${USMS_POLICY_S3_RW:?USMS_POLICY_S3_RW is empty - see repo note 1}"

aws iam attach-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_S3_RW}"

aws iam list-attached-role-policies --role-name "$TASK_ROLE_NAME" \
  --query 'AttachedPolicies[].{Policy:PolicyName,Arn:PolicyArn}' --output table
```

**Verify. Read the policy; this is the teaching moment.**

```bash
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_S3_RW}"
DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
  --query 'Policy.DefaultVersionId' --output text)

aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VERSION" \
  --query 'PolicyVersion.Document' --output json | tee outputs/lab-04-task-role-policy.json
```

It is the same document Lab 3 Step 11 printed: Get/Put/List on `usms-student-data`, and Deny `s3:DeleteBucket`. Two kinds of compute now hold the same permission through two different delivery mechanisms:

```
Lab 03  usms-web-01 -- instance profile -- usms-ec2-app-role  --+
                                                                 +-- USMSStudentDataReadWrite --> arn:aws:s3:::usms-student-data
Lab 04  task        -- taskRoleArn      -- usms-ecs-task-role --+                                  (does not exist yet)
```

Write this into `notes/lab-04-notes.md` now. It is Review Question 2.

> **Floci limitation:** Floci does not serve `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` to containers, so code inside
> a task would not find credentials. The chain of task definition → role → trust → policy is still what you are assessed on.

> 📸 **Screenshot 08** - `screenshots/lab-4/lab4-08-task-role-policy.png`: the task role's `ListAttachedRolePolicies` table and the policy document (S3 actions on `usms-student-data`, Deny `DeleteBucket`).

**Checkpoint 2 - REQUIRED screenshot.** Run this summary so that one screen shows the whole checkpoint:

```bash
clear
echo "== Checkpoint 2 =="
aws ecs describe-clusters --clusters usms-ecs-cluster \
  --query 'clusters[0].[clusterName,status,activeServicesCount,runningTasksCount]' --output text
aws logs describe-log-groups --log-group-name-prefix /usms/ecs \
  --query 'logGroups[].[logGroupName,retentionInDays]' --output text
for r in usms-ecs-exec-role usms-ecs-task-role; do
  printf '%-20s trusts=%-26s policies=%s\n' "$r" \
    "$(aws iam get-role --role-name $r --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)" \
    "$(aws iam list-attached-role-policies --role-name $r --query 'AttachedPolicies[].PolicyName' --output text)"
done
```

> 📸 **Screenshot 09 (REQUIRED - Checkpoint 2)** - `screenshots/lab-4/lab4-09-checkpoint2.png`: the cluster ACTIVE with 0 services and 0 tasks, the log group with `7`, and both roles trusting `ecs-tasks.amazonaws.com` with their policies.

### Step 8 - Enrolment security group, sourced from the web tier's group

```bash
ENROLMENT_SG=$(aws ec2 create-security-group \
  --group-name usms-enrolment-sg \
  --description "USMS enrolment service tasks: HTTP from the web tier security group only" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-enrolment-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app}]' \
  --query 'GroupId' \
  --output text)

echo "ENROLMENT_SG = $ENROLMENT_SG"

# UNQUOTED heredoc: $USMS_APP_SG must become a real ID now
cat > policies/usms-enrolment-sg-ingress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "$USMS_APP_SG",
        "Description": "HTTP from the USMS web tier (usms-app-sg) - the only caller of the enrolment API"
      }
    ]
  }
]
EOF

grep -q '\$' policies/usms-enrolment-sg-ingress.json && echo "UNEXPANDED VARIABLE - fix before continuing" || echo "expanded OK"

aws ec2 authorize-security-group-ingress \
  --group-id "$ENROLMENT_SG" \
  --ip-permissions file://policies/usms-enrolment-sg-ingress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

**Verify**

```bash
aws ec2 describe-security-groups --group-ids "$ENROLMENT_SG" \
  --query 'SecurityGroups[0].{Name:GroupName,Inbound:IpPermissions[].{Port:FromPort,FromGroup:UserIdGroupPairs[0].GroupId,FromCIDR:IpRanges[0].CidrIp},OutboundRules:length(IpPermissionsEgress)}' \
  --output json
```

**Pass condition:** one inbound rule on port 80, with `FromGroup` = `$USMS_APP_SG`, `FromCIDR` = `null`, and `OutboundRules` = 1. The default allow-all egress is what lets tasks reach the NAT in Step 10.

> 📸 **Screenshot 10** - `screenshots/lab-4/lab4-10-enrolment-sg.png`: the security group JSON, with `FromGroup` = your app SG ID and `FromCIDR` `null`.

Why a group and not a CIDR: tasks get new ENIs and new IPs every time they are replaced or scaled. A group reference is the only rule that survives that.

### Step 9 - Write and register the task definition

**Part 1 - the document** (UNQUOTED heredoc: five variables must expand)

```bash
cat > templates/lab-04-taskdef.json << EOF
{
  "family": "usms-enrolment",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "enrolment-api",
      "image": "public.ecr.aws/nginx/nginx:stable-alpine",
      "essential": true,
      "portMappings": [
        { "containerPort": 80, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "USMS_SERVICE", "value": "enrolment" },
        { "name": "USMS_BUCKET",  "value": "usms-student-data" },
        { "name": "AWS_REGION",   "value": "$AWS_REGION_COURSE" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$AWS_REGION_COURSE",
          "awslogs-stream-prefix": "enrolment"
        }
      }
    }
  ],
  "tags": [
    { "key": "Name",    "value": "usms-enrolment" },
    { "key": "Project", "value": "USMS" },
    { "key": "Tier",    "value": "app" },
    { "key": "Lab",     "value": "04" }
  ]
}
EOF

python3 -m json.tool templates/lab-04-taskdef.json > /dev/null \
  && echo "valid JSON" || echo "INVALID JSON - fix it before registering"

grep -c '\$' templates/lab-04-taskdef.json      # MUST print 0
grep -E '"(executionRoleArn|taskRoleArn|awslogs-group)"' templates/lab-04-taskdef.json   # no empty "" values
```

If `grep -c` prints anything other than `0`, or a role ARN is `""`, a variable was empty. Re-derive it using Appendix C and rewrite the file.

**Part 2 - register it**

```bash
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://templates/lab-04-taskdef.json \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

TASK_DEF_REVISION=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition.revision' \
  --output text)

echo "TASK_DEF_ARN      = $TASK_DEF_ARN"
echo "TASK_DEF_REVISION = $TASK_DEF_REVISION"
```

**Verify**

```bash
aws ecs describe-task-definition --task-definition usms-enrolment \
  --query 'taskDefinition.{Family:family,Revision:revision,Status:status,Network:networkMode,Compat:requiresCompatibilities,Cpu:cpu,Memory:memory,Exec:executionRoleArn,Task:taskRoleArn,LogGroup:containerDefinitions[0].logConfiguration.options."awslogs-group"}' \
  --output json
```

**Pass condition:** `ACTIVE`, `awsvpc`, `FARGATE`, `256`/`512`, and **`Exec` ≠ `Task`**.
Note the `options."awslogs-group"` quoting. Without the inner double quotes, JMESPath reads the hyphen as subtraction.

> 📸 **Screenshot 11 (REQUIRED - Checkpoint 3)** - `screenshots/lab-4/lab4-11-checkpoint3-taskdef.png`: the task-definition JSON above, showing ACTIVE, `awsvpc`, `FARGATE`, `256`/`512`, two different role ARNs in `Exec` and `Task`, and the log group.

### Step 10 - Create the service in the private subnets

```bash
SERVICE_NAME="usms-enrolment-svc"

SERVICE_ARN=$(aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition usms-enrolment \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags \
  --propagate-tags SERVICE \
  --tags key=Name,value=usms-enrolment-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 \
  --query 'service.serviceArn' \
  --output text)

echo "SERVICE_ARN = $SERVICE_ARN"
```

Shorthand rules for `--network-configuration`: no spaces, square brackets for lists, and **no quotes around IDs**.
If it will not parse, use `aws ecs create-service --generate-cli-skeleton > outputs/lab-04-create-service-skeleton.json` and pass a JSON file instead.

**Wait for it**

```bash
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  && echo "service stable" \
  || echo "waiter did not complete - check the state manually below (expected on some builds)"
```

If the waiter hangs for more than a minute, press Ctrl+C and poll:

```bash
for i in $(seq 1 12); do
  read -r d r p <<< "$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
     --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
  echo "attempt $i: desired=$d running=$r pending=$p"
  [ "$d" = "$r" ] && break
  sleep 5
done
```

`running=0` while `desired=2` is the Floci "no containers" limitation. Record it and continue; nothing in this lab depends on running tasks.

**Be able to explain the image-pull path** (the core idea of this step):

```
Fargate task (usms-private-subnet-a/b), ENI with usms-enrolment-sg (allow-all egress)
  -> usms-private-rt
       0.0.0.0/0 -> usms-nat          (registry API + image layers)
       pl-...    -> usms-s3-endpoint  (layer data stored in S3)
  -> usms-nat in usms-public-subnet-a (Elastic IP)
  -> usms-igw -> public.ecr.aws
```

Without the NAT gateway or the default route, the service would *create* fine, and every task would then fail with an image-pull timeout.

### Step 11 - Read the four numbers

```bash
aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query 'services[0].{
      Name:serviceName,
      Status:status,
      Desired:desiredCount,
      Running:runningCount,
      Pending:pendingCount,
      TaskDef:taskDefinition,
      Launch:launchType,
      Subnets:networkConfiguration.awsvpcConfiguration.subnets,
      SG:networkConfiguration.awsvpcConfiguration.securityGroups,
      PublicIP:networkConfiguration.awsvpcConfiguration.assignPublicIp
  }' \
  --output json

aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name "$SERVICE_NAME" \
  --query 'length(taskArns)' --output text

aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].events[0:3].[createdAt,message]' --output text
```

| Field | Meaning | If wrong |
|---|---|---|
| `desiredCount` | What you (later: auto scaling) asked for | Not moving means the policy is not firing |
| `runningCount` | Tasks actually up | Low for a long time: check a stopped task's `stoppedReason` |
| `pendingCount` | Tasks starting now | Stuck above 0: image pull or subnet addresses |
| `status` | `ACTIVE` / `DRAINING` / `INACTIVE` | `INACTIVE` means deleted |

**Pass condition:** `ACTIVE`, `Desired` 2, two subnet IDs equal to `$USMS_PRIVATE_SUBNET_A`/`_B`, `SG` = `$ENROLMENT_SG`, `PublicIP` `DISABLED`.

> 📸 **Screenshot 12 (REQUIRED - Checkpoint 4)** - `screenshots/lab-4/lab4-12-checkpoint4-service.png`: the service JSON above (first command), plus the task count and the events lines if they fit on screen.

**Your turn - scale by hand** (record commands and output in `exercises.md` or the notes; this is assessed evidence)

```bash
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
  --desired-count 3 --query 'service.desiredCount' --output text
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" || true
aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text

aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
  --desired-count 2 --query 'service.desiredCount' --output text
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" || true

aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].events[0:5].[createdAt,message]' --output text
```

**The count must end at 2.** Step 12 records whatever it is as Lab 06's floor.

> 📸 **Screenshot 13** - `screenshots/lab-4/lab4-13-manual-scaling.png`: the `3`, then the `2`, and the events list narrating both changes. The assessment checklist asks for this evidence.

---

## 5. Record and commit - Steps 12 and 13

### Step 12 - `configs/lab-04.env`

Unquoted heredoc. Every `$(...)` runs **now**, so a populated value is proof the resource exists.

```bash
cat > configs/lab-04.env << EOF
# Lab 04 - ECS cluster, task definition, roles and service outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Lab 05 attaches a load balancer to the service recorded here. Lab 06 registers
# this service as a scalable target, using the baseline desired count as its floor.

export USMS_ECS_CLUSTER=usms-ecs-cluster
export USMS_ECS_CLUSTER_ARN=$(aws ecs describe-clusters --clusters usms-ecs-cluster \
  --query 'clusters[0].clusterArn' --output text)

export USMS_ENROLMENT_SERVICE=usms-enrolment-svc
export USMS_ENROLMENT_SERVICE_ARN=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
export USMS_ECS_DESIRED_BASELINE=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].desiredCount' --output text)

export USMS_ENROLMENT_TASK_FAMILY=usms-enrolment
export USMS_ENROLMENT_TASK_REVISION=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.revision' --output text)
export USMS_ENROLMENT_CONTAINER=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition.containerDefinitions[0].name' --output text)
export USMS_ECS_TASK_CPU=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.cpu' --output text)
export USMS_ECS_TASK_MEMORY=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.memory' --output text)

export USMS_ENROLMENT_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-enrolment-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_ECS_EXEC_ROLE=usms-ecs-exec-role
export USMS_ECS_EXEC_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-exec-role \
  --query 'Role.Arn' --output text)
export USMS_ECS_TASK_ROLE=usms-ecs-task-role
export USMS_ECS_TASK_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-task-role \
  --query 'Role.Arn' --output text)
export USMS_POLICY_ECS_EXEC=USMSECSTaskExecution

export USMS_LOG_GROUP_ENROLMENT=/usms/ecs/enrolment
EOF

grep -n 'export .*=$\|None' configs/lab-04.env || echo "all values populated"
```

**Verify**

```bash
source configs/lab-04.env

printf '%-26s %s\n' \
  "cluster"           "$USMS_ECS_CLUSTER" \
  "service"           "$USMS_ENROLMENT_SERVICE" \
  "baseline desired"  "$USMS_ECS_DESIRED_BASELINE" \
  "task revision"     "$USMS_ENROLMENT_TASK_REVISION" \
  "container"         "$USMS_ENROLMENT_CONTAINER" \
  "task cpu / memory" "$USMS_ECS_TASK_CPU / $USMS_ECS_TASK_MEMORY" \
  "enrolment sg"      "$USMS_ENROLMENT_SG" \
  "task role"         "$USMS_ECS_TASK_ROLE_ARN"

grep -c '^export' configs/lab-04.env      # must be 17
```

**Pass condition:** `all values populated`, eight non-empty lines, `baseline desired` = `2`, count = **17**.

> 📸 **Screenshot 14** - `screenshots/lab-4/lab4-14-lab-04-env.png`: `all values populated`, the eight printed values, and `17`.

> If you later finish Exercise 2 (revision 2, memory 1024), regenerate this file by re-running the block above.
> The revision and memory values then become `2` and `1024`, and `verify-lab-04.sh` still passes.

### Section 9 first - build the two scripts before committing

Building `verify-lab-04.sh` and `lab-04-cleanup.sh` (Section 6 below) **before** Step 13 lets you commit everything in one go.

### Step 13 - Commit

**Part 1 - look before adding**

```bash
git status --short
git check-ignore -v outputs/lab-04-assumed-role.json
git ls-files outputs/
```

Check:
- nothing under `outputs/` appears in the status;
- `configs/lab-04.env` *does* appear;
- `check-ignore` prints `.gitignore:<n>:outputs/*  outputs/lab-04-assumed-role.json` (silence would mean the file is NOT ignored, so stop);
- `ls-files outputs/` lists only `outputs/.gitkeep`.

**Part 2 - commit with explicit paths, never `git add -A`**

```bash
git add labs/lab-04-ecs/ \
        configs/lab-04.env \
        policies/trust-ecs-tasks.json \
        policies/usms-ecs-task-execution-policy.json \
        policies/usms-enrolment-sg-ingress.json \
        templates/lab-04-taskdef.json \
        scripts/utilities/verify-lab-04.sh \
        scripts/cleanup/lab-04-cleanup.sh \
        notes/lab-04-notes.md

git status --short

git commit -m "Lab 04: USMS enrolment service deployed on ECS Fargate - cluster, task definition, both IAM roles, security group and service"

git log --oneline -5
```

> 📸 **Screenshot 15** - `screenshots/lab-4/lab4-15-git-hygiene.png`: the `git check-ignore -v` line, `git ls-files outputs/` showing only `.gitkeep`, and the `[main xxxxxxx] Lab 04: ...` commit line.

**Checkpoint 5:** `lab-04.env` committed with 17 exports, policies and template under version control, nothing from `outputs/` staged, and `git log` shows commits for Labs 01-04.

---

## 6. Verification and cleanup scripts - Section 9

### 9.2 `scripts/utilities/verify-lab-04.sh` (38 checks)

```bash
cat > scripts/utilities/verify-lab-04.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 04 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to run at any time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true

: "${USMS_APP_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_TASK_FAMILY:=usms-enrolment}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_EXEC_ROLE:=usms-ecs-exec-role}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_LOG_GROUP_ENROLMENT:=/usms/ecs/enrolment}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else                               printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# svc <jmespath>  -> one field from the ECS service
svc() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
          --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
# td <jmespath>   -> one field from the latest task definition revision
td()  { aws ecs describe-task-definition --task-definition "$USMS_ENROLMENT_TASK_FAMILY" \
          --query "taskDefinition.$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 01 to 03 dependencies =="
check "usms-app-sg still exists"         "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-private-subnet-a exists"     "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "usms-private-subnet-b exists"     "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B"
check "private rt still has NO igw route" \
  "aws ec2 describe-route-tables --route-table-ids ${USMS_PRIVATE_RT:-none} >/dev/null && ! aws ec2 describe-route-tables --route-table-ids ${USMS_PRIVATE_RT:-none} --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"
check "USMSStudentDataReadWrite policy exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite"

echo "== Lab 04 IAM =="
check "usms-ecs-exec-role exists"        "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE"
check "usms-ecs-task-role exists"        "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "exec role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "task role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "exec role carries USMSECSTaskExecution" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_EXEC_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -qw USMSECSTaskExecution"
check "task role REUSES Lab 01's USMSStudentDataReadWrite" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_TASK_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -qw USMSStudentDataReadWrite"

echo "== Lab 04 logging =="
check "log group $USMS_LOG_GROUP_ENROLMENT exists" \
  "aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'length(logGroups)' --output text | grep -q '^1$'"
check "log group has a retention policy set" \
  "test \"\$(aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'logGroups[0].retentionInDays' --output text)\" != None"

echo "== Lab 04 ECS =="
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "task definition family $USMS_ENROLMENT_TASK_FAMILY registered" \
  "aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY"
check "task definition uses awsvpc network mode" "test \"\$(td networkMode)\" = awsvpc"
check "task definition is FARGATE compatible"    "td requiresCompatibilities | grep -qw FARGATE"
check "exec role and task role are DIFFERENT" \
  "test \"\$(td executionRoleArn)\" != \"\$(td taskRoleArn)\""
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svc status)\" = ACTIVE"
check "service launch type is FARGATE"            "test \"\$(svc launchType)\" = FARGATE"
check "service spans TWO subnets" \
  "test \"\$(svc 'length(networkConfiguration.awsvpcConfiguration.subnets)')\" = 2"
check "service does NOT assign a public IP" \
  "test \"\$(svc networkConfiguration.awsvpcConfiguration.assignPublicIp)\" = DISABLED"
check "service carries usms-enrolment-sg" \
  "svc 'networkConfiguration.awsvpcConfiguration.securityGroups' | grep -q $USMS_ENROLMENT_SG"
check "service desiredCount is $USMS_ECS_DESIRED_BASELINE (one task per Availability Zone)" \
  "test \"\$(svc desiredCount)\" = $USMS_ECS_DESIRED_BASELINE"

echo "== Lab 04 networking =="
check "usms-enrolment-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG"
check "usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"
check "usms-enrolment-sg admits NOTHING from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG >/dev/null && ! aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"

echo "== Files and Git hygiene =="
check "configs/lab-04.env exists"            "test -f configs/lab-04.env"
check "configs/lab-04.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-04.env"
check "task definition document is valid JSON" "python3 -m json.tool templates/lab-04-taskdef.json"
check "trust policy is valid JSON"            "python3 -m json.tool policies/trust-ecs-tasks.json"
check "execution policy is valid JSON"        "python3 -m json.tool policies/usms-ecs-task-execution-policy.json"
check "no task definition document contains an unexpanded variable" \
  "! grep -q '[$]' templates/lab-04-taskdef.json"
check "no secret is tracked by git" "! git ls-files | grep -v '^outputs/.gitkeep$' | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-04.sh
bash -n scripts/utilities/verify-lab-04.sh && echo "syntax OK"
./scripts/utilities/verify-lab-04.sh
```

Expected: `PASS=38  FAIL=0` (4 + 5 + 6 + 2 + 11 + 3 + 7 = 38).

> 📸 **Screenshot 16** - `screenshots/lab-4/lab4-16-verify-lab-04.png`: the full script output ending in `PASS=38  FAIL=0`. If it does not fit on one screen, make the terminal font smaller or take two shots (`16a`, `16b`).

Two small hardening changes compared with the handout. Both stop a check from passing when a resource is missing:
- The "NO igw route" and "NOTHING from 0.0.0.0/0" checks first confirm that the resource can be described. Otherwise `! <failed command>` would pass.
- "no secret is tracked" excludes `outputs/.gitkeep`, which **is** tracked on purpose. Without the exclusion, the handout's version always fails.

**Benign failures** (record them, don't fight them):

| Check | Benign cause |
|---|---|
| anything where `Running` is 0 | The build never starts Fargate containers; no check reads `runningCount` |
| `log group has a retention policy set` | The build ignores `put-retention-policy` |
| `service spans TWO subnets` | **Not benign.** Lab 2 Exercise 5 is missing |

### 9.3 `scripts/cleanup/lab-04-cleanup.sh` (build it, DO NOT RUN IT)

```bash
cat > scripts/cleanup/lab-04-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 04, dependencies first.
# Order: service (scaled to 0) -> task definitions -> cluster -> security group -> IAM -> log group.
# Run this AFTER scripts/cleanup/lab-06-cleanup.sh and scripts/cleanup/lab-05-cleanup.sh,
# and BEFORE scripts/cleanup/lab-02-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"

cat <<'WARN'
==================================================================
  This deletes the USMS enrolment service, its ECS cluster,
  its security group, both ECS IAM roles and its log group.

  Lab 05, Lab 06 and a later storage lab all depend on some part
  of it. None of this is reversible.
  Run this AFTER lab-06-cleanup.sh and lab-05-cleanup.sh,
  and BEFORE lab-02-cleanup.sh.
==================================================================
WARN

read -r -p 'Type exactly: DELETE USMS ECS  > ' answer
[ "$answer" = "DELETE USMS ECS" ] || { echo "aborted - nothing deleted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "service: scale to zero first, then delete"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null || true
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 20
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null || true

say "task definition revisions"
for arn in $(aws ecs list-task-definitions --family-prefix "$USMS_ENROLMENT_TASK_FAMILY" \
               --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$arn" >/dev/null || true
done

say "cluster"
aws ecs delete-cluster --cluster "$USMS_ECS_CLUSTER" >/dev/null || true

say "security group (nothing may still reference it)"
[ -n "${USMS_ENROLMENT_SG:-}" ] && \
  aws ec2 delete-security-group --group-id "$USMS_ENROLMENT_SG" || true

say "IAM: detach before delete"
aws iam detach-role-policy --role-name "$USMS_ECS_EXEC_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true
aws iam detach-role-policy --role-name "$USMS_ECS_TASK_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite" || true
aws iam delete-role --role-name "$USMS_ECS_EXEC_ROLE" || true
aws iam delete-role --role-name "$USMS_ECS_TASK_ROLE" || true
aws iam delete-policy \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true

say "log group"
[ -n "${USMS_LOG_GROUP_ENROLMENT:-}" ] && \
  aws logs delete-log-group --log-group-name "$USMS_LOG_GROUP_ENROLMENT" || true

echo; echo "Lab 04 teardown complete. lab-03-cleanup.sh and lab-02-cleanup.sh may now run, in that order."
EOF

chmod +x scripts/cleanup/lab-04-cleanup.sh
bash -n scripts/cleanup/lab-04-cleanup.sh && echo "syntax OK - do NOT run it"
```

> 📸 **Screenshot 17** - `screenshots/lab-4/lab4-17-cleanup-syntax.png`: `syntax OK - do NOT run it`.

Be able to explain the order:
1. Scale to 0 before deleting the service (a graceful drain, instead of `--force` killing tasks).
2. Task definitions before the cluster. Deregistered revisions become `INACTIVE` and are never truly deleted.
3. Detach IAM policies before deleting roles, or you get `DeleteConflict`, and that error doesn't name the policy.
4. Delete the security group after the service. Otherwise you get `DependencyViolation` from task ENIs.
5. Run this script after Lab 06's and Lab 05's cleanups, and before Lab 02's.

---

## 7. Exercises - Section 13

Record commands **and** output for each exercise in `labs/lab-04-ecs/exercises.md`. Start the file:

```bash
cat > labs/lab-04-ecs/exercises.md << 'EOF'
# Lab 04 - Exercises

## Exercise 1 - a second service (usms-results-svc)

## Exercise 2 - revision 2 and a rolling deployment

## Exercise 3 - ECS configuration drift report

## Exercise 4 - enrolment week capacity plan

## Exercise 5 - close the loop to Lab 3, hand Lab 05 what it needs
EOF
```

All exercise commands assume `source configs/course.env configs/lab-02.env configs/lab-04.env` has been run in the terminal (one `source` per file).

### Exercise 1 - `usms-results-svc` (desired 1)

```bash
RESULTS_SVC_ARN=$(aws ecs create-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service-name usms-results-svc \
  --task-definition "$USMS_ENROLMENT_TASK_FAMILY" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags --propagate-tags SERVICE \
  --tags key=Project,value=USMS key=Tier,value=app key=Lab,value=04 key=Service,value=results \
  --query 'service.serviceArn' --output text)
echo "$RESULTS_SVC_ARN"

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
  --services usms-enrolment-svc usms-results-svc \
  --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount}' --output table
```

Expected: two `ACTIVE` rows, with desired 2 and 1. **Don't** add this service to `lab-04.env`; Exercise 4 deletes it.
What changes compared with Step 10: name, count and the `Service` tag. What must not change: subnets, security group, `assignPublicIp`.

> 📸 **Screenshot 18** - `screenshots/lab-4/lab4-18-ex1-results-svc.png`: the table with two ACTIVE services (desired 2 and 1).

### Exercise 2 - revision 2 and a rolling deployment

```bash
# keep the revision-1 template untouched; derive revision 2 from it
cp templates/lab-04-taskdef.json templates/lab-04-taskdef-v1.json
jq '.memory = "1024"
    | .containerDefinitions[0].environment += [{"name":"USMS_LOG_LEVEL","value":"info"}]' \
  templates/lab-04-taskdef-v1.json > templates/lab-04-taskdef-v2.json
python3 -m json.tool templates/lab-04-taskdef-v2.json >/dev/null && echo "valid JSON"
diff templates/lab-04-taskdef-v1.json templates/lab-04-taskdef-v2.json

aws ecs register-task-definition --cli-input-json file://templates/lab-04-taskdef-v2.json \
  --query 'taskDefinition.[taskDefinitionArn,memory]' --output text

aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --task-definition usms-enrolment:2 --query 'service.taskDefinition' --output text
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  || echo "waiter did not complete - poll manually (Step 10 loop)"

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{TaskDef:taskDefinition,Desired:desiredCount}' --output json
aws ecs describe-task-definition --task-definition usms-enrolment:1 \
  --query 'taskDefinition.{Revision:revision,Status:status,Memory:memory}' --output json
```

Expected: the service's `taskDefinition` ends in `:2`, and `usms-enrolment:1` is still `ACTIVE`.

> 📸 **Screenshot 19** - `screenshots/lab-4/lab4-19-ex2-revision2.png`: the `diff` (memory and `USMS_LOG_LEVEL`), the service on `:2`, and revision 1 still `ACTIVE`.
One-sentence answer: *the revision a task definition ARN points to can never change, but the service's `taskDefinition` field is just a pointer, and `update-service` moves it from `:1` to `:2` while `desiredCount`, subnets and security group stay exactly as they were.*
Afterwards, regenerate `configs/lab-04.env` (Step 12 block) so it records revision 2 and 1024 MiB, and commit the two new template files.

### Exercise 3 - `scripts/utilities/lab-04-ecs-inventory.sh`

```bash
cat > scripts/utilities/lab-04-ecs-inventory.sh << 'EOF'
#!/usr/bin/env bash
# Lab 04 Exercise 3 - one line per ECS service in the course cluster, with computed verdicts.
# Also writes outputs/lab-04-ecs-inventory.json. Read-only.
#
# set -e is deliberately OFF: one service that fails to describe (deleted mid-run, emulator gap)
# must not abort the report and silently hide every service after it. Each call is checked
# explicitly instead, and a failure is printed as an ERROR line for that service.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
OUT="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"

arns=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text) || {
  echo "ERROR: cannot list services in $CLUSTER" >&2; exit 1; }

records="[]"
for arn in $arns; do
  svc_json=$(aws ecs describe-services --cluster "$CLUSTER" --services "$arn" \
               --query 'services[0]' --output json 2>/dev/null)
  if [ -z "$svc_json" ] || [ "$svc_json" = "null" ]; then
    printf '%-20s ERROR could not describe %s\n' "${arn##*/}" "$arn"; continue
  fi

  name=$(jq -r '.serviceName'          <<< "$svc_json")
  desired=$(jq -r '.desiredCount // "N/A"' <<< "$svc_json")
  running=$(jq -r '.runningCount // "N/A"' <<< "$svc_json")
  td_arn=$(jq -r '.taskDefinition // ""'   <<< "$svc_json")
  public=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "NONE"' <<< "$svc_json")

  case "$public" in
    DISABLED) publicip=OK ;;
    ENABLED)  publicip=RISK ;;
    *)        publicip=N/A ;;     # no networkConfiguration (e.g. EC2 launch type)
  esac

  taskdef="N/A"; roles="N/A"
  if [ -n "$td_arn" ]; then
    taskdef="${td_arn##*/}"
    td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" \
                --query 'taskDefinition.{e:executionRoleArn,t:taskRoleArn}' --output json 2>/dev/null)
    if [ -n "$td_json" ]; then
      exec_r=$(jq -r '.e // ""' <<< "$td_json"); task_r=$(jq -r '.t // ""' <<< "$td_json")
      if   [ -z "$exec_r" ] || [ -z "$task_r" ]; then roles=MISSING
      elif [ "$exec_r" = "$task_r" ];          then roles=SAME
      else                                          roles=SEPARATE; fi
    else
      roles=ERROR
    fi
  fi

  printf '%-20s desired=%-3s running=%-3s taskdef=%-22s roles=%-9s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  records=$(jq --arg n "$name" --arg d "$desired" --arg r "$running" --arg t "$taskdef" \
               --arg ro "$roles" --arg p "$publicip" \
    '. + [{service:$n, desired:$d, running:$r, taskdef:$t, roles:$ro, publicip:$p}]' <<< "$records")
done

mkdir -p "$(dirname "$OUT")"
jq --arg c "$CLUSTER" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '{cluster:$c, generatedAt:$at, services:.}' <<< "$records" > "$OUT"
echo "JSON written to $OUT"
EOF

chmod +x scripts/utilities/lab-04-ecs-inventory.sh
bash -n scripts/utilities/lab-04-ecs-inventory.sh && echo "syntax OK"

# prove it runs from anywhere
(cd ~ && ~/aws-floci-course/scripts/utilities/lab-04-ecs-inventory.sh) > /tmp/inv-home.txt
(cd ~/aws-floci-course/labs/lab-04-ecs && ../../scripts/utilities/lab-04-ecs-inventory.sh) > /tmp/inv-lab.txt
diff /tmp/inv-home.txt /tmp/inv-lab.txt && echo "identical output from both directories"
cat /tmp/inv-home.txt
```

> 📸 **Screenshot 20** - `screenshots/lab-4/lab4-20-ex3-inventory.png`: `identical output from both directories` and the inventory lines (roles=SEPARATE, publicip=OK).

### Exercise 4 - Enrolment-week capacity plan (written) and deletion of `usms-results-svc`

Write the analysis in `exercises.md`. The skeleton below covers every required element. **Replace the assumed traffic numbers with your own assumptions, and state them as assumptions.**

1. **Why a fixed `desiredCount` of 2 cannot solve the 08:03 problem.** `usms-enrolment-svc` has no scalable target, no alarm and no schedule. Nothing in it reads a metric or a clock. Its capacity only changes when a human runs `update-service`, and even then each new Fargate task needs 20-60 s to start. The 08:00 spike arrives faster than a human can notice it and react.
2. **Plan, with derivations** (example assumptions: 4,000 students in 20 min, ~10 requests per registration, so 40,000 req / 1,200 s ≈ 33 req/s average and about 3× that at peak, ≈ 100 req/s; one 0.25 vCPU task handles ~20 req/s, which you should measure in Lab 05/06):
   - **Minimum 2:** one task per AZ, so the service survives an AZ failure. Too low, and an AZ loss means an outage. Too high, and you pay for idle capacity 6 days a week.
   - **Maximum 8:** 100 ÷ 20 = 5 tasks, +1 headroom, rounded to an even 6 for AZ balance, +2 for retries. Too low means a capped, overloaded service. Too high means runaway cost if a bad metric triggers scaling.
   - **Scheduled floor 6, Monday 07:45-08:30:** pre-warm before the spike, because the 20-60 s start latency makes purely reactive scaling arrive too late. Too low and 08:03 repeats; too high and you pay for 45 minutes of extra tasks, which is cheap.
   - **Trigger:** target tracking on `ECSServiceAverageCPUUtilization` ≈ 60 % (if Container Insights works), or a request-count metric after Lab 05.
3. **Cost (Fargate Linux/x86, us-east-1; verify and cite https://aws.amazon.com/fargate/pricing/ on the day):** $0.04048 per vCPU-hour, $0.004445 per GB-hour, 730 h/month.
   - Per task: 0.25 × 0.04048 + 0.5 × 0.004445 = $0.012343/h → **≈ $9.01/month**
   - Fixed at 2 tasks: **≈ $18.02/month**
   - Fixed at the peak of 8 tasks: **≈ $72.08/month**
   - Scaled (2 baseline + 4 extra for ~3 h/week ≈ 13 h/month): 18.02 + 4 × 13 × 0.012343 ≈ **$18.66/month**
4. **What to switch off: `usms-results-svc`.** Precede it with the danger admonition:

> **DANGER - irreversible.**
> **What will be deleted:** ECS service `usms-results-svc` (Exercise 1 practice only).
> **What depends on it:** nothing. It is not in `lab-04.env`, and Labs 05/06 use `usms-enrolment-svc`.
> **Reversible?** Only by re-running Exercise 1.

```bash
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc \
  --desired-count 0 --query 'service.desiredCount' --output text
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" --services usms-results-svc || sleep 10
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc \
  --query 'service.status' --output text
aws ecs list-services --cluster "$USMS_ECS_CLUSTER" --query 'serviceArns[]' --output text
./scripts/utilities/verify-lab-04.sh      # must still be FAIL=0
```

> 📸 **Screenshot 21** - `screenshots/lab-4/lab4-21-ex4-delete-results.png`: the delete status, `list-services` showing only `usms-enrolment-svc`, and the verify `FAIL=0` line.

Don't touch anything in the KEEP list (Section 9 of this guide).

### Exercise 5 - Close the loop back to Lab 3

```bash
OUT=outputs/lab-04-lab03-linkage.txt
SRC_SG=$(aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
RESOLVED=$(aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$SRC_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
source configs/lab-03.env

if [ "$RESOLVED" = "$USMS_WEB_INSTANCE" ]; then VERDICT="LOOP CLOSED"; else VERDICT="MISMATCH"; fi

{
  echo "# Lab 04 -> Lab 03 linkage ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "usms-enrolment-sg        : $USMS_ENROLMENT_SG"
  echo "inbound source group     : $SRC_SG (usms-app-sg = $USMS_APP_SG)"
  echo "running instances on it  : ${RESOLVED:-<none>}"
  echo "expected (lab-03.env)    : $USMS_WEB_INSTANCE"
  echo "verdict                  : $VERDICT"
  echo
  echo "This tcp/80 rule from usms-app-sg is temporary: Lab 05 removes it once the load balancer becomes the only caller of the enrolment service."
  echo
  echo "== ECS tag audit =="
  echo "-- cluster $USMS_ECS_CLUSTER_ARN"
  aws ecs list-tags-for-resource --resource-arn "$USMS_ECS_CLUSTER_ARN" --output table
  echo "-- service $USMS_ENROLMENT_SERVICE_ARN"
  aws ecs list-tags-for-resource --resource-arn "$USMS_ENROLMENT_SERVICE_ARN" --output table
} > "$OUT"
cat "$OUT"
```

> 📸 **Screenshot 22** - `screenshots/lab-4/lab4-22-ex5-linkage.png`: the `cat` of the linkage file (verdict line + tag tables).

On `MISMATCH`, explain it: several IDs mean a second instance carries `usms-app-sg` (for example `usms-web-02` from Lab 3's "your turn"); a different single ID means `usms-web-01` was relaunched and `lab-03.env` is stale.
If a tag list comes back empty, fix it and record the gap:

```bash
aws ecs tag-resource --resource-arn "$USMS_ECS_CLUSTER_ARN" \
  --tags key=Project,value=USMS key=Tier,value=app key=Name,value=usms-ecs-cluster
aws ecs tag-resource --resource-arn "$USMS_ENROLMENT_SERVICE_ARN" \
  --tags key=Project,value=USMS key=Tier,value=app key=Lab,value=04 key=Name,value=usms-enrolment-svc
```

> **[repo note]** The lab asks for a *committed* file, but `outputs/*` is git-ignored, and Step 13 forbids committing outputs.
> Keep `.gitignore` intact. Instead, copy the file's contents into `exercises.md` under Exercise 5, which is committed,
> and note this conflict in your report.

---

## 8. Review questions - Section 15 (answer in your own words in `notes/lab-04-notes.md`)

Points each answer must cover:

1. **"Auto scaling on the task definition."** A task definition is an immutable blueprint, so nothing can scale it. Lab 06 registers the **service** (`service/usms-ecs-cluster/usms-enrolment-svc`) as a scalable target, and the only thing scaling changes is its `desiredCount`. The **service** controller then starts or stops tasks to match. Consequence: ECS knows nothing about the target, so a manual `update-service --desired-count` will be overridden by the scaling min/max/policy, and `describe-services` shows no sign of scaling. You must look in `application-autoscaling`.
2. **The policy now on two roles.** The instance profile delivers role credentials through the instance metadata service; the task role delivers them through the container credentials endpoint (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`). Both are temporary credentials from STS, rotated automatically, and the SDK finds them with no configuration, so there is no key on disk. When the `usms-student-data` bucket is created, both chains start working at that moment with no IAM change, because the policy names the ARN, not the resource's existence.
3. **Execution role vs task role.** "Task never reaches RUNNING; `stoppedReason` mentions the image pull or logs" points at the execution role. "Task runs, but the app logs AccessDenied calling S3" points at the task role. The trust policies are identical because the same principal (`ecs-tasks.amazonaws.com`) assumes both; the difference is *when* each is used and *what it is attached to*.
4. **Group vs CIDR.** Even with a fixed count, the rule expresses intent ("only the web tier"), stays correct if the web tier's IPs change, and doesn't admit other hosts in `10.0.1.0/24` (such as the NAT). Once Lab 06 scales tasks, ENIs and IPs churn constantly, and only a group reference stays valid without rewriting.
5. **What Fargate removes and what it keeps.** It removes instances, AMIs, patching, the ECS agent fleet and capacity planning for hosts. It keeps networking: each `awsvpc` task has its own ENI in your subnet, is filtered by `usms-enrolment-sg`, and follows `usms-private-rt` → NAT, which is why the image pull works at all.
6. **Persistence scepticism.** `aws ecs describe-task-definition --task-definition usms-enrolment` right after registering looks identical in memory and hybrid mode, because it reads state from the same session. The same command, or `describe-services`/`describe-clusters`, run **after `floci-down.sh` → `floci-up.sh`** would differ: memory mode returns `ClientException`/`ClusterNotFoundException`, while hybrid returns the resources. Only a check across a restart is evidence of persistence. Constants (account ID, the cluster name typed in your command) prove nothing.

Also add to the notes:
- the Floci limitations you hit (running count, Container Insights, retention, tags, credentials endpoint, SG enforcement), each with what real AWS would do;
- the OBSERVED vs CONCEPTUAL lists from Section 12.1, according to your support path.

---

## 9. Finish - KEEP vs CLEAN UP, snapshot

**KEEP** (Labs 05/06 need these): `usms-ecs-cluster`, the `usms-enrolment` family, `usms-enrolment-svc`, `usms-enrolment-sg`, both ECS roles + `USMSECSTaskExecution`, `/usms/ecs/enrolment`, `configs/lab-04.env`, `templates/lab-04-taskdef*.json`, `verify-lab-04.sh`, everything from Labs 01-03.

**CLEAN UP** (after submitting):

```bash
rm -f outputs/lab-04-assumed-role.json
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
git status --short
```

`usms-results-svc` should already be gone (Exercise 4). **Never** run `lab-04-cleanup.sh`, `lab-03-cleanup.sh` or `lab-02-cleanup.sh` now.

**Final confirmation before Lab 05**

```bash
./scripts/utilities/verify-lab-04.sh
grep -c '^export' configs/lab-04.env          # 17
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].{Desired:desiredCount,Running:runningCount}' --output json
```

**Snapshot**

```bash
floci snapshot save lab-04-complete
# fallback if 'floci snapshot' does not exist on this build:
./scripts/setup/floci-down.sh
tar -czf ~/floci-data-lab-04.tar.gz -C "$(dirname "$FLOCI_HOST_DATA_DIR")" "$(basename "$FLOCI_HOST_DATA_DIR")"
./scripts/setup/floci-up.sh
ls -lh ~/floci-data-lab-04.tar.gz
```

**[repo note]** `course.env` sets `FLOCI_HOST_DATA_DIR` under `$COURSE_ROOT`, not `~/floci-data`. The tar command above uses the variable, so it archives the directory Floci actually uses.

Commit the remaining work (exercises, inventory script, revision-2 templates, notes):

```bash
git add labs/lab-04-ecs/ notes/lab-04-notes.md configs/lab-04.env \
        scripts/utilities/lab-04-ecs-inventory.sh \
        templates/lab-04-taskdef-v1.json templates/lab-04-taskdef-v2.json
git status --short
git commit -m "Lab 04: exercises, inventory script, revision 2 and review notes"
```

**Read ahead for Lab 05:** why an ALB target group for a Fargate service must use target type `ip`, not `instance`. Fargate tasks have no EC2 instance to register; each task is its own ENI and IP.

---

## 10. Assessment checklist (Section 14)

- [ ] `floci-storage-check.sh` FAIL=0; `whoami.sh` shows 000000000000; no `floci start` / `down -v` / `volume prune` in history
- [ ] Support path A/B/C at the top of `notes/lab-04-notes.md`
- [ ] Cluster ACTIVE; log group with retention
- [ ] Both ECS roles exist and trust `ecs-tasks.amazonaws.com`; task role carries Lab 1's original policy
- [ ] `usms-enrolment:1` awsvpc / FARGATE / two different role ARNs
- [ ] Service ACTIVE, two private subnets, `assignPublicIp` DISABLED, desired 2
- [ ] SG: tcp/80 from `usms-app-sg` only, nothing from 0.0.0.0/0
- [ ] Step 11 "Your turn" (3 → 2) recorded with the events list
- [ ] Exercise 5 linkage with LOOP CLOSED or an explained MISMATCH
- [ ] Screenshots for Checkpoints 2, 3, 4 (`lab4-09`, `lab4-11`, `lab4-12`), plus the recommended ones from the Section 0.1 plan
- [ ] `configs/lab-04.env` committed, 17 exports, no empties or `None`
- [ ] `verify-lab-04.sh` FAIL=0 (or documented benign failures)
- [ ] `lab-04-cleanup.sh` passes `bash -n` and has not been run
- [ ] Nothing under `outputs/` tracked; `git check-ignore -v` names the rule
- [ ] All six review questions answered in prose
- [ ] `exercises.md` contains all five exercises
- [ ] Every Floci limitation recorded with real-AWS behaviour

---

## Appendix A - Troubleshooting quick reference

| Symptom | Cause / fix |
|---|---|
| `ClusterNotFoundException` | `$CLUSTER_NAME` is empty in this terminal → `source configs/lab-04.env`, use `$USMS_ECS_CLUSTER`; check `aws ecs list-clusters` |
| `NoSuchEntity` on attach-role-policy for the task role | `USMS_POLICY_S3_RW` is empty → repo note 1 |
| `Task definition does not support launch type FARGATE` | `requiresCompatibilities` lacks FARGATE, or `networkMode` ≠ awsvpc; fix and register `:2`, then `update-service --task-definition usms-enrolment:2` |
| `Invalid 'cpu' setting` | cpu/memory not strings, or not a valid pair |
| `InvalidGroup.NotFound` / invalid group ID in Step 8 | Quoted heredoc used, so `$USMS_APP_SG` is literal in the JSON |
| `ExpiredToken` hours later | Step 4 part 3 skipped → `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` |
| `runningCount` stays 0 | Real AWS: `events`, then `describe-tasks` `stoppedReason` (image, meaning exec role or NAT route; log driver, meaning a missing log group). Floci: benign limitation |
| `ResourceInUseException` deleting | Scale to 0, wait, delete the service, then the cluster |
| `DeleteConflict` on a role | `list-attached-role-policies`, then detach first |
| `Could not connect to the endpoint URL` | `docker compose ps`; `./scripts/setup/floci-up.sh` |
| Everything gone after a restart | `./scripts/utilities/floci-storage-check.sh`; memory mode means restoring a snapshot |
| `create-service` rejects `--network-configuration` | Spaces or quotes inside the shorthand; use the skeleton JSON instead |

## Appendix B - New CLI/JMESPath patterns

| Pattern | Meaning |
|---|---|
| `options."awslogs-group"` | Quote a key containing a hyphen inside JMESPath |
| `--max-items N` / `--starting-token` | Client-side pagination |
| `--filters "Name=instance.group-id,Values=sg-..."` | Reverse lookup: which instances carry a group |
| `awsvpcConfiguration={subnets=[a,b],securityGroups=[c],assignPublicIp=DISABLED}` | Nested shorthand: no spaces, no quotes |

## Appendix C - Re-derive variables in a new terminal

If the terminal closed between Steps 4 and 12 (before `lab-04.env` existed):

```bash
cd ~/aws-floci-course
source configs/course.env; source configs/lab-01.env; source configs/lab-02.env; source configs/lab-03.env
export USMS_POLICY_S3_RW="${USMS_POLICY_S3_RW:-USMSStudentDataReadWrite}"
CLUSTER_NAME=usms-ecs-cluster
SERVICE_NAME=usms-enrolment-svc
LOG_GROUP=/usms/ecs/enrolment
EXEC_ROLE_NAME=usms-ecs-exec-role
TASK_ROLE_NAME=usms-ecs-task-role
EXEC_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-exec-role --query 'Role.Arn' --output text 2>/dev/null)
TASK_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-task-role --query 'Role.Arn' --output text 2>/dev/null)
EXEC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/USMSECSTaskExecution"
ENROLMENT_SG=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=usms-enrolment-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
printf '%s\n' "$EXEC_ROLE_ARN" "$TASK_ROLE_ARN" "$ENROLMENT_SG"
```

If a resource already exists because a step was half-run, `create-*` returns `EntityAlreadyExists` / `InvalidGroup.Duplicate` / similar. Re-derive its ID with the snippet above instead of creating it again.
