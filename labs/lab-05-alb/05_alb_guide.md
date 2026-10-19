# Lab 05 - Putting the ECS Service Behind an Application Load Balancer: Step-by-Step Guide

**Course:** DSO303 · **Project:** USMS · **Builds on:** Labs 01-04
**Time:** about 3 h for Sections 7 and 8, plus 75 min for the in-class assessment.

This guide follows the official Lab 05 handout step by step. Each step gives:

* **Do:** the commands, adapted to *this* repository,
* **Expect:** what a correct result looks like,
* **Write:** anything that goes into `notes/lab-05-notes.md`,
* **📸 Screenshot:** the screenshot to take, with its file name.

Screenshots go in `screenshots/lab-5/`. The names follow the Lab 04 pattern (`lab5-NN-description.png`).
The handout **requires** screenshots for Checkpoints 4, 5 and 7, marked **REQUIRED** below. The rest are
evidence for your report, as in Lab 04.

---

## 0. Read this first: where this repo differs from the handout

| Handout says | In this repo | What to do |
|---|---|---|
| `labs/lab-05-ecs-alb/` | `labs/lab-05-alb/` (this folder already exists, and Lab 04 is `labs/lab-04-ecs/`) | Use `labs/lab-05-alb/` everywhere: `exercises.md`, the report and `git add` |
| `templates/lab-04-deployment-config.json` (Step 10 fallback) | **Does not exist** | The fallback below passes the deployment configuration inline instead |
| `usms-enrolment:2` | `configs/lab-04.env` still says `USMS_ENROLMENT_TASK_REVISION=1`, but Lab 04 Exercise 2 moved the service to `:2` | Confirm in Step 2 that the service runs `:2`; containerName `enrolment-api` and port `80` are correct in `templates/lab-04-taskdef-v2.json` |
| `verify-lab-04.sh` gives `PASS=49 FAIL=0` | Your script has its own count | Only one thing matters: after Step 13, **exactly one** line changes from `ok` to `FAIL` |
| Section 8 check `no secret is tracked by git` uses `! git ls-files \| grep -q '^outputs/'` | `outputs/.gitkeep` **is tracked**, so that check would always FAIL | Use the fixed line given in Section 8.1 below |
| Commands written for bash | Your login shell is **zsh** | Type `bash` at the start of every lab terminal (see Step 1). Several loops and quoting patterns in the handout assume bash |
| Cleanup script comment "Run AFTER lab-04-cleanup.sh" (twice) | Typo in the handout: the first one is Lab 06's cleanup | Written as `lab-06-cleanup.sh` in Section 8.2 |

> **Known issue on Floci 2.0.1:** the ECS service may not keep its `loadBalancers` attachment.
> Step 10 includes a diagnose → fallback → record procedure for this. Never claim something your build
> did not do; an invented result is **-5 marks**.

### Notes file skeleton

Create this now. Several steps write into it.

```bash
cd ~/aws-floci-course
mkdir -p screenshots/lab-5
cat > notes/lab-05-notes.md << 'EOF'
# Lab 05 - ALB - Notes

**Support path:** A / B / C   <-- keep the one that applies (Step 3)

## Step 3 probe output

## Step 4 "Your turn" - HTTPS: the two missing things

## Step 6 "Your turn" - matcher (a) and (b)

## Step 10 - in-place update or fallback?

## Step 11 - ECS health vs target health table

## Step 11 "Your turn" - what you would do by hand without service registration

## Step 12 - which proof I obtained (data path or control plane)

## Step 13 - the expected verify-lab-04.sh failure

## Floci limitations hit (and what real AWS would do)

## Section 11 - observed vs reasoned about, for MY build

## Review questions (Section 14)
### Q1
### Q2
### Q3
### Q4
### Q5
### Q6
### Q7
EOF
touch labs/lab-05-alb/exercises.md
```

---

## 1. Prerequisites

* Lab 04 complete: `./scripts/utilities/verify-lab-04.sh` must report `FAIL=0` **now, before you start**.
* `usms-public-subnet-b` exists (Lab 2 Step 11 "Your turn"). Your `lab-02.env` has `USMS_PUBLIC_SUBNET_B`. ✔
* `usms-private-subnet-b` exists (Lab 2 Exercise 5). ✔
* `usms-web-01` is running with `usms-app-sg` (Lab 3).
* `echo "$AWS_PROFILE"` prints `floci` in a new terminal.
* Floci runs under Docker Compose with `FLOCI_STORAGE_MODE=hybrid`.

```bash
cd ~/aws-floci-course
for t in jq python3 docker curl; do printf '%-10s ' "$t"; command -v "$t" || echo MISSING; done
aws --version
./scripts/utilities/floci-storage-check.sh
```

**Expect:** four tools found. Your copy of `floci-storage-check.sh` is a simpler 3-section version and prints no
`PASS=16 FAIL=0` count. A correct result is:

```
=== 1. Container Status ===   running
=== 2. Storage Mode ===       FLOCI_STORAGE_MODE=hybrid
=== 3. Data Directory ===     <size>  .../aws-floci-course/floci-data   (not empty)
```

Anything other than `running`, or `FLOCI_STORAGE_MODE=memory`, is a real problem: fix it before Step 1.

Then finish the prerequisite list:

```bash
echo "$AWS_PROFILE"                                   # must print: floci
source configs/course.env
./scripts/utilities/verify-lab-04.sh | tail -3        # must be FAIL=0 BEFORE you start
```

---

## 2. Create the lab folder

The folder already exists (`labs/lab-05-alb/`). Confirm it:

```bash
ls -d labs/*
```

Files this lab creates:

```
labs/lab-05-alb/         guide.md (this), exercises.md, Report.md (later)
policies/                usms-alb-sg-ingress.json, usms-enrolment-sg-ingress-alb.json
templates/               lab-05-listener-default-actions.json, lab-05-rule-conditions.json,
                         lab-05-rule-actions.json, lab-05-service-load-balancers.json
configs/lab-05.env
scripts/utilities/verify-lab-05.sh
scripts/cleanup/lab-05-cleanup.sh
notes/lab-05-notes.md
outputs/lab-05-*         (git-ignored evidence)
```

---

## 3. Step-by-step implementation

> Run everything from `~/aws-floci-course`, in **one** terminal, in **bash**. The lab captures six ARNs in
> shell variables (`ALB_SG`, `ALB_ARN`, `ALB_DNS`, `TG_ARN`, `LISTENER_ARN`, `RULE_ARN`). If you close the
> terminal, use the **Recovery block** in Appendix A to get them back.

### Step 1 - Resume the environment and load five env files

```bash
bash                                  # switch from zsh to bash for this lab
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env

./scripts/utilities/whoami.sh

printf '%-26s %s\n' \
  "vpc"                "$USMS_VPC_ID" \
  "public subnet a"    "$USMS_PUBLIC_SUBNET_A" \
  "public subnet b"    "$USMS_PUBLIC_SUBNET_B" \
  "private subnet a"   "$USMS_PRIVATE_SUBNET_A" \
  "private subnet b"   "$USMS_PRIVATE_SUBNET_B" \
  "app security group" "$USMS_APP_SG" \
  "enrolment sg"       "$USMS_ENROLMENT_SG" \
  "web instance"       "$USMS_WEB_INSTANCE" \
  "cluster"            "$USMS_ECS_CLUSTER" \
  "service"            "$USMS_ENROLMENT_SERVICE" \
  "container"          "$USMS_ENROLMENT_CONTAINER" \
  "region"             "$AWS_REGION_COURSE"
```

**Expect:** account `000000000000`, endpoint `http://localhost:4566`, profile `floci`, and **twelve non-empty
values**. Your values should match `vpc-384d1580`, `subnet-0c2aeee0` / `subnet-ccb62227`,
`sg-385df73a6b6f8fead` (app) and `sg-9773754b5fdc6a643` (enrolment).

* `public subnet b` empty → do Lab 2 Step 11 "Your turn" first.
* `enrolment sg` empty → `configs/lab-04.env` is incomplete; redo Lab 04 Step 20.

📸 **`lab5-01-env-loaded.png`**: the whoami output and the twelve-line table.

---

### Step 2 - Confirm Labs 2, 3 and 04 are still intact

```bash
./scripts/utilities/verify-lab-02.sh | tail -3
./scripts/utilities/verify-lab-03.sh | tail -3
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-pre-verify-04.txt | tail -3

# Repo-specific: confirm the service really runs revision 2 and the container/port names
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
aws ecs describe-task-definition --task-definition usms-enrolment:2 \
  --query 'taskDefinition.containerDefinitions[].{Name:name,Ports:portMappings[].containerPort}' --output table
```

**Expect:** `FAIL=0` three times. The service runs `...task-definition/usms-enrolment:2` with desired `2`, and the
container is `enrolment-api` on port `80`.
If Lab 04 is not `FAIL=0`, **stop and fix Lab 04 first**.

📸 **`lab5-02-pre-verify.png`**: the three `PASS=… FAIL=0` lines and the `usms-enrolment:2` line.

---

### Step 3 - Probe what this Floci build supports for ELBv2

