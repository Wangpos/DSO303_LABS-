# Lab 06 notes - Auto Scaling for usms-enrolment-svc

**Support path: A (full) for alarm-driven scaling; scheduled scaling unsupported.**
Floci build `floci/floci:latest` (aws-cli 2.39.3). The custom alarm evaluated itself, went to
`ALARM`, and invoked the step policy; `desiredCount` moved with no command from me and
`describe-scaling-activities` recorded a `Cause` naming both the alarm and the policy.
`PutScheduledAction` / `DescribeScheduledActions` return `UnsupportedOperation` (Floci 2.0.1
known issue), so Step 11 is conceptual on this build.

## Pre-flight (Steps 1-2)

- Docker Desktop was not running; started it. The first Floci start exited 137 mid-run (not OOM,
  no script stops it - Docker Desktop was still settling with a kind cluster starting beside it).
  A second `floci-up.sh` was stable for the rest of the lab.
- `verify-lab-02` 6/0, `verify-lab-04` PASS=39 FAIL=0 (no failures in 04 - Lab 05 Exercise 2 done).
- `verify-lab-03` FAIL=1 `usms-web-01 is running`: the known "instances stop on Floci restart"
  limitation from Lab 05's notes. Started usms-web-01 and usms-db-01 -> PASS=36 FAIL=0. Same again
  after Step 14's restart.
- `verify-lab-05` PASS=47 FAIL=2: `healthCheckGracePeriodSeconds is set` and `lab-05.env has no
  empty values` (`USMS_SVC_GRACE_PERIOD=None`). I re-applied `update-service
  --health-check-grace-period-seconds 60`; Floci accepts it and still returns `None`. **Floci does not
  store the grace period.** Both failures are this one limitation, existed before Lab 06, and the
  end-of-lab diff of `verify-lab-05.sh` against `outputs/lab-06-pre-verify-05.txt` was empty.
  Step 12's arithmetic uses the intended 60 s.
