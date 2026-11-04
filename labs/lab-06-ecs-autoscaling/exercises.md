# Lab 06 - Independent Lab Exercises

Raw command output: `outputs/lab-06-ex1-ex2.txt`, `outputs/lab-06-ex3.txt`, `outputs/lab-06-ex4.txt`,
`outputs/lab-06-scale-latency.txt`, `outputs/lab-06-lab10-readiness.txt` (git-ignored, kept until submission).

---

## Exercise 1 - a memory policy, and a scale-out-only policy

```bash
cat > templates/lab-06-target-tracking-memory.json << 'EOF'   # quoted: no variables
{ "TargetValue": 70.0,
  "PredefinedMetricSpecification": { "PredefinedMetricType": "ECSServiceAverageMemoryUtilization" },
  "ScaleOutCooldown": 60, "ScaleInCooldown": 600, "DisableScaleIn": true }
EOF
MEM_ARN=$(aws application-autoscaling put-scaling-policy --service-namespace ecs \
  --resource-id "$RID" --scalable-dimension "$SDIM" \
  --policy-name usms-enrolment-memory-target-tracking --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-memory.json \
  --query PolicyARN --output text)
```

Result: three target tracking policies + one step policy; the new one shows `DisableScaleIn: true`,
`ScaleInCooldown: 600`. Managed alarms went **4 -> 6 on Floci** (real AWS: 4 -> 5). Bounds unchanged.
Prediction for Section 8: still the same result (PASS=39 FAIL=3 here) because no check counts
policies or alarms exactly (`-ge 2`) - confirmed.

- **Why five and not six?** On real AWS the AlarmLow is not created because a policy with scale-in
  disabled never needs to be told "you may shrink"; its absence means this policy can only ever vote
  to grow. Floci created it anyway (six) - a recorded limitation.
- **Memory 70 vs CPU 50 - which scales out first?** Whichever metric crosses its own target first,
  which depends on the workload's memory-to-CPU profile under load: with 256 CPU units and 512 MiB, a
  request-heavy Node/Java API usually hits CPU 50 first, but a cache-heavy one could hit memory 70
  first - answering properly needs a load test recording both metrics against request rate.
- **Does a scale-out-only policy change scale-in of the other two?** Yes, it can only block it never
  cause it: scale-in happens only when every policy agrees, and a policy with `DisableScaleIn` never
  initiates scale-in - on AWS it does not veto either, so the CPU and request policies still scale in
  when *they* agree; but each scale-out it triggers raises the count the others must later agree to shrink.

## Exercise 2 - the scale-in half of step scaling

`templates/lab-06-step-scaling-in.json` (threshold 20, alarm `< 20` for 3 x 60 s):

| MetricIntervalLowerBound | MetricIntervalUpperBound | ScalingAdjustment | metric range |
|---|---|---|---|
| -10 | 0 | -1 | 10 <= queue < 20 |
| (none) | -10 | -2 | queue < 10 |

Signs: bounds are **non-positive** because a scale-in alarm breaches *below* its threshold, so the
breach (metric - threshold) is negative; adjustments are **negative** because they remove tasks.
`MetricIntervalUpperBound: 0` with `ScalingAdjustment: -1` means "from just below the threshold down
to the next bound, remove one task". Cooldown **300 > 60**: removing capacity is the reversible-but-
slow mistake (a removed task takes minutes to come back), so scale-in waits for evidence to settle.

Run: published 5 three times (breach -15 -> the `-2` step), forced `usms-enrolment-queue-low` to
`ALARM`. Observed: **nothing** - desired stayed 2/2, no new activity, `NotScaledReasons` null. That is
correct behaviour at the floor (AWS would record a not-scaled activity "already at min capacity").
**Unreachable step**: from the baseline 2, `2 + (-2) = 0 < MinCapacity 2`, so the stronger `-2` step can
never apply in full near the floor - from 3 it can only remove 1, from 2 nothing; the floor clips it.

Deletion (point 5), dependency order - alarm first, because it names the policy:

> **What will be deleted:** the alarm `usms-enrolment-queue-low`, then the policy `usms-enrolment-queue-step-in`.
> **What depends on it:** nothing - practice objects from this exercise; the alarm's only action is that policy.
> **Reversible?** Yes - `put-scaling-policy` from `templates/lab-06-step-scaling-in.json`, then `put-metric-alarm`.
> **Effect on later labs:** none; Section 15 lists both under CLEAN UP.