```bash
probe() {
  printf '%-48s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}
{
echo "== Elastic Load Balancing v2 =="
probe "elbv2 describe-load-balancers"          "aws elbv2 describe-load-balancers"
probe "elbv2 create-load-balancer (skeleton)"  "aws elbv2 create-load-balancer --generate-cli-skeleton"
probe "elbv2 describe-target-groups"           "aws elbv2 describe-target-groups"
probe "elbv2 create-target-group (skeleton)"   "aws elbv2 create-target-group --generate-cli-skeleton"
probe "elbv2 describe-listeners (bad arn)"     "aws elbv2 describe-listeners --load-balancer-arn probe"
probe "elbv2 describe-account-limits"          "aws elbv2 describe-account-limits"
echo "== ECS integration =="
probe "ecs update-service (skeleton)"          "aws ecs update-service --generate-cli-skeleton"
probe "ecs describe-services"                  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE"
echo "== Already used in Labs 1 to 4 =="
probe "ec2 describe-security-groups"           "aws ec2 describe-security-groups --max-items 1"
probe "ec2 describe-subnets"                   "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
} | tee outputs/lab-05-probe.txt
```

> The `describe-listeners (bad arn)` probe may print "not available" even when ELBv2 exists, because the
> call returns a ValidationError (non-zero exit). Run it by hand. A `ValidationError` about the ARN means ELBv2
> **is** present; a connection error or `InvalidAction` means it is not.

**Decide your support path:**

| Path | If | Then |
|---|---|---|
| **A - full** | describes and skeletons answer, and Step 5 later returns an ARN | Do every step as written |
| **B - control plane only** (most likely) | Objects are created, but targets never become healthy and `curl` does not connect | Do everything; record where target health stayed `initial`/`unused` |
| **C - no ELBv2** | `describe-load-balancers` fails or `create-load-balancer` gives `InvalidAction` | Stop; tell your instructor; do the conceptual parts only |

**Write:** the path at the top of `notes/lab-05-notes.md`, and paste the probe output under *Step 3*.

📸 **`lab5-03-elbv2-probe.png`**: the probe table.

**Checkpoint 1:** Floci up (hybrid); five env files sourced; three verify scripts at `FAIL=0`;
`outputs/lab-05-pre-verify-04.txt` saved; both public subnets present in two AZs; support path recorded.

---

### Step 4 - Create the load balancer's security group

**Part 1 - the group:**

```bash
ALB_SG=$(aws ec2 create-security-group \
  --group-name usms-alb-sg \
  --description "USMS enrolment load balancer: HTTP from the internet; forwards to usms-enrolment-sg" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-alb-sg},{Key=Project,Value=USMS},{Key=Tier,Value=edge},{Key=Lab,Value=05}]' \
  --query 'GroupId' \
  --output text)
echo "ALB_SG = $ALB_SG"
```

**Part 2 - the ingress rule** (quoted `'EOF'`, because this document has no variables):

```bash
cat > policies/usms-alb-sg-ingress.json << 'EOF'
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTP from the internet - this is an internet-facing load balancer and this rule is the reason it works"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-alb-sg-ingress.json > /dev/null && echo "valid JSON"

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --ip-permissions file://policies/usms-alb-sg-ingress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].{Name:GroupName,VPC:VpcId,Inbound:IpPermissions[].{Port:FromPort,CIDR:IpRanges[0].CidrIp,FromGroup:UserIdGroupPairs[0].GroupId},OutboundRules:length(IpPermissionsEgress)}' \
  --output json
```

**Expect:** `ALB_SG = sg-…`, `valid JSON`, one `sgr-…`; one inbound rule, port 80 from `0.0.0.0/0`, `FromGroup`
null, and `OutboundRules: 1`.

📸 **`lab5-04-alb-sg.png`**: `ALB_SG`, the rule ID and the verify JSON.

#### ✏️ Your turn - add tcp/443

```bash
cat > policies/usms-alb-sg-ingress-https.json << 'EOF'
[
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "IpRanges": [ { "CidrIp": "0.0.0.0/0", "Description": "HTTPS from the internet - needs an HTTPS listener and a certificate before anything answers" } ]
  }
]
EOF
python3 -m json.tool policies/usms-alb-sg-ingress-https.json > /dev/null && echo "valid JSON"
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --ip-permissions file://policies/usms-alb-sg-ingress-https.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,CIDR:IpRanges[0].CidrIp}' --output table
```

**Expect:** two rules, ports 80 and 443, both from `0.0.0.0/0`.

**Write (two sentences):** the two missing things are (1) an **HTTPS listener on port 443**, which you create
yourself and which makes something *listen* on the port, and (2) a **TLS certificate** for that listener. AWS
Certificate Manager issues public certificates **free**, but you must prove you control the **domain name**, which
you have to obtain from a registrar, by creating a DNS validation record.

> Section 8's script checks only port 80, so the 443 rule does no harm. Step 16's persistence query reads
> `IpPermissions[0]`. If the order changes after the restart, the diff will show it; that is a reorder, not data loss.

📸 **`lab5-05-alb-sg-443.png`**: the two-rule table.

---

### Step 5 - Create the Application Load Balancer

**Part 1 - create it:**

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name usms-enrolment-alb \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$USMS_PUBLIC_SUBNET_A" "$USMS_PUBLIC_SUBNET_B" \
  --security-groups "$ALB_SG" \
  --tags Key=Name,Value=usms-enrolment-alb Key=Project,Value=USMS Key=Tier,Value=edge Key=Lab,Value=05 \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
echo "ALB_ARN = $ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "ALB_DNS = $ALB_DNS"
```

> `--tags` uses capital `Key=`/`Value=`. `--subnets` is **space**-separated.

**Part 2 - wait, then read it back:**

```bash
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" \
  && echo "load balancer available" \
  || echo "waiter did not complete - poll manually below (expected on some builds)"

for i in $(seq 1 10); do
  STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].State.Code' --output text)
  printf 'poll %2d  state=%s\n' "$i" "$STATE"
  [ "$STATE" = "active" ] && break
  sleep 10
done

aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,Type:Type,Scheme:Scheme,VPC:VpcId,DNS:DNSName,IPType:IpAddressType,AZs:AvailabilityZones[].{Zone:ZoneName,Subnet:SubnetId},SGs:SecurityGroups}' \
  --output json
```

If the waiter hangs for more than a minute, press **Ctrl+C** and use the loop.

**Check, in order:** (1) `AZs` has two **different** zones; (2) `Scheme` is `internet-facing` and `Type` is `application`;
(3) `SGs` contains `$ALB_SG`; (4) `State` is `active`.

**Part 3 - load balancer attributes:**

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --attributes \
      Key=idle_timeout.timeout_seconds,Value=60 \
      Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
  --query 'Attributes[?Key==`idle_timeout.timeout_seconds` || Key==`routing.http.drop_invalid_header_fields.enabled`]' \
  --output table \
  || echo "attribute modification not supported on this build - record it and continue"
```

**Write:** record the DNS name in your notes. The ARN suffix `app/usms-enrolment-alb/<id>` is needed for
Exercise 5.

📸 **`lab5-06-alb-created-1.png`**: `ALB_ARN`, `ALB_DNS` and the state poll.
📸 **`lab5-06-alb-created-2.png`**: the describe JSON (two AZs) and the attributes table.

**Checkpoint 2:** the ALB is active, internet-facing and of type application; it has nodes in two AZs and carries
`usms-alb-sg`; there are **no listeners yet**.

---

### Step 6 - Create the target group

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name usms-enrolment-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$USMS_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path / \
  --health-check-port traffic-port \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags Key=Name,Value=usms-enrolment-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
echo "TG_ARN = $TG_ARN"
```

**Verify:**

```bash
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,Type:TargetType,Proto:Protocol,Port:Port,VPC:VpcId,HCProto:HealthCheckProtocol,HCPath:HealthCheckPath,HCPort:HealthCheckPort,Interval:HealthCheckIntervalSeconds,Timeout:HealthCheckTimeoutSeconds,Healthy:HealthyThresholdCount,Unhealthy:UnhealthyThresholdCount,Matcher:Matcher.HttpCode,LBs:length(LoadBalancerArns)}' \
  --output json

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions' --output json
```

**Expect:** `Type: ip`, `Port: 80`, your VPC, `HCPath: /`, `Interval: 30`, `Timeout: 5`, `Healthy: 2`,
`Unhealthy: 2`, `Matcher: "200"`, `LBs: 0`; target health `[]`.

> ⚠ **Never** run `aws elbv2 register-targets`. The ECS service owns the target group's contents.

📸 **`lab5-07-target-group.png`**: the describe JSON and the empty `[]`.

#### ✏️ Your turn - widen the matcher, then restore it

```bash
aws elbv2 modify-target-group --target-group-arn "$TG_ARN" --matcher HttpCode=200-399 \
  --query 'TargetGroups[0].Matcher.HttpCode' --output text
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].Matcher.HttpCode' --output text
aws elbv2 modify-target-group --target-group-arn "$TG_ARN" --matcher HttpCode=200 \
  --query 'TargetGroups[0].Matcher.HttpCode' --output text
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].Matcher.HttpCode' --output text
```

**Expect:** `200-399`, then `200`.

**Write:**
(a) An application whose `/` redirects to a login page (`302` to `/login`), for example a web portal with
sign-in, would be "unhealthy forever" under a strict `200` matcher.
(b) It would be a bug in **your work**, not in the script. A verification script encodes the *agreed
specification*; a mismatch means the build drifted from the spec. If the spec itself should change, change it
deliberately and update the script in the same commit.

📸 **`lab5-08-matcher-your-turn.png`**: `200-399`, then `200`.

---

### Step 7 - Target group attributes (deregistration delay and algorithm)

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes \
      Key=deregistration_delay.timeout_seconds,Value=30 \
      Key=load_balancing.algorithm.type,Value=least_outstanding_requests \
  --query 'Attributes[?Key==`deregistration_delay.timeout_seconds` || Key==`load_balancing.algorithm.type`].[Key,Value]' \
  --output text

aws elbv2 describe-target-group-attributes --target-group-arn "$TG_ARN" \
  --query 'Attributes[].[Key,Value]' --output table
```