- Task size on this repo is 256 CPU / **512** MiB (the lab text's example shows 1024).

## Step 4 - service-linked role

`create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com` succeeded
but Floci named the role **`AWSServiceRoleForEcsApplicationAutoscaling`**, not AWS's fixed name
`AWSServiceRoleForApplicationAutoScaling_ECSService`; `get-role` on the real name -> `NoSuchEntity`.
Path is `/aws-service-role/ecs.application-autoscaling.amazonaws.com/` (service-owned), trust
principal correct, no attached policy. The scalable target's `RoleARN` nevertheless names the
canonical AWS name, which is what `configs/lab-06.env` records. Nothing assumes it on Floci.

## Step 6 "Your turn" - `--min-capacity 5`

Prediction: on real AWS `desiredCount` jumps to 5 within seconds, no policy, no alarm.
Observed on Floci: `MinCapacity` stored as 5, `desiredCount` stayed **2** for 20 s, 0 activities.
Floci stores the bound but does not enforce it on registration. Put back to 2/10.

- (a) The **scalable target** made (on AWS, would make) the change - its registration enforces the
  floor; no scaling policy is involved and ECS merely obeys the new desired count.
- (b) The cost is paying for 3 extra Fargate tasks around the clock while the floor also hides any
  real scale-in, and `describe-scalable-targets --query 'ScalableTargets[0].MinCapacity'` is the one
  call whose value a monitor would compare with the expected 2.

## Step 8 - managed alarms, and "Your turn" arithmetic

Floci created both managed alarms (High 3x60 s `>`, Low 15x60 s `<`, one action each = the CPU
policy ARN). Deviations: `MetricName` is `ECSServiceAverageCPUUtilization` (not `CPUUtilization`),
and the Low threshold is **50**, not 45 - no dead band.

Time at 100 % CPU before a third task serves traffic:

| term | value | where configured |
|---|---|---|
| High alarm Period x EvaluationPeriods | 60 x 3 = 180 s | AWS (managed alarm) |
| policy invocation | ~0 s | AWS |
| Fargate task start-up | ~60 s (cited; Lab 04 Ex 5 not measured) | AWS / image size |
| health-check grace period | 60 s | Lab 05 Step 10 |
| **total** | **~300 s** | |

I would change the **task start-up** term first (smaller image, faster health endpoint); it costs
engineering time on the image but nothing at run time - the alarm term is AWS's to choose, and
shortening the grace period risks killing healthy tasks still warming up.

## Step 9

`ResourceLabel` came from `USMS_ALB_RESOURCE_LABEL` (Lab 05 Ex 5):
`app/usms-enrolment-alb/cc9d002d3f6343a2/targetgroup/usms-enrolment-tg/7750fc7480fd4dbc` -
6 segments, `app` first, `targetgroup` fourth. Policy created, two managed alarms (4 total).
Floci put the request alarms in namespace `AWS/ECS`; real AWS uses `AWS/ApplicationELB`
`RequestCountPerTarget`.

## Step 10

Policy, alarm and `--alarm-actions` link all stored. Deviations: `TreatMissingData` reads back as
`null` (not stored), and the step policy's `Alarms` list is **empty** - Floci does not back-link the
alarm into the policy as real AWS does.

## Step 11 - scheduled actions

`put-scheduled-action` -> `UnsupportedOperation`, with `--timezone` and with the UTC fallback.
Recorded the intended actions in `templates/lab-06-scheduled-actions.json` (morning
`cron(45 7 ? * MON-FRI *)` Asia/Thimphu min 4/max 10, evening `cron(0 20 ? * MON-FRI *)` min 2/max 10).
As a stand-in I re-registered min 4 then min 2 by hand (`outputs/lab-06-step11-schedule-standin.txt`);
this proves only what the action *would write*, not that a scheduler fires. The `results-night`
`at()` "Your turn" could not be created; the mechanism is not observable. Floor confirmed 2/10.

"Your turn" answer: an `at()` action stays behind after firing as a dead calendar entry; six months
later nobody remembers it, it shows in every `describe-scheduled-actions`, the CloudFormation lab
would re-declare it, and the floor it raised stays raised unless someone lowers it. The runbook page
that creates it must also hold the `delete-scheduled-action` call **and** the
`register-scalable-target --min-capacity 2` that puts the floor back.

## Step 12 - which proof I obtained: BOTH

- Prediction: 260 vs 100 -> breach 160 -> +3 -> 2 to 5.
- The alarm reached `ALARM` on its own at poll 1 ("Threshold Crossed: 1 datapoint(s)"), before the
  `set-alarm-state` (which also worked).
- First activity: **2 -> 3 (+1)**, not +3. The evaluated one-minute bucket's average was **106.4**
  (it mixed the earlier 3/5/4 datapoints with the first 260), a breach of 6.4 -> the first step.
  That is correct `Average` aggregation; my prediction assumed the whole minute was 260.
- Floci then re-invoked the policy **every 10 s** while the alarm stayed in `ALARM`, ignoring the
  60 s cooldown: 3,4,5,6,7,8, then 10 (8+3=11 clamped by `MaxCapacity` 10). Seven `Successful`
  activities, all with `Cause: monitor alarm usms-enrolment-queue-high in state ALARM triggered
  policy usms-enrolment-queue-step-out`. Running count followed within ~20 s (no real start-up delay).
- So on Floci: alarm evaluation, policy invocation and the ceiling are real; cooldowns are not.
- Six-block wiring proof also saved: `outputs/lab-06-scaling-proof.txt`.
- Baseline restored in the right order: metric to 4/3/2 and alarm `OK` first, then
  `update-service --desired-count 2` -> 2/2/0. It stayed at 2.

## Step 13 - suspension

Suspended scale-in via `file://templates/lab-06-suspended-state.json`; bounds 2/10 kept, all three
policies and 4 managed alarms unchanged; resumed with shorthand; `SuspendedState.*` = `False False
False`, `grep -ci true` = 0. (Floci stores suspension; whether it blocks scaling was not tested.)

## Step 14 - persistence

`PERSISTENCE PROVEN` after `floci-down.sh` / `floci-up.sh`, identifiers re-derived from the API.
The scheduled-actions line is `UnsupportedOperation` both times. EC2 instances stopped again and
were restarted.

## Step 15 - the nine lines

1. A student clicks Register.
2. Requests per target rises past 1000, or the queue passes 100 - **Lab 06** (alarms, block 1).
3. An alarm fires and invokes a policy - **Lab 06** (blocks 1-2).
4. The policy writes `desiredCount`, clamped to 2..10 - **Lab 06** (block 3).
5. ECS starts a task from `usms-enrolment:2` - Lab 04.
6. The task gets an ENI in usms-private-subnet-a or -b, no public IP - Lab 02/04.
7. usms-enrolment-sg admits tcp/80 from usms-alb-sg only - Lab 05.
8. The service registers the task's address in usms-enrolment-tg - Lab 05.
9. The ALB health-checks it and after the grace period sends traffic; nothing about the blueprint,
   service or load balancer changed - block 7 shows `:2`, 1 LB, 1 deployment.

Lab 06 owns three of the nine (2-4). Floci observation: the target group listed 6 targets (2 unhealthy)
after scale-in to 2 - Floci does not deregister stopped tasks' IPs; real ECS deregisters them.

## Step 16-17

- The lab's `awk -F: '{print \$NF}'` inside the unquoted heredoc produced an **empty**
  `USMS_SCALABLE_RESOURCE_ID` under both zsh and macOS bash 3.2 (awk received the backslash). Inside
  `$(...)` the single quotes already protect `$NF`, so the unescaped form is correct; I filled the
  value by the same lookup. 22 exports, all populated (24 after Exercise 5).
- Step 17 part 1: the hint strings were already correct (`lab-06-cleanup.sh`). The remaining
  `lab-04-cleanup.sh` mentions in `lab-05-cleanup.sh` ("Run BEFORE lab-04-cleanup.sh", "lab-04-cleanup.sh
  may now run") are *correct*; the lab's blind replace would have broken them, so I skipped it.
- `verify-lab-06.sh`: the lab's last check `! git ls-files | grep -q '^outputs/'` always fails because
  `outputs/.gitkeep` is (correctly) tracked; changed it to ignore exactly that file.

## Section 8 result

`PASS=39 FAIL=3`. The three failures are the documented benign ones for an unimplemented
`describe-scheduled-actions`: morning exists, evening exists, morning floor > evening floor.

## Floci limitations hit (and what real AWS would do)

| Observed on Floci | Real AWS |
|---|---|
| SLR created as `AWSServiceRoleForEcsApplicationAutoscaling` | fixed name `AWSServiceRoleForApplicationAutoScaling_ECSService`, assumed for every `UpdateService` |
| `healthCheckGracePeriodSeconds` not stored (`None`) | stored; new tasks not health-judged for 60 s |
| Raising `MinCapacity` above `desiredCount` does nothing | raises `desiredCount` immediately |
| Managed alarm metric named after the predefined type; Low threshold = target (no dead band) | `CPUUtilization` / `RequestCountPerTarget`; Low threshold below target |
| Request alarms in `AWS/ECS` | `AWS/ApplicationELB` |
| `TreatMissingData` not stored; step policy `Alarms` list empty | both stored and shown |
| `DisableScaleIn: true` still created an AlarmLow (6 alarms, not 5) | no low alarm for a scale-out-only policy |
| Scheduled actions `UnsupportedOperation` | full, with IANA time zones |
| Policy re-invoked every 10 s in ALARM; cooldown ignored | cooldown 60 s respected; one step per cooldown |
| Tasks reach RUNNING in seconds | 20-60 s Fargate start + grace period |
| Stopped tasks left registered in target group | ECS deregisters on stop |
| `--include-not-scaled-activities`: `NotScaledReasons` null | lists reasons such as "already at min" |
| No IAM authorisation, no cost, no quotas, no subnet exhaustion | all enforced |

## Section 11 - which list each item ended up in for me

Observed: role (with naming deviation), target, bounds as records, policies, managed alarms,
`ResourceLabel`, step table, custom alarm, alarm self-evaluation, policy invocation, scaling activities
with `Cause`, ceiling clamping, suspension as a record, persistence.
Conceptual: scheduled actions and their firing, floor enforcement, cooldowns, target-tracking capacity
arithmetic on real CPU/request metrics, Fargate start latency, grace period, not-scaled reasons, cost.

## Review questions (Section 14)

### Q1
The nine lines are in Step 15 above. Lab 06 owns lines 2-4: the alarms that watch a signal, the
policies they invoke, and the scalable target that clamps the one integer. Lines 5-9 needed no change
because the service already knew how to make `runningCount` equal `desiredCount` (Lab 04), every task
already landed in two private subnets behind the right security group (Labs 02/04/05), and the
service - not a person - already registered each task in the target group (Lab 05); a task started by
a policy is indistinguishable from one started by `update-service`. **Auto scaling changes exactly one
thing about my application: who writes `desiredCount`, and when.**

### Q2
The resource ID is Application Auto Scaling's own address for "the thing that has a scalable number",
a constructed string rather than an ARN because the service spans many namespaces whose resources
have no common ARN format (and some dimensions, such as a DynamoDB index's capacity, have no ARN of
their own). For `ecs` it is `service/<cluster>/<service>` - exactly the suffix after the last colon of
the service ARN; for `dynamodb` it is `table/<table>` or `table/<table>/index/<index>`; for `lambda` it is
`function:<function>:<alias-or-version>` (provisioned concurrency is on a qualifier, not the function).
Passing the full ARN fails because it is not that string. Other constructed identifiers here: the
`ResourceLabel` `app/<alb>/<id>/targetgroup/<tg>/<id>` built from the ALB ARN (after `:loadbalancer/`)
and the target group ARN (after the last colon); the managed alarm prefix `TargetTracking-<resource id>`;
and the CloudWatch metric dimensions `ClusterName`/`ServiceName` derived from the service ARN.

### Q3
The **scalable target** makes it: registration enforces `MinCapacity` by writing `desiredCount` up to
the floor. A policy acts only when an alarm invokes it, moves the count by a computed or stepped
amount, respects cooldowns and writes an activity whose `Cause` names an alarm; the floor is
unconditional and has no alarm behind it. 3 a.m. incident: requests are timing out, CPU is fine but a
downstream dependency is slow, so more concurrency helps; the on-call engineer runs
`register-scalable-target --min-capacity 6` to force capacity without waiting for metrics. Evidence at
8 a.m.: `describe-scalable-targets` shows `MinCapacity` 6 (and an updated registration), on AWS a
scaling activity / CloudTrail `RegisterScalableTarget` event by that engineer's principal, a desired
count of 6 with no alarm in `ALARM`, and the cost line - but no note, unless the runbook demanded one.

### Q4
The two managed alarms are owned by Application Auto Scaling: created by `put-scaling-policy`,
recreated (overwriting any edit) when the policy changes, deleted with it; delete one by hand and the
policy silently loses that direction while `describe-scaling-policies` still lists it. My
`usms-enrolment-queue-high` is owned by me: it survives policy changes and deletion (cleanup must
remove it explicitly), I choose its metric, period, evaluations, threshold and missing-data treatment,
and it can have several actions (an SNS topic as well as the policy) - which a managed alarm cannot -
while a managed alarm can do the capacity arithmetic against a set point, which mine cannot.
Argument for `breaching`: the queue metric is published by the application; if it stops, the likeliest
cause is that the workers or the publisher are overwhelmed or dead, which is exactly when more capacity
is wanted, so silence should count as backlog. If I were right but the outage were in the *publisher*
alone (a broken metrics agent), the alarm would fire continuously, step policy adds +1/+3 every
cooldown and the service sits at the ceiling of 10 paying for idle tasks until someone notices - and
scale-in is blocked if a matching low alarm treats missing data as not breaching.

### Q5
Delays, in order: the metric is published and aggregated per one-minute period (CloudWatch); the
alarm needs `EvaluationPeriods` breaching periods - 3 x 60 s for the managed high alarm, 1 x 60 s for
mine (AWS / Step 10); policy invocation ~seconds; ECS schedules a Fargate task and pulls the image,
20-60 s (AWS, image size from Lab 04); the container health check passes; the target group needs its
healthy threshold of checks and the 60 s grace period (Lab 05 Step 10) before the task is useful.
About 60-180 + 0 + 60 + 60 = 3-5 minutes, all of it served by existing capacity. Consequences:
(1) the **floor is a latency decision** - justifies `MinCapacity` 2 = one task per AZ to absorb the
first minutes; (2) **scale out eagerly, in reluctantly** - justifies `ScaleOutCooldown` 60 vs
`ScaleInCooldown` 300 and a 1-evaluation queue alarm; (3) **for a known spike use scheduled scaling** -
justifies the 07:45 Asia/Thimphu min-4 action, the only mechanism that can be early.

### Q6
Scale-out: the largest capacity any policy computes wins, so if requests say 6 and CPU says 3 the
service goes to 6. Scale-in: only when every policy agrees it is safe, so if CPU says 2 but requests
say 4 it stays at 4. The asymmetry exists because the cost of too little capacity (failed requests)
is far worse than the cost of too much (a few task-hours); each policy is a separate reason the
service might need capacity, and any one being true is enough to grow while all must be false to
shrink. Two target tracking policies on the *same* metric with different targets fight: one computes
a capacity that puts the metric at 50, the other at 70; the 50 policy scales out until the metric is
50, which is below 70's low alarm, so the other wants to scale in - they can never both be satisfied
and the count oscillates (or is pinned by the scale-in rule). A step policy on the same metric is the
same mistake: target tracking computes capacity proportional to metric/target assuming it alone
changes capacity; a step policy adding tasks on top moves the metric below the set point and the
target tracker's low alarm then works against it - two controllers on one signal.

### Q7
Reasons `ALBRequestCountPerTarget` beats CPU for the enrolment API: it measures the cause (demand)
not a symptom (CPU), so it moves the instant load arrives; it is independent of the 256-unit CPU
reservation, so resizing the task does not silently change what "50" means; and it falls predictably
as tasks are added (per-target), which is what target tracking's arithmetic assumes. CPU is better for
CPU-bound work with variable per-request cost - e.g. report generation or PDF rendering, where 100
cheap requests and 100 expensive ones differ tenfold. `ALBRequestCountPerTarget` would scale badly if
the bottleneck is elsewhere - requests waiting on a slow database: per-target requests stay flat (or
fall, as clients time out) while latency climbs, so it never scales or scales the wrong tier; or if
request cost varies so much that 1000/min is too many. The warning metric is `TargetResponseTime`
(and HTTP 5xx count) on the target group, rising while request count stays at target.