```bash
aws cloudwatch delete-alarms --alarm-names usms-enrolment-queue-low
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-queue-step-in
```

Both deleted; verify unchanged.

**CPU step policy at 60 % beside CPU target tracking at 50.** Target tracking computes capacity as
`current x metric / target`, assuming it is the only thing changing capacity. When CPU hits 60 the
step policy adds tasks *as well*; CPU then drops well below 50, the tracker's low alarm fires and it
computes a smaller capacity to bring CPU back up to 50 - but scale-in needs every policy to agree and
the step policy's alarm is now OK, so the tracker shrinks the service, CPU climbs back to 60, the step
policy fires again: a loop of grow-shrink with the step policy undoing the tracker's arithmetic. Keep
the **target tracking** policy: it is proportional, has managed scale-in, and the step policy adds no
information because it watches the same signal.

## Exercise 3 - scaling report tool

`scripts/utilities/usms-scaling-report.sh` - no arguments, resolves `configs/` from `BASH_SOURCE`,
discovers targets with a `usms-` cluster, batches all alarms into one `describe-alarms` call, does the
JSON work in python3, writes `outputs/lab-06-scaling-report.json`. `-e` not set (justified in the
script: unsupported calls must degrade to "none recorded", not abort).

Verdict order PINNED > FROZEN > AT-CEILING > AT-FLOOR > ELASTIC. FROZEN outranks AT-CEILING because a
suspended target at the ceiling is stuck for an administrative reason the operator must fix first;
position verdicts only mean something for a target that is free to move.