**Expect:** `deregistration_delay.timeout_seconds 30`, `load_balancing.algorithm.type least_outstanding_requests`;
`stickiness.enabled false`, `slow_start.duration_seconds 0`. If the call is rejected, record it as a limitation.

The task-death sequence to remember (needed for Review Q4 and Task C):

```
ECS decides to stop T -> ECS deregisters T -> T is `draining` (no new requests, in-flight finish,
up to deregistration_delay = 30s) -> fully deregistered -> SIGTERM -> wait stopTimeout (Lab 04) -> SIGKILL
```

📸 **`lab5-09-tg-attributes.png`**: the attribute table.

---

### Step 8 - Create the listener

**Part 1 - the default action** (unquoted `EOF`, because `$TG_ARN` must expand):

```bash
cat > templates/lab-05-listener-default-actions.json << EOF
[
  {
    "Type": "forward",
    "TargetGroupArn": "$TG_ARN"
  }
]
EOF

python3 -m json.tool templates/lab-05-listener-default-actions.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-05-listener-default-actions.json      # must print 0
```

**Part 2 - create the listener:**

```bash
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions file://templates/lab-05-listener-default-actions.json \
  --tags Key=Name,Value=usms-enrolment-listener Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Listeners[0].ListenerArn' \
  --output text)
echo "LISTENER_ARN = $LISTENER_ARN"
```

**Verify:**

```bash
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Proto:Protocol,DefaultActionType:DefaultActions[0].Type,Forwards:DefaultActions[0].TargetGroupArn,SSL:SslPolicy}' \
  --output json

aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,AttachedToLoadBalancers:length(LoadBalancerArns)}' \
  --output json
```

**Expect:** `valid JSON`, `0`, a listener ARN that contains `app/usms-enrolment-alb/<id>/`; port 80, HTTP,
`forward` to `$TG_ARN`, `SSL: null`; `AttachedToLoadBalancers: 1`.

📸 **`lab5-10-checkpoint3-listener.png`**: the listener JSON and `AttachedToLoadBalancers: 1`.

**Checkpoint 3:** listener HTTP:80 → forward → `usms-enrolment-tg` (ip, GET / 30s, 200, delay 30,
least_outstanding_requests, 1 LB attached, **no targets yet**).

---

### Step 9 - Let the load balancer reach the tasks

```bash
cat > policies/usms-enrolment-sg-ingress-alb.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "$ALB_SG",
        "Description": "HTTP from usms-alb-sg - the load balancer is the only client of the enrolment tasks"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-enrolment-sg-ingress-alb.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-enrolment-sg-ingress-alb.json          # must print 0

aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --ip-permissions file://policies/usms-enrolment-sg-ingress-alb.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json
echo "usms-app-sg = $USMS_APP_SG   usms-alb-sg = $ALB_SG"
```

**Expect:** port 80 with **two** sources (`usms-app-sg` and `usms-alb-sg`) and empty `CIDRs`. Both paths existing
side by side is intended: you build the new path and prove it before removing the old one.

📸 **`lab5-11-enrolment-sg-two-sources.png`**: the JSON with both group IDs and the echo line.

---

### Step 10 - Attach the existing service to the target group

**Part 1 - the document:**

```bash
cat > templates/lab-05-service-load-balancers.json << EOF
[
  {
    "targetGroupArn": "$TG_ARN",
    "containerName": "$USMS_ENROLMENT_CONTAINER",
    "containerPort": 80
  }
]
EOF

python3 -m json.tool templates/lab-05-service-load-balancers.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-05-service-load-balancers.json         # must print 0
cat templates/lab-05-service-load-balancers.json                  # containerName must be enrolment-api
```

**Part 2 - attach it:**

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --load-balancers file://templates/lab-05-service-load-balancers.json \
  --health-check-grace-period-seconds 60 \
  --query 'service.{Name:serviceName,LB:loadBalancers,Grace:healthCheckGracePeriodSeconds,Deployments:length(deployments),TaskDef:taskDefinition}' \
  --output json
```

**Expect:** `LB` has one entry (`enrolment-api`, `80`), `Grace: 60`, `Deployments: 2` (or 1), and `TaskDef` still
`usms-enrolment:2`.

**Diagnose (Floci 2.0.1 known issue):** read the attachment back **separately**:

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{LB:loadBalancers,Grace:healthCheckGracePeriodSeconds}' --output json
```

* `LB` populated → in-place update worked. Note "in-place update" in your notes and go to Step 11.
* `update-service` failed with `InvalidParameterException` / `UnsupportedFeatureException`, or `LB` reads back `[]`
  → use the fallback.

**Fallback - recreate the service with the load balancer attached.**

> ⚠ **Read before running any delete command**
> **What will be deleted:** the ECS service `usms-enrolment-svc` and its running tasks; the cluster, task
> definitions, roles, security group and log group are untouched.
> **What depends on it:** Lab 06 registers a scalable target against this service *name*.
> **Reversible?** An identical service is one `create-service` away; every input is in `configs/lab-04.env`.
> **Effect on later labs:** none, **provided** the name, cluster, task definition and desired count are identical.

This repo has no `templates/lab-04-deployment-config.json`, so the deployment configuration is passed inline,
with the same values Lab 04 used (100/200):

```bash
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 15
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null

aws ecs create-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service-name "$USMS_ENROLMENT_SERVICE" \
  --task-definition usms-enrolment:2 \
  --desired-count "$USMS_ECS_DESIRED_BASELINE" \
  --launch-type FARGATE \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" \
  --load-balancers file://templates/lab-05-service-load-balancers.json \
  --health-check-grace-period-seconds 60 \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags \
  --propagate-tags SERVICE \
  --tags key=Name,value=usms-enrolment-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 \
  --query 'service.serviceArn' --output text
```

