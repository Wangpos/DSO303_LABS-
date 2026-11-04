# Lab 06 - Implementing Auto Scaling for an ECS-Based Application

Source: <https://norbutlepcha25.github.io/dso303/Lab/Lab-06-autoscaling.html>

Application Auto Scaling for `usms-enrolment-svc`. It writes one integer, `desiredCount`; ECS, the
target group and the load balancer from Labs 04-05 do everything after that.

## What was built

| Object | Configuration |
|---|---|
| scalable target | `ecs` / `service/usms-ecs-cluster/usms-enrolment-svc` / `ecs:service:DesiredCount`, min 2, max 10, no suspension |
| `usms-enrolment-cpu-target-tracking` | `ECSServiceAverageCPUUtilization` 50, out 60 s, in 300 s (+2 managed alarms) |
| `usms-enrolment-requests-target-tracking` | `ALBRequestCountPerTarget` 1000, six-segment `ResourceLabel` (+2 managed alarms) |
| `usms-enrolment-queue-step-out` | StepScaling, ChangeInCapacity, Average, cooldown 60, `[0,100) +1`, `[100,inf) +3` |
| `usms-enrolment-queue-high` | `USMS/Enrolment EnrolmentQueueDepth` Average >= 100, 1 x 60 s -> step policy |
| scheduled actions | **not supported on Floci 2.0.1**; intent in `templates/lab-06-scheduled-actions.json` |
| service-linked role | created (Floci names it `AWSServiceRoleForEcsApplicationAutoscaling`) |

## Files

- `templates/lab-06-target-tracking-cpu.json`, `-requests.json`, `-memory.json` (Ex 1),
  `lab-06-step-scaling-out.json`, `-in.json` (Ex 2), `lab-06-suspended-state.json` (runbook),
  `lab-06-scheduled-actions.json`
- `configs/lab-06.env` - 24 exports
- `scripts/utilities/verify-lab-06.sh` - `PASS=39 FAIL=3` (3 benign scheduled-action checks)
- `scripts/utilities/usms-scaling-report.sh` (Ex 3), `usms-scaling-history.sh` (Ex 5)
- `scripts/cleanup/lab-06-cleanup.sh` - end of course only, run before lab-05 and lab-04 cleanups
- `notes/lab-06-notes.md` - support path, limitations, Your-turn answers, review questions
- `exercises.md` - the five exercises

## Result

Support path **A** for alarm-driven scaling: the alarm self-evaluated, invoked the step policy and
moved `desiredCount` 2 -> 10 (clamped by MaxCapacity) with activities naming the alarm and policy.
Persistence proven across a Floci restart. Service returned to desired 2, one deployment, `usms-enrolment:2`.

```bash
./scripts/utilities/verify-lab-06.sh | tail -1
./scripts/utilities/usms-scaling-report.sh
```