Tested (output in `outputs/lab-06-ex3.txt`): identical output from `~` and from
`labs/lab-06-ecs-autoscaling/`; `AT-FLOOR` at baseline (desired 2 = min 2, >1 policy); `FROZEN` while
scale-in suspended; `PINNED` with min = max = 3; correct before and after Exercise 1 (memory policy
listed with "scale-in DISABLED"); unsupported scheduled actions print "none recorded"; step policy
summarised as `+1 / +3` and its alarm found via `AlarmActions` (Floci leaves the policy's `Alarms` empty).

```
service/usms-ecs-cluster/usms-enrolment-svc   ecs:service:DesiredCount
  bounds       min=2  max=10   desired=2   running=2   AT-FLOOR
  suspended    none
  target-track usms-enrolment-cpu-target-tracking         CPU/50.0      out=60  in=300
                 alarms  AlarmHigh=INSUFFICIENT_DATA  AlarmLow=INSUFFICIENT_DATA
  step         usms-enrolment-queue-step-out              +1 / +3         cooldown=60
                 alarm   usms-enrolment-queue-high = OK  (USMS/Enrolment EnrolmentQueueDepth >= 100.0)
  target-track usms-enrolment-requests-target-tracking    ALBReq/1000.0    out=60  in=300
                 alarms  AlarmHigh=INSUFFICIENT_DATA  AlarmLow=INSUFFICIENT_DATA
  scheduled    none recorded (or unsupported on this build)
  last activity  2026-11-04T18:25:00.414000+06:00  Successful  Setting desired capacity to 10
```

## Exercise 4 - the enrolment-week capacity plan

### Is it solved? (three sentences)
Reactive auto scaling is good at following gradual change - the "double normal for three weeks" load
will be tracked automatically and cheaply. It is bad at sudden steps, because every reactive decision
arrives three to five minutes after the load and then in increments limited by cooldowns and a
ceiling of 10. The first twenty minutes of a forty-fold spike are therefore served almost entirely by
the capacity that was already running, which is why last year's portal fell over and why it would
fall over again with only today's configuration.

### Why forty times traffic is not a scaling problem
Reactive time from 2 to 10 tasks with this lab's numbers:

- Step policy (fastest path): alarm 1 x 60 s -> +3 (2->5); cooldown 60 s -> +3 (5->8); 60 s -> +3
  clamped (8->10): 60 + 60 + 60 = **180 s** of decisions, then the last tasks need ~60 s Fargate start
  + 60 s grace = **~300 s** before 10 tasks serve.
- CPU target tracking: high alarm 3 x 60 s = 180 s, computes 2 x 100/50 = 4; start + grace 120 s; then
  again (CPU still saturated) 180 s -> 8; again -> 10: about **3 x 180 + 120 = 660 s (~11 min)**.

The ceiling: 10 tasks x 1000 requests/target/minute = 10,000 requests/minute = **~167 requests/s**.
If normal load is what two tasks serve at target (2,000 req/min ~ 33 req/s), forty times is
80,000 req/min ~ 1,333 req/s, which needs **80 tasks** at the provisional target. A ceiling of 10 serves
12.5 % of the peak however fast scaling is - this is a *capacity* problem (the ceiling and a
pre-warmed floor), not a scaling-speed problem. Capacity is how many tasks exist; throughput is what
they serve: 10 tasks give 167 req/s only if 1000/min/task is what one task really sustains, which has
never been measured.

### The ceiling, checked against Lab 02
A /24 has 256 addresses; AWS reserves 5 in every subnet (network, VPC router, DNS, future use,
broadcast) - [VPC subnet sizing](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html) -
leaving **251** in each of 10.0.3.0/24 and 10.0.4.0/24 (Floci reports `AvailableIpAddressCount` 251).
Existing occupants: usms-private-subnet-a holds usms-db-01 and one ENI is in use in each subnet
(`outputs/lab-06-ex4.txt`); allow ~5 per subnet for the DB, NAT/endpoint ENIs and growth -> ~246 per
subnet, ~492 total. Each Fargate task in `awsvpc` mode takes one ENI/IP, and a rolling deployment at
the default `maximumPercent` 200 % needs room for old and new tasks at once, so the largest safe
ceiling is about **half: ~240 tasks (120 per AZ)**. The plan's 100 fits comfortably; also check the
account's Fargate vCPU quota (100 tasks x 0.25 vCPU = 25 vCPU).

### Capacity plan
Assumptions to confirm (item 1 below): enrolment opens Monday 14 December 2026, cohort days are the
14th, 21st and 28th, portal opens at 08:00 Asia/Thimphu, the window ends 3 January 2027.

| action | schedule | time zone | min | max |
|---|---|---|---|---|
| `usms-enrolment-window-open` | `at(2026-12-13T20:00:00)` | Asia/Thimphu | 4 | 20 |
| `usms-enrolment-cohort-1-warm` | `at(2026-12-14T07:30:00)` | Asia/Thimphu | 80 | 100 |
| `usms-enrolment-cohort-1-cool` | `at(2026-12-14T10:00:00)` | Asia/Thimphu | 4 | 20 |
| cohort 2 warm / cool | `at(2026-12-21T07:30:00)` / `at(2026-12-21T10:00:00)` | Asia/Thimphu | 80 / 4 | 100 / 20 |
| cohort 3 warm / cool | `at(2026-12-28T07:30:00)` / `at(2026-12-28T10:00:00)` | Asia/Thimphu | 80 / 4 | 100 / 20 |
| `usms-enrolment-window-close` | `at(2027-01-03T20:00:00)` | Asia/Thimphu | 2 | 10 |

Warm 30 minutes early covers start-up + grace for 80 tasks; holding the floor through the first two
hours absorbs the spike with no reactive delay, and target tracking above the floor handles anything
beyond. The existing weekday evening action (min 2 at 20:00) would undo the window's floor of 4 every
night; suspending all scheduled scaling would also kill the cohort actions, so instead re-put the
evening action with MinCapacity 4 for the window (one `put-scheduled-action`) and restore it at close.
Target value: keep 1000 until a load test exists, then set it to ~70 % of the measured per-task
maximum. Ceiling: raise to 100 for cohort days and 20 for the window (bounded by the ~240 address
limit and Fargate quota). Every change is reversible in one command: each `put-scheduled-action`
is undone by `delete-scheduled-action` plus one `register-scalable-target --min-capacity 2
--max-capacity 10`; the target value by one `put-scaling-policy` from `templates/`. (On Floci,
scheduled actions are unsupported, so this plan was not applied here.)

### Monthly cost estimate
Prices (us-east-1, Linux/x86, at time of writing - check the
[Fargate pricing](https://aws.amazon.com/fargate/pricing/) and
[CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) pages before quoting):
$0.04048 per vCPU-hour, $0.004445 per GB-hour; task = 0.25 vCPU + 0.5 GB (`configs/lab-04.env`:
256/512) = 0.01012 + 0.0022225 = **$0.0123 per task-hour**.

| item | arithmetic | USD |
|---|---|---|
| window floor 4 vs baseline 2, 3 weeks | 2 extra x 504 h x 0.0123 | 6.22 |
| reactive headroom (assume avg 2 more tasks during the 3 weeks for the doubled load) | 2 x 504 x 0.0123 | 6.22 |
| cohort days: 80 vs 4 for 2.5 h, x 3 | 76 x 2.5 x 3 x 0.0123 | 7.04 |
| CloudWatch alarms (4 managed + 1 custom, standard resolution) | 5 x $0.10 | 0.50 |
| custom metric `USMS/Enrolment EnrolmentQueueDepth` | 1 x $0.30 | 0.30 |
| **total additional for the enrolment month** | | **~$20.3** |

Assumptions: no Savings Plan; ALB LCU charges, data transfer, NAT processing and CloudWatch Logs
ingestion excluded; the alarms and metric exist all year so their $0.80 is not enrolment-specific.

### What I need from the project lead
1. The exact dates and opening times of the three cohort days and of the window close.
2. A **load test** of one `usms-enrolment` task (requests/minute at acceptable latency) - the
   measurement Section 11 says nobody has taken; every number above is provisional without it.
3. Last year's per-minute request counts for one cohort-day first hour, plus sign-off on a budget
   of ~$25 for the month and on raising the account's Fargate quota if the test says more than ~100 tasks.

### Tidy-up (executed)

> **What will be deleted:** the scaling policy `usms-enrolment-memory-target-tracking` (Exercise 1) and, with it, its two managed CloudWatch alarms.
> **What depends on it:** nothing - it is practice; no check, env file or later lab names it.
> **Reversible?** Yes - one `put-scaling-policy` from `templates/lab-06-target-tracking-memory.json`.
> **Effect on later labs:** none; Section 15 lists it under CLEAN UP.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking
```

Managed alarms 6 -> 4. Exercise 2 leftovers: none (`usms-enrolment-queue-step-in` and
`usms-enrolment-queue-low` were removed in Exercise 2 point 5; re-checked: 0 alarms, 3 policies).
`verify-lab-06.sh`: PASS=39 FAIL=3 (the three documented benign scheduled-action checks).

## Exercise 5 - the hand-off to Lab 10

1-2. `scripts/utilities/usms-scaling-history.sh` (any directory, everything discovered, `-e` off so an
unsupported call degrades to `[]`) wrote `outputs/lab-06-scaling-history.json`: target, 3 policies,
5 alarms, 0 scheduled actions (unsupported), 7 activities, top-level `generated` (python3 UTC) and
`resourceId`. Valid JSON, **16,240 bytes**.

3. Scale-out latency: raised MinCapacity to 4, polled 65 s - `desiredCount` stayed 2 (Floci does not
enforce the floor), so no task started. Recorded the cited AWS Fargate start-up figure, **60 s**
(upper end of 20-60 s), with both timestamps and capacities in `outputs/lab-06-scale-latency.txt`.
Floor put back to 2. (Step 12's observed policy-driven starts reached RUNNING in under ~20 s - Floci
being nicer than reality.)

4. Appended `USMS_SCALING_HISTORY_FILE` and `USMS_SCALE_LATENCY_SECONDS` (both derived) -> **24 exports**,
all populated.

5-6. `outputs/lab-06-lab10-readiness.txt`:

```
history_file=outputs/lab-06-scaling-history.json
history_size_bytes=16240
scale_latency_seconds=60 (cited)
task_role_arn=arn:aws:iam::000000000000:role/usms-ecs-task-role
policy_arn=arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite (version v1)
bucket_arn=arn:aws:s3:::usms-student-data (the bucket-level Resource entry; the other entry is the object-level arn:aws:s3:::usms-student-data/*)
permissions=Lab 01's USMSStudentDataReadWrite ALLOWS s3:ListBucket and s3:GetBucketLocation on the bucket and s3:GetObject, s3:PutObject and s3:DeleteObject on its objects, and explicitly DENIES s3:DeleteBucket.
head_bucket_exit_code=254
head_bucket_output= aws: [ERROR]: An error occurred (404) when calling the HeadBucket operation: Not Found
after_lab10_step1=Once Lab 10 creates usms-student-data, head-bucket returns exit 0 with no error, and usms-ecs-task-role's unchanged policy starts granting real access to a real bucket at that same instant, as does usms-ec2-app-role's.
```

The bucket ARN was read with `get-policy` -> `DefaultVersionId` -> `get-policy-version`, not typed;
I recorded the bucket-level entry. No script reads or references an access key.