Then re-run the diagnose query. If `LB` **still** reads `[]`, the build cannot store the attachment. Record that in
`notes/lab-05-notes.md` (Floci limitation: "service does not retain loadBalancers; real AWS would register
targets automatically"). Continue: later checks on the service wiring become documented benign failures.

**Write:** under *Step 10*, whether you used the in-place update or the fallback, and the final read-back.

📸 **`lab5-12-service-attached.png`**: the `update-service` (or `create-service`) output and the diagnose read-back.

---

### Step 11 - Watch the targets register, and read target health

**Part 1 - watch it fill:**

```bash
for i in $(seq 1 12); do
  echo "--- poll $i ---"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table
  N=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query 'length(TargetHealthDescriptions)' --output text)
  [ "$N" -ge 2 ] && break
  sleep 10
done 2>&1 | tee outputs/lab-05-step11-targets.txt
```

**Part 2 - the service's own account of it:**

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments),Rollout:deployments[0].rolloutState,LB:loadBalancers[0].targetGroupArn}' \
  --output json
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].events[0:6].[createdAt,message]' --output text
```

**Part 3 - the two health opinions side by side:**

```bash
for t in $(aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER" --service-name "$USMS_ENROLMENT_SERVICE" \
            --query 'taskArns[]' --output text); do
  aws ecs describe-tasks --cluster "$USMS_ECS_CLUSTER" --tasks "$t" \
    --query 'tasks[0].{Task:taskArn,ECSHealth:healthStatus,Last:lastStatus,IP:attachments[].details[?name==`privateIPv4Address`].value|[]|[0]}' \
    --output text
done
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
```

**Expect (path A):** two targets, one in `10.0.3.x` (us-east-1a) and one in `10.0.4.x` (us-east-1b), `initial` →
`healthy`. **Path B:** the list may stay empty or `initial`; record exactly what you see.

**Write:** copy this table into the notes under *Step 11* (it is Review Q4 and assessment Task C):

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| HEALTHY | healthy | Working |
| HEALTHY | unhealthy | **Network path broken**: security group, subnet, or health check path returning the wrong code |
| UNHEALTHY | unhealthy | Application broken; read the container logs |
| UNKNOWN | healthy | Not a fault; the task definition has no container health check |
| anything | unused | Nothing forwards to this target group |

📸 **`lab5-13-checkpoint4-targets-1.png`**: **REQUIRED (Checkpoint 4)**: the target-health table from part 1.
📸 **`lab5-13-checkpoint4-targets-2.png`**: **REQUIRED (Checkpoint 4)**: part 2 (service JSON + events) and part 3 (ECS health next to target health).

#### ✏️ Your turn - desired count 3, then back to 2

```bash
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 3 --query 'service.desiredCount' --output text
sleep 30
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text

aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 2 --query 'service.desiredCount' --output text
sleep 45
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
```

**Expect:** three targets, then two, without you running `register-targets` or `deregister-targets` once.

**Write (one sentence):** without service registration, after every scaling event you would have to run
`register-targets` (scale-out) or `deregister-targets` (scale-in) with each task's ENI IP address by hand.

📸 **`lab5-14-desired-3-then-2.png`**: three targets, then two.

**Checkpoint 4:** the service has one `loadBalancers` entry (enrolment-api / 80); grace period 60; task definition
`:2` unchanged; targets registered **by the service**, one per private subnet.

---

### Step 12 - Prove the path, and be honest about which proof you got

**Part 1 - the data path:**

```bash
echo "ALB DNS name: $ALB_DNS"

python3 -c "
import socket,sys
try:
    print(socket.gethostbyname_ex(sys.argv[1]))
except Exception as e:
    print('does not resolve:', e)
" "$ALB_DNS"

curl -s -o /dev/null -w 'http_code=%{http_code}  time_total=%{time_total}s\n' \
     --max-time 10 "http://$ALB_DNS/" \
  || echo "curl could not connect - expected on many builds; see part 2"
```

(macOS has no `getent`, so this goes straight to the Python fallback.)

**Part 2 - the control-plane proof, which always works:**

```bash
{
  echo "== 1. The listener a client would connect to =="
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].[Protocol,Port,DefaultActions[0].Type,DefaultActions[0].TargetGroupArn]' \
    --output text

  echo
  echo "== 2. The target group that listener forwards to =="
  aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,VpcId]' \
    --output text

  echo
  echo "== 3. The targets in it, and which subnet each address belongs to =="
  for ip in $(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
                --query 'TargetHealthDescriptions[].Target.Id' --output text); do
    printf '%-16s ' "$ip"
    case "$ip" in
      10.0.3.*) echo "usms-private-subnet-a  (us-east-1a)" ;;
      10.0.4.*) echo "usms-private-subnet-b  (us-east-1b)" ;;
      *)        echo "NOT in a Lab 02 private subnet - investigate" ;;
    esac
  done

  echo
  echo "== 4. The service that put them there =="
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,loadBalancers[0].targetGroupArn,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' \
    --output text

  echo
  echo "== 5. The firewall that lets step 1 reach step 3 =="
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text
  echo "   (usms-alb-sg is $ALB_SG)"
} | tee outputs/lab-05-path-proof.txt
```

**Read it as one chain:** listener → forward to TG → targets in private subnets → registered by the service →
reachable because `usms-enrolment-sg` admits `usms-alb-sg`. If block 3 is empty, say "the build started no
containers". If block 5 lacks `$ALB_SG`, that is a real fault: go back to Step 9.

**Write:** under *Step 12*, exactly which proof you got: an `http_code=200` you actually saw, **or** "no data path;
control-plane proof in outputs/lab-05-path-proof.txt".

📸 **`lab5-15-path-proof-1.png`**: part 1 (resolution + curl result, whatever it was).
📸 **`lab5-15-path-proof-2.png`**: part 2's five blocks.

---

### Step 13 - The cutover: remove the direct path

> ⚠ **Read before running any delete command**
> **What will be deleted:** one inbound rule on `usms-enrolment-sg`, the tcp/80 rule sourced from `usms-app-sg`
> (Lab 04). Not the group, not today's rule, not any task.
> **What depends on it:** anything calling tasks by address rather than through the ALB. Here that is nothing,
> because Step 12 proved the new path first.
> **Reversible?** Yes: `policies/usms-enrolment-sg-ingress.json` + one `authorize-security-group-ingress`.
> **Effect on later labs:** `verify-lab-04.sh` reports exactly one expected failure. Lab 06 is unaffected.

**Part 1 - find the exact rule:**

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query 'SecurityGroupRules[].{Id:SecurityGroupRuleId,Egress:IsEgress,Port:FromPort,CIDR:CidrIpv4,FromGroup:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

OLD_RULE_ID=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && ReferencedGroupInfo.GroupId=='$USMS_APP_SG'].SecurityGroupRuleId | [0]" \
  --output text)
echo "rule to remove: $OLD_RULE_ID"
```

`OLD_RULE_ID` must be a real `sgr-…`, **not** `None`. `None` means the rule is gone or `$USMS_APP_SG` is empty.

**Part 2 - remove it:**

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --security-group-rule-ids "$OLD_RULE_ID" \
  --query 'Return' --output text
```

**Expect:** `True`.

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json
echo "usms-alb-sg = $ALB_SG"
echo "usms-app-sg = $USMS_APP_SG   (must NOT appear above)"
```

**Part 3 - what this did to Lab 04's script:**

```bash
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-post-verify-04.txt | tail -5
echo "== what changed =="
diff outputs/lab-05-pre-verify-04.txt outputs/lab-05-post-verify-04.txt
```

**Expect:** the diff shows **exactly one** check changing,
`ok usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)` → `FAIL …`, plus the PASS/FAIL line moving by
one (for example `PASS=N FAIL=0` → `PASS=N-1 FAIL=1`). Any other changed line is an accident; investigate it.

**Write (under *Step 13*):** the three responses and when each is right:

| Response | When it is right |
|---|---|
| Leave it, and document the expected failure | Now: Lab 04's script records what Lab 04 built |
| Update the check to assert the new source group | Exercise 2: what you would do on a real system, in the same commit |
| Delete the check | Almost never: the property still matters; only the expected value changed |

From here on, **`verify-lab-05.sh` is the script of record.**

📸 **`lab5-16-cutover-1.png`**: the rule table, `OLD_RULE_ID`, `True` and the verify JSON with one source.
📸 **`lab5-16-cutover-2.png`**: the `verify-lab-04.sh` tail and the one-check diff.

---

### Step 14 - Deploy behind a load balancer, and watch a target drain

**Part 1 - record the state before:**

```bash
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'sort(TargetHealthDescriptions[].Target.Id)' --output text
} > outputs/lab-05-pre-deploy.txt
cat outputs/lab-05-pre-deploy.txt
```

**Part 2 - force a deployment with no change:**

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --force-new-deployment \
  --query 'service.{TaskDef:taskDefinition,Deployments:length(deployments)}' \
  --output json
```

**Part 3 - watch both sides at once:**

```bash
for i in $(seq 1 15); do
  echo "--- poll $i ---"
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].deployments[].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,Rollout:rolloutState}' \
    --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
  N=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
        --query 'length(deployments)' --output text)
  [ "$N" = "1" ] && break
  sleep 8
done 2>&1 | tee outputs/lab-05-step14-deploy-polls.txt
```

Look for `initial`, `healthy` and `draining`. **One frame with `draining` next to `healthy` is the screenshot.**

**Part 4 - confirm:**

```bash
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'sort(TargetHealthDescriptions[].Target.Id)' --output text
} > outputs/lab-05-post-deploy.txt
paste outputs/lab-05-pre-deploy.txt outputs/lab-05-post-deploy.txt
```

**Expect:** the same task definition and counts, but **different addresses**. If your build never changes the
target list, prove that the tasks were replaced with `aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER"
--service-name "$USMS_ENROLMENT_SERVICE"` (compare task ARNs before and after) and record that instead.

📸 **`lab5-17-checkpoint5-deploy-1.png`**: **REQUIRED (Checkpoint 5)**: a poll frame showing `draining` next to
`healthy` (or, on path B, the polls as they really looked).
📸 **`lab5-17-checkpoint5-deploy-2.png`**: **REQUIRED (Checkpoint 5)**: the `paste` of pre/post (and the task ARN
comparison if you needed it).

---

### Step 15 - Add a listener rule

**Part 1 - the condition and the action** (both quoted, with no variables):

```bash
cat > templates/lab-05-rule-conditions.json << 'EOF'
[
  {
    "Field": "path-pattern",
    "PathPatternConfig": {
      "Values": ["/alb-health", "/alb-health/*"]
    }
  }
]
EOF

cat > templates/lab-05-rule-actions.json << 'EOF'
[
  {
    "Type": "fixed-response",
    "FixedResponseConfig": {
      "StatusCode": "200",
      "ContentType": "text/plain",
      "MessageBody": "usms-enrolment-alb ok\n"
    }
  }
]
EOF

python3 -m json.tool templates/lab-05-rule-conditions.json > /dev/null && echo "conditions valid"
python3 -m json.tool templates/lab-05-rule-actions.json    > /dev/null && echo "actions valid"
```

**Part 2 - create the rule:**

```bash
RULE_ARN=$(aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions file://templates/lab-05-rule-conditions.json \
  --actions file://templates/lab-05-rule-actions.json \
  --tags Key=Name,Value=usms-enrolment-health-rule Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Rules[0].RuleArn' \
  --output text)
echo "RULE_ARN = $RULE_ARN"

aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Default:IsDefault,Condition:Conditions[0].Field,Values:Conditions[0].Values,Action:Actions[0].Type,Status:Actions[0].FixedResponseConfig.StatusCode,TargetGroup:Actions[0].TargetGroupArn}' \
  --output json
```

**Expect:** two entries: priority `"10"` (`fixed-response`, `"200"`) and `"default"` (`forward` to the TG).

**Part 3 - test it if you have a data path:**

```bash
curl -s -o /dev/null -w '/            -> %{http_code}\n' --max-time 10 "http://$ALB_DNS/" || true
curl -s -w '/alb-health  -> %{http_code}  body: %{size_download} bytes\n' --max-time 10 \
     "http://$ALB_DNS/alb-health" || true
```

If neither answers, the `describe-rules` output is your evidence.

📸 **`lab5-18-checkpoint6-rule.png`**: `RULE_ARN` and the `describe-rules` JSON (plus curl results, if any).

---

### Step 16 - Prove the whole thing survives a restart

**Part 1 - record the truth:**

```bash
{
  aws elbv2 describe-load-balancers --names usms-enrolment-alb \
    --query 'LoadBalancers[0].[LoadBalancerName,Scheme,Type,State.Code,length(AvailabilityZones),length(SecurityGroups)]' --output text
  aws elbv2 describe-target-groups --names usms-enrolment-tg \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,Matcher.HttpCode,HealthCheckIntervalSeconds,UnhealthyThresholdCount]' --output text
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'sort_by(Listeners,&Port)[].[Port,Protocol,DefaultActions[0].Type]' --output text
  aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query 'sort_by(Rules,&Priority)[].[Priority,Actions[0].Type]' --output text
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,status,desiredCount,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
  aws ec2 describe-security-groups --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp]' --output text
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].[GroupName,length(IpPermissions[0].UserIdGroupPairs)]' --output text
} > outputs/lab-05-pre-restart.txt
cat outputs/lab-05-pre-restart.txt
```

**Part 2 - perturb** (this is `docker compose stop`, so state is kept; **never** use `down -v`):

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
source configs/course.env
source configs/lab-02.env
source configs/lab-04.env
```

**Part 3 - re-derive every ARN from the API, then compare:**

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].DNSName' --output text)       # repo addition: Step 17 needs it

echo "re-derived:"
printf '  %s\n' "$ALB_ARN" "$TG_ARN" "$LISTENER_ARN" "$ALB_SG"

{
  aws elbv2 describe-load-balancers --names usms-enrolment-alb \
    --query 'LoadBalancers[0].[LoadBalancerName,Scheme,Type,State.Code,length(AvailabilityZones),length(SecurityGroups)]' --output text
  aws elbv2 describe-target-groups --names usms-enrolment-tg \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,Matcher.HttpCode,HealthCheckIntervalSeconds,UnhealthyThresholdCount]' --output text
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'sort_by(Listeners,&Port)[].[Port,Protocol,DefaultActions[0].Type]' --output text
  aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query 'sort_by(Rules,&Priority)[].[Priority,Actions[0].Type]' --output text
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,status,desiredCount,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
  aws ec2 describe-security-groups --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp]' --output text
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].[GroupName,length(IpPermissions[0].UserIdGroupPairs)]' --output text
} > outputs/lab-05-post-restart.txt

diff outputs/lab-05-pre-restart.txt outputs/lab-05-post-restart.txt \
  && echo "PERSISTENCE PROVEN: the load balancer, its two Availability Zones, its security group, the target group with its full health check configuration, the listener, the rule, the service's loadBalancers entry and the grace period are all unchanged" \
  || echo "PERSISTENCE FAILED: read the diff above, then run ./scripts/utilities/floci-storage-check.sh"
```

**Expect:** four re-derived identifiers and `PERSISTENCE PROVEN`. On `FAILED`, read the diff first. The `usms-alb-sg`
line can differ only because the 443 rule from Step 4 moved to `IpPermissions[0]`. That is a reorder, not data
loss; explain it if it happens.

📸 **`lab5-19-checkpoint7-persistence.png`**: **REQUIRED (Checkpoint 7)**: the re-derived ARNs and the
`PERSISTENCE PROVEN` line.

---

### Step 17 - Close the loop, and audit what this lab created

```bash
source configs/lab-03.env

{
echo "== 1. Who can reach the load balancer? =="
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,FromCIDR:IpRanges[].CidrIp,FromGroup:UserIdGroupPairs[].GroupId}' \
  --output json

echo
echo "== 2. Who can reach the tasks? =="
TASK_SOURCE=$(aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
echo "source group: $TASK_SOURCE"
if [ "$TASK_SOURCE" = "$ALB_SG" ]; then
  echo "CUTOVER CONFIRMED: the ONLY thing that may open a connection to an enrolment task is usms-alb-sg"
else
  echo "MISMATCH: expected $ALB_SG (usms-alb-sg), found $TASK_SOURCE - re-read Steps 9 and 13"
fi

echo
echo "== 3. And who is the client of the load balancer, in the story? =="
aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$USMS_APP_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,Subnet:SubnetId}' \
  --output table
CARRIER=$(aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$USMS_APP_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$CARRIER" = "$USMS_WEB_INSTANCE" ]; then
  echo "LOOP CLOSED: usms-web-01 ($CARRIER) still carries usms-app-sg, but now calls $ALB_DNS instead of a task address"
else
  echo "NOTE: usms-app-sg is carried by $CARRIER; lab-03.env records $USMS_WEB_INSTANCE"
fi

echo
echo "== 4. Audit: everything this lab tagged Lab=05 =="
aws ec2 describe-security-groups --filters "Name=tag:Lab,Values=05" \
  --query 'SecurityGroups[].[GroupName,GroupId]' --output text
aws elbv2 describe-tags --resource-arns "$ALB_ARN" "$TG_ARN" \
  --query 'TagDescriptions[].{Resource:ResourceArn,Tags:Tags[?Key==`Lab`].Value|[0]}' \
  --output table \
  || echo "elbv2 describe-tags not supported on this build - record it and continue"
} | tee outputs/lab-05-step17-audit.txt
```

**Expect:** `CUTOVER CONFIRMED` and `LOOP CLOSED`. `MISMATCH` is a real fault. `NOTE` usually means `usms-web-01`
is stopped or was relaunched (Lab 04's report records it was stopped once). Start it, or explain the NOTE.
If an ELBv2 resource has no tags, add them with
`aws elbv2 add-tags --resource-arns ... --tags Key=Lab,Value=05` and record that you did.

📸 **`lab5-20-loop-closed-audit.png`**: `CUTOVER CONFIRMED`, `LOOP CLOSED` and the tag audit.

---

### Step 18 - Write `configs/lab-05.env`

Unquoted `EOF`, so every `$(...)` runs now. Note the escaped `\`` in the listener line.

```bash
cat > configs/lab-05.env << EOF
# Lab 05 - ECS service behind an Application Load Balancer
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Sourced alongside lab-01/02/03/04. Lab 06 sources this
# file for the target group its ALBRequestCountPerTarget policy names.

export USMS_ALB_NAME=usms-enrolment-alb
export USMS_ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
export USMS_ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
export USMS_ALB_SCHEME=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].Scheme' --output text)
export USMS_ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_TG_NAME=usms-enrolment-tg
export USMS_TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
export USMS_TG_TARGET_TYPE=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetType' --output text)
export USMS_TG_HEALTH_PATH=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].HealthCheckPath' --output text)

export USMS_ALB_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'Listeners[?Port==\`80\`].ListenerArn | [0]' --output text)

export USMS_ALB_LISTENER_PORT=80
export USMS_ALB_HEALTH_RULE_PATH=/alb-health

export USMS_SVC_LB_CONTAINER=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerName' --output text)
export USMS_SVC_LB_PORT=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerPort' --output text)
export USMS_SVC_GRACE_PERIOD=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].healthCheckGracePeriodSeconds' --output text)
EOF

grep -n 'export .*=$\|None' configs/lab-05.env || echo "all values populated"
```

**Verify:**

```bash
source configs/lab-05.env
printf '%-26s %s\n' \
  "alb name"     "$USMS_ALB_NAME" \
  "alb scheme"   "$USMS_ALB_SCHEME" \
  "alb dns"      "$USMS_ALB_DNS" \
  "alb sg"       "$USMS_ALB_SG" \
  "target group" "$USMS_TG_NAME" \
  "target type"  "$USMS_TG_TARGET_TYPE" \
  "health path"  "$USMS_TG_HEALTH_PATH" \
  "listener"     "$USMS_ALB_LISTENER_ARN" \
  "lb container" "$USMS_SVC_LB_CONTAINER" \
  "lb port"      "$USMS_SVC_LB_PORT" \
  "grace period" "$USMS_SVC_GRACE_PERIOD"
grep -c '^export' configs/lab-05.env
```

**Expect:** `all values populated`, eleven non-empty lines, **15** exports; `ip`, `enrolment-api`, `80`, `60`.
A `None` in the `SVC_*` lines means the service lost its `loadBalancers` attachment (the Floci 2.0.1 issue, see
Step 10). Record it rather than hand-editing the file.

📸 **`lab5-21-lab-05-env.png`**: `all values populated`, the eleven-line table and `15`.

---

### Step 19 - Commit

Do Section 8 (both scripts) **before** this step, so that a single commit includes them.

**Part 1 - look before you add:**

```bash
git status --short
git check-ignore -v outputs/lab-05-path-proof.txt
git ls-files outputs/
```

**Expect:** nothing under `outputs/` in `git status`; `.gitignore:6:outputs/*  outputs/lab-05-path-proof.txt` (your
line number); `git ls-files outputs/` lists only `outputs/.gitkeep`.

**Part 2 - commit with explicit paths** (never `git add -A`):

```bash
git add labs/lab-05-alb/ \
        notes/lab-05-notes.md \
        configs/lab-05.env \
        policies/usms-alb-sg-ingress.json \
        policies/usms-alb-sg-ingress-https.json \
        policies/usms-enrolment-sg-ingress-alb.json \
        templates/lab-05-listener-default-actions.json \
        templates/lab-05-rule-conditions.json \
        templates/lab-05-rule-actions.json \
        templates/lab-05-service-load-balancers.json \
        scripts/utilities/verify-lab-05.sh \
        scripts/cleanup/lab-05-cleanup.sh \
        screenshots/lab-5/
git status --short
git commit -m "Lab 05: USMS enrolment service behind an Application Load Balancer - ALB, target group, listener, rule, service attachment and the security cutover"
git log --oneline -6
```

> Your git status also shows uncommitted Lab 04 files (`labs/lab-04-ecs/Report.md`, `screenshots/lab-4/`, …).
> Commit those separately in their own "Lab 04" commit, so the Lab 05 commit holds only Lab 05.

📸 **`lab5-22-git-hygiene.png`**: `check-ignore -v`, `ls-files outputs/`, and the commit plus `git log`.

**Checkpoint 8:** `lab-05.env` committed with 15 exports; nothing in `outputs/` staged; `check-ignore` names the rule.

---

## 4. Section 8 - Verification

### 8.1 Build `scripts/utilities/verify-lab-05.sh`

Transcribed from the handout, with **one repo fix** on the final check (marked), because `outputs/.gitkeep` is
tracked here.

```bash
cat > scripts/utilities/verify-lab-05.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 05 artefact exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true

# Defaults so that set -u cannot abort the script before it has told you anything.
: "${USMS_VPC_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PUBLIC_SUBNET_B:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_CONTAINER:=enrolment-api}"
: "${USMS_ALB_NAME:=usms-enrolment-alb}"
: "${USMS_ALB_SG:=none}"
: "${USMS_TG_NAME:=usms-enrolment-tg}"
: "${USMS_TG_ARN:=none}"
: "${USMS_ALB_LISTENER_ARN:=}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# One field from the load balancer, the target group, a target group attribute, or the service.
lbq()    { aws elbv2 describe-load-balancers --names "$USMS_ALB_NAME" \
             --query "LoadBalancers[0].$1" --output text; }
tgq()    { aws elbv2 describe-target-groups --names "$USMS_TG_NAME" \
             --query "TargetGroups[0].$1" --output text; }
tgattr() { aws elbv2 describe-target-group-attributes --target-group-arn "$(tgq TargetGroupArn)" \
             --query "Attributes[?Key=='$1'].Value | [0]" --output text; }
svcq()   { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
             --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
sgsrc()  { aws ec2 describe-security-groups --group-ids "$1" \
             --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text; }
az()     { aws ec2 describe-subnets --subnet-ids "$1" \
             --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null; }

# Listeners and rules have no names, so walk down from the load balancer.
LARN="${USMS_ALB_LISTENER_ARN}"
if [ -z "$LARN" ] || [ "$LARN" = "None" ]; then
  LARN=$(aws elbv2 describe-listeners --load-balancer-arn "$(lbq LoadBalancerArn)" \
           --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo none)
fi

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 02 to 04 dependencies =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "usms-public-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_B"
check "the two public subnets are in TWO different AZs" \
  "test -n \"\$(az $USMS_PUBLIC_SUBNET_A)\" && test \"\$(az $USMS_PUBLIC_SUBNET_A)\" != \"\$(az $USMS_PUBLIC_SUBNET_B)\""
check "usms-app-sg still exists" "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svcq status)\" = ACTIVE"

echo "== Lab 05 security groups =="
check "usms-alb-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG"
check "usms-alb-sg admits tcp/80 from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"
check "usms-enrolment-sg admits tcp/80 from usms-alb-sg" \
  "sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_ALB_SG"
check "cutover done: usms-enrolment-sg no longer admits usms-app-sg" \
  "! sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_APP_SG"

echo "== Lab 05 load balancer =="
check "load balancer $USMS_ALB_NAME exists" "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME"
check "load balancer state is active"        "test \"\$(lbq 'State.Code')\" = active"
check "scheme is internet-facing"            "test \"\$(lbq Scheme)\" = internet-facing"
check "type is application"                  "test \"\$(lbq Type)\" = application"
check "spans TWO availability zones"         "test \"\$(lbq 'length(AvailabilityZones)')\" = 2"
check "carries usms-alb-sg" \
  "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME --query 'LoadBalancers[0].SecurityGroups' --output text | grep -qw $USMS_ALB_SG"

echo "== Lab 05 target group =="
check "target group $USMS_TG_NAME exists" "aws elbv2 describe-target-groups --names $USMS_TG_NAME"
check "target type is ip (mandatory for awsvpc)" "test \"\$(tgq TargetType)\" = ip"
check "protocol HTTP on port 80" \
  "test \"\$(tgq Protocol)\" = HTTP && test \"\$(tgq Port)\" = 80"
check "target group lives in usms-vpc" "test \"\$(tgq VpcId)\" = $USMS_VPC_ID"
check "health check is GET / with matcher 200" \
  "test \"\$(tgq HealthCheckPath)\" = / && test \"\$(tgq 'Matcher.HttpCode')\" = 200"
check "deregistration delay is 30 seconds" \
  "test \"\$(tgattr deregistration_delay.timeout_seconds)\" = 30"

echo "== Lab 05 listener and rule =="
check "a listener exists on port 80" "test \"\$LARN\" != none && test -n \"\$LARN\""
check "listener default action forwards to $USMS_TG_NAME" \
  "aws elbv2 describe-listeners --listener-arns \"\$LARN\" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "at least one non-default rule exists" \
  "test \"\$(aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'length(Rules[?IsDefault==\`false\`])' --output text)\" -ge 1"
check "the non-default rule returns a fixed-response 200" \
  "aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'Rules[?IsDefault==\`false\`].Actions[0].FixedResponseConfig.StatusCode' --output text | grep -q 200"

echo "== Lab 05 service wiring =="
check "service has exactly ONE loadBalancers entry" "test \"\$(svcq 'length(loadBalancers)')\" = 1"
check "it names $USMS_TG_NAME" \
  "svcq 'loadBalancers[0].targetGroupArn' | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "containerName is $USMS_ENROLMENT_CONTAINER" \
  "test \"\$(svcq 'loadBalancers[0].containerName')\" = $USMS_ENROLMENT_CONTAINER"
check "containerPort is 80" "test \"\$(svcq 'loadBalancers[0].containerPort')\" = 80"
check "healthCheckGracePeriodSeconds is set (not None, not 0)" \
  "test \"\$(svcq healthCheckGracePeriodSeconds)\" != None && test \"\$(svcq healthCheckGracePeriodSeconds)\" -gt 0"
check "service still spans two private subnets" \
  "test \"\$(svcq 'length(networkConfiguration.awsvpcConfiguration.subnets)')\" = 2"
check "service still assigns NO public IP" \
  "test \"\$(svcq 'networkConfiguration.awsvpcConfiguration.assignPublicIp')\" = DISABLED"
check "exactly ONE deployment (nothing stuck mid-roll)" \
  "test \"\$(svcq 'length(deployments)')\" = 1"

echo "== Files and Git hygiene =="
check "configs/lab-05.env exists" "test -f configs/lab-05.env"
check "configs/lab-05.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-05.env"
check "policies/usms-alb-sg-ingress.json is valid JSON" \
  "python3 -m json.tool policies/usms-alb-sg-ingress.json"
check "policies/usms-enrolment-sg-ingress-alb.json is valid JSON" \
  "python3 -m json.tool policies/usms-enrolment-sg-ingress-alb.json"
check "templates/lab-05-listener-default-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-listener-default-actions.json"
check "templates/lab-05-rule-conditions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-conditions.json"
check "templates/lab-05-rule-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-actions.json"
check "templates/lab-05-service-load-balancers.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-service-load-balancers.json"
check "no Lab 05 document contains an unexpanded variable" \
  "! grep -q '[\$]' templates/lab-05-listener-default-actions.json templates/lab-05-service-load-balancers.json policies/usms-enrolment-sg-ingress-alb.json"
# REPO FIX: outputs/.gitkeep is deliberately tracked, so exclude it from this check.
check "no secret is tracked by git" "! git ls-files | grep '^outputs/' | grep -qv '^outputs/.gitkeep$'"

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Lab 02 to 04 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh, verify-lab-03.sh and verify-lab-04.sh before re-reading
anything here. Remember that verify-lab-04.sh is EXPECTED to report exactly one
failure after Step 13, on the usms-app-sg source check.
REMEDY
fi

[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-05.sh
bash -n scripts/utilities/verify-lab-05.sh && echo "syntax OK"
./scripts/utilities/verify-lab-05.sh | tee outputs/lab-05-verify.txt
```

**Expect:** `PASS=49  FAIL=0`.

**Known benign failures** (record them in the notes rather than fighting them):

| Check | Benign cause |
|---|---|
| deregistration delay is 30 seconds | `modify-target-group-attributes` not implemented |
| load balancer state is active | the build stays in `provisioning` |
| the non-default rule returns a fixed-response 200 | `create-rule` not implemented |
| healthCheckGracePeriodSeconds is set | the flag is accepted but not stored |
| exactly ONE deployment | the build reports zero deployments |
| the service-wiring checks (Floci 2.0.1) | the service does not retain `loadBalancers` (Step 10) |

**Not benign:** the two public subnets in different AZs, and the cutover check. Go and fix those.

📸 **`lab5-23-verify-lab-05.png`**: the full run ending in `PASS=49 FAIL=0` (take two shots, `-1`/`-2`, if it
scrolls).

### 8.2 Build the end-of-course cleanup script

> ⚠ **DO NOT RUN THIS SCRIPT NOW.** It deletes the service, rule, listener, ALB, target group and `usms-alb-sg`.
> End-of-course order, inside-out: `lab-06-cleanup.sh` → **`lab-05-cleanup.sh`** → `lab-04-cleanup.sh` →
> `lab-03-cleanup.sh` → `lab-02-cleanup.sh`.

```bash
cat > scripts/cleanup/lab-05-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 05, dependencies first.
# Order: service -> rules -> listener -> load balancer -> target group -> security group.
# Run AFTER scripts/cleanup/lab-06-cleanup.sh and BEFORE scripts/cleanup/lab-04-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"
source "$REPO_ROOT/configs/lab-05.env"

cat <<'WARN'
============================================================
  This deletes the USMS enrolment SERVICE, the Application
  Load Balancer usms-enrolment-alb, its listener and rule,
  the target group usms-enrolment-tg and the security group
  usms-alb-sg.

  Lab 06, Lab 09 and the CloudFormation lab depend on parts
  of it. None of this is reversible.

  Run AFTER  lab-06-cleanup.sh
  Run BEFORE lab-04-cleanup.sh
============================================================
WARN

# Refuse while Lab 06's scaling configuration still points at this service.
RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"
TARGETS=$(aws application-autoscaling describe-scalable-targets \
            --service-namespace ecs --resource-ids "$RID" \
            --query 'length(ScalableTargets)' --output text 2>/dev/null || echo 0)
if [ "$TARGETS" != "0" ] && [ "$TARGETS" != "None" ]; then
  echo "REFUSING: a scalable target still exists for $RID"
  echo "Run scripts/cleanup/lab-06-cleanup.sh first."
  exit 1
fi

read -r -p 'Type exactly: DELETE USMS LOAD BALANCER  > ' answer
[ "$answer" = "DELETE USMS LOAD BALANCER" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "service: scale to zero, wait, then delete (this frees the targets)"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null || true
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 20
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null || true

say "listener rules (deleting the listener would take them anyway; explicit is clearer)"
LARN=$(aws elbv2 describe-listeners --load-balancer-arn "$USMS_ALB_ARN" \
         --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || echo None)
if [ "$LARN" != "None" ] && [ -n "$LARN" ]; then
  for r in $(aws elbv2 describe-rules --listener-arn "$LARN" \
               --query 'Rules[?IsDefault==`false`].RuleArn' --output text); do
    aws elbv2 delete-rule --rule-arn "$r" >/dev/null || true
  done
  say "listener"
  aws elbv2 delete-listener --listener-arn "$LARN" >/dev/null || true
fi

say "load balancer (must go before the target group it forwarded to)"
aws elbv2 delete-load-balancer --load-balancer-arn "$USMS_ALB_ARN" >/dev/null || true
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$USMS_ALB_ARN" 2>/dev/null || sleep 20

say "target group"
aws elbv2 delete-target-group --target-group-arn "$USMS_TG_ARN" >/dev/null || true

say "security group (only after the load balancer's interfaces are gone)"
aws ec2 delete-security-group --group-id "$USMS_ALB_SG" || \
  echo "  still in use - wait for the load balancer's ENIs to be released, then retry"

echo
echo "Lab 05 teardown complete. scripts/cleanup/lab-04-cleanup.sh may now run."
EOF

chmod +x scripts/cleanup/lab-05-cleanup.sh
bash -n scripts/cleanup/lab-05-cleanup.sh && echo "syntax OK - do NOT run it"
```

📸 **`lab5-24-cleanup-syntax.png`**: `syntax OK - do NOT run it`.

---

## 5. Section 12 - Independent exercises

Record commands and output in `labs/lab-05-alb/exercises.md`. Screenshots go in `screenshots/lab-5/`.

### Exercise 1 - a second path (`/results` → `usms-results-tg`)

1. Create `usms-results-tg`: `--target-type ip`, HTTP 80, `usms-vpc`, health check `/`, `--matcher HttpCode=200-399`,
   and tags `Project=USMS Tier=app Lab=05 Service=results`. Then set `deregistration_delay.timeout_seconds` to 15.
2. Write `templates/lab-05-ex1-rule-conditions.json` (`path-pattern`, values `/results` and `/results/*`) and
   `templates/lab-05-ex1-rule-actions.json` (`forward` to `$RESULTS_TG_ARN`, an **unquoted** heredoc).
3. `create-rule --priority 20` on `$LISTENER_ARN`, capturing `RESULTS_RULE_ARN=$(...)`.
4. Read back sorted: `aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query 'sort_by(Rules,&Priority)[].[Priority,Conditions[0].Values,Actions[0].Type]' --output text`
   (`Priority` is a string; `"default"` sorts after the digits).
5. `describe-target-health` on the results TG returns `[]`; `describe-target-groups` shows `length(LoadBalancerArns)` = 1.

Do **not** create a service, do **not** register targets, and do **not** add these objects to `lab-05.env`.
**One sentence:** a request to `/results` with no targets gets **`503 Service Temporarily Unavailable`** from the ALB.

📸 **`lab5-ex1-results-rule.png`**: the three rules in order and the empty target health.

### Exercise 2 - repair `verify-lab-04.sh`

1. The property the failing check (line 97) asserts: *"the enrolment tasks accept traffic only from a named
   security group (the tier in front of them), never from a CIDR."*
2. At the top of the script, after the `source` lines, add:
   `source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true` and `: "${USMS_ALB_SG:=none}"`.
   (Check how the script resolves its root; keep its `${BASH_SOURCE[0]}` logic.)
3. Change line 97's check to assert that `UserIdGroupPairs` contains `$USMS_ALB_SG` and that `IpRanges` is empty.
   Rename the label, for example: `usms-enrolment-sg is sourced from usms-alb-sg (not a CIDR)`.
4. Add right after it: `check "usms-app-sg is no longer a source on usms-enrolment-sg" "! aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | grep -qw $USMS_APP_SG"`
5. Run both verify scripts and get `FAIL=0`. Put the new PASS count in a comment at the top of the script and in
   `exercises.md`.
6. Commit with a *why* message, for example: "verify-lab-04: enrolment tasks are now fronted by the ALB (Lab 05
   cutover); assert usms-alb-sg as the only source instead of usms-app-sg".

📸 **`lab5-ex2-verify-04-repaired.png`**: both scripts at `FAIL=0`, plus `git log -1`.

### Exercise 3 - `scripts/utilities/usms-lb-report.sh`

* Walk `describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'usms-')]"`, then
  listeners, rules and target health. Python3 is easiest for the formatting and the `Priority` sort: map
  `"default"` to infinity, otherwise `int()`.
* Handle: no listeners, no non-default rules, an empty TG. Print `fixed-response 200` for non-forward actions.
* `set -uo pipefail` without `-e`, because one failing describe should not kill the whole report; say so in a comment.
* Also write `outputs/lab-05-lb-report.json`. Run it from `~` and from `labs/lab-05-alb/`; the output must be identical.

📸 **`lab5-ex3-lb-report.png`**: the report run from two directories.

### Exercise 4 - the exposure review (write-up + tidy-up)

Write in `exercises.md`: what changed (2 sentences), internal vs internet-facing (with the change to Step 5:
`--scheme internal`, a private DNS name), the before/after exposure table, a monthly cost estimate with
citations (ALB hours × 730 + LCUs; for a low-traffic API, the **new connections** or **active connections**
dimension usually dominates, not bytes), and the HTTPS plan (ACM public certificate, free, DNS validation record
at a domain you own → HTTPS:443 listener with the cert → port-80 rule/default changed to a `redirect` action to
HTTPS).

Then delete, in this order, each with the 4-line danger admonition:
`aws elbv2 delete-rule --rule-arn "$RESULTS_RULE_ARN"` → `aws elbv2 delete-target-group --target-group-arn "$RESULTS_TG_ARN"`.
**Never** delete the `/alb-health` rule. Re-run `verify-lab-05.sh` and confirm `FAIL=0`.

📸 **`lab5-ex4-tidy-up.png`**: the two deletions, `describe-rules` showing only priority 10 + default, and verify `FAIL=0`.

### Exercise 5 - the ResourceLabel for Lab 06

* `scripts/utilities/usms-resource-label.sh [lb-name] [tg-name]`: get both ARNs from the API.
  LB suffix: `${ALB_ARN#*:loadbalancer/}` (parameter expansion). TG suffix: the part from `targetgroup/` onward,
  so `targetgroup/${TG_ARN#*:targetgroup/}`. The TG suffix must **include** the word `targetgroup`; the LB suffix
  must not include `loadbalancer`. That is why they need different treatment.
* Validate: contains both names, exactly 6 `/`-separated segments, first segment `app` (`net` for an NLB).
* Append `export USMS_ALB_RESOURCE_LABEL=$(./scripts/utilities/usms-resource-label.sh)` to `lab-05.env` → **16** exports.
* Write `outputs/lab-05-lab04c-readiness.txt` (label, TG ARN, LB ARN, `service/usms-ecs-cluster/usms-enrolment-svc`,
  `ecs:service:DesiredCount`, the current desired count, and the metric recommendation:
  `ALBRequestCountPerTarget`).
* Measure the replacement time with `python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())'`
  before and after `--force-new-deployment`.

📸 **`lab5-ex5-resource-label.png`**: the label, the validation passing, and `grep -c '^export'` = 16.

---

## 6. Section 13.1 - In-class assessment (prepare, don't pre-build)

Hand-in files are **git-ignored and not committed**:
`outputs/lab-05-assessment-a.txt`, `-b.txt`, `-c.md`. No screenshots are required for the assessment.

* **Task A (30):** `usms-transcripts-tg`: ip, HTTP **8080**, health check `/transcripts/health`, interval 15,
  timeout 4, healthy 2, unhealthy 3, matcher `200-399`; deregistration delay 20 **via attributes**; a rule at priority
  30 for `/transcripts` + `/transcripts/*` → forward; a rule at priority **5** for `/admin` + `/admin/*` →
  `fixed-response` `503`, `text/plain`, `usms admin api is not exposed publicly`. Capture every ARN with
  `$(...)`. End with a sorted `describe-rules`. Practise with Steps 6, 7 and 15 and Exercise 1.
* **Task B (25):** SYMPTOM → ≥3 ranked HYPOTHESES (written **before** testing) → ONE TEST → CAUSE (object,
  field, wrong value, right value) → FIX → PROOF. Start from `verify-lab-05.sh`.
* **Task C (25):** the four questions draw on your Step 11 table, Step 7's timer sequence, Step 10's grace-period
  loop (45 s start, 30 s interval × 2 = marked unhealthy around 60 s → replaced → loop forever), and Step 6's `ip`
  vs `instance` (`instance` is accepted at creation and errors only at Step 10).
* **Task D (20):** verify at `FAIL=0` (or benign failures explained), `lab-05.env` committed, `check-ignore -v`
  on an assessment file, support path at the top of the notes, a descriptive commit.

---

## 7. Section 15 - after submission

```bash
rm -f outputs/lab-05-pre-restart.txt  outputs/lab-05-post-restart.txt
rm -f outputs/lab-05-pre-deploy.txt   outputs/lab-05-post-deploy.txt
rm -f outputs/lab-05-pre-verify-04.txt outputs/lab-05-post-verify-04.txt
git status --short
./scripts/utilities/verify-lab-05.sh | tail -2
```

**Keep** everything else (ALB, TG, listener, `/alb-health` rule, service, SGs, `lab-05.env`). Do **not** run any
cleanup script.

**Before Lab 06:**

```bash
./scripts/utilities/verify-lab-04.sh | tail -2          # FAIL=1 (expected) or FAIL=0 after Exercise 2
./scripts/utilities/verify-lab-05.sh | tail -2          # FAIL=0
grep -c '^export' configs/lab-05.env                    # 15 (16 after Exercise 5)
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].[desiredCount,runningCount,length(loadBalancers),length(deployments)]' --output text   # 2 2 1 1
aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].[TargetType,length(LoadBalancerArns)]' --output text                               # ip 1
./scripts/setup/floci-down.sh && tar -czf ~/floci-data-lab-05.tar.gz -C "$COURSE_ROOT" floci-data && ./scripts/setup/floci-up.sh
```

(Your `floci-data` lives under `$COURSE_ROOT` from `course.env`, not directly under `~`. Check the path with
`echo "$FLOCI_HOST_DATA_DIR"` before you archive.)

---

## 8. Screenshot checklist

Save everything in `screenshots/lab-5/`.

| # | File | Step | What must be visible | Required? |
|---|---|---|---|---|
| 01 | `lab5-01-env-loaded.png` | 1 | whoami + 12 non-empty values | evidence |
| 02 | `lab5-02-pre-verify.png` | 2 | three `FAIL=0` lines + service on `:2` | evidence |
| 03 | `lab5-03-elbv2-probe.png` | 3 | probe table (support path) | evidence |
| 04 | `lab5-04-alb-sg.png` | 4 | `ALB_SG`, rule ID, verify JSON | evidence |
| 05 | `lab5-05-alb-sg-443.png` | 4 Your turn | two inbound rules, 80 and 443 | evidence |
| 06 | `lab5-06-alb-created-1.png` / `-2.png` | 5 | ARN, DNS, state; 2 AZs; attributes | evidence |
| 07 | `lab5-07-target-group.png` | 6 | TG JSON (`ip`, …) + empty `[]` | evidence |
| 08 | `lab5-08-matcher-your-turn.png` | 6 Your turn | `200-399`, then `200` | evidence |
| 09 | `lab5-09-tg-attributes.png` | 7 | delay 30, least_outstanding_requests | evidence |
| 10 | `lab5-10-checkpoint3-listener.png` | 8 | listener → TG, `AttachedToLoadBalancers: 1` | evidence |
| 11 | `lab5-11-enrolment-sg-two-sources.png` | 9 | two source groups on port 80 | evidence |
| 12 | `lab5-12-service-attached.png` | 10 | LB entry, Grace 60, read-back (or fallback) | evidence |
| 13 | `lab5-13-checkpoint4-targets-1.png` / `-2.png` | 11 | targets per private subnet; ECS vs target health | **REQUIRED (CP4)** |
| 14 | `lab5-14-desired-3-then-2.png` | 11 Your turn | 3 targets, then 2 | evidence |
| 15 | `lab5-15-path-proof-1.png` / `-2.png` | 12 | curl result (honest) + five-block chain | evidence |
| 16 | `lab5-16-cutover-1.png` / `-2.png` | 13 | `True`, one source; one-line diff | evidence |
| 17 | `lab5-17-checkpoint5-deploy-1.png` / `-2.png` | 14 | `draining` next to `healthy`; pre/post paste | **REQUIRED (CP5)** |
| 18 | `lab5-18-checkpoint6-rule.png` | 15 | priority 10 fixed-response + default | evidence |
| 19 | `lab5-19-checkpoint7-persistence.png` | 16 | re-derived ARNs + `PERSISTENCE PROVEN` | **REQUIRED (CP7)** |
| 20 | `lab5-20-loop-closed-audit.png` | 17 | `CUTOVER CONFIRMED`, `LOOP CLOSED`, tags | evidence |
| 21 | `lab5-21-lab-05-env.png` | 18 | `all values populated`, 11 lines, `15` | evidence |
| 22 | `lab5-22-git-hygiene.png` | 19 | `check-ignore -v`, `ls-files outputs/`, commit | evidence |
| 23 | `lab5-23-verify-lab-05.png` | 8.1 | `PASS=49 FAIL=0` | evidence |
| 24 | `lab5-24-cleanup-syntax.png` | 8.2 | `syntax OK - do NOT run it` | evidence |
| ex1 | `lab5-ex1-results-rule.png` | Ex 1 | rules 10/20/default; empty results TG | evidence |
| ex2 | `lab5-ex2-verify-04-repaired.png` | Ex 2 | both verify scripts `FAIL=0` + commit | evidence |
| ex3 | `lab5-ex3-lb-report.png` | Ex 3 | report from two directories | evidence |
| ex4 | `lab5-ex4-tidy-up.png` | Ex 4 | deletions + verify `FAIL=0` | evidence |
| ex5 | `lab5-ex5-resource-label.png` | Ex 5 | label, validation, 16 exports | evidence |

---

## Appendix A - Recovery block (new terminal mid-lab)

```bash
bash
cd ~/aws-floci-course
for f in course lab-01 lab-02 lab-03 lab-04; do source configs/$f.env; done
[ -f configs/lab-05.env ] && source configs/lab-05.env
ALB_SG=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=usms-alb-sg" --query 'SecurityGroups[0].GroupId' --output text)
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null)
RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query 'Rules[?Priority==`"10"`].RuleArn | [0]' --output text 2>/dev/null)
printf '%-14s %s\n' ALB_SG "$ALB_SG" ALB_ARN "$ALB_ARN" ALB_DNS "$ALB_DNS" TG_ARN "$TG_ARN" LISTENER_ARN "$LISTENER_ARN" RULE_ARN "$RULE_ARN"
```

A value of `None` means that object has not been created yet. Do not create it twice: if the object already
exists, `create-security-group` fails with `InvalidGroup.Duplicate`, and the elbv2 calls fail with `DuplicateLoadBalancerName` or
`DuplicateTargetGroupName`.

## Appendix B - Troubleshooting quick map

| Symptom | Likely cause | Fix |
|---|---|---|
| `At least two subnets in two different AZs` | public subnet b empty or in the same AZ | Lab 2 Step 11; regenerate `lab-02.env` |
| `container enrolment-api does not exist` | `containerName` mismatch | must be `enrolment-api`, not the family name |
| `InvalidParameterException` about the network mode | TG is `instance` | recreate the TG with `--target-type ip`, redo Steps 7, 8 and 10 |
| targets stay `initial` / go `unhealthy` | SG → path → port → `Reason` field | Section 10; on path B, `initial` is expected |
| target health `unused` | no listener forwards to the TG | `describe-target-groups --query '...LoadBalancerArns'` |
| tasks start and stop in a loop | grace period missing or too short | `update-service --health-check-grace-period-seconds 60` |
| `ResourceInUseException` on delete-target-group | a listener still forwards to it | delete or repoint the listener first |
| `DependencyViolation` deleting `usms-alb-sg` | ALB ENIs not released yet | wait; never delete `ELB app/...` ENIs |
| `NoCredentials` / "aws login" hint | env not loaded | `source configs/course.env`; **never** run `aws login` |
| everything gone after a restart | storage mode is `memory` | `floci-storage-check.sh`; restore the Lab 04 snapshot |
