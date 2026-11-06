# Lab 08 notes - EKS scaling and service exposure

**Support path: A.** Floci `floci/floci:latest` reports version **2.1.0**. The k3s cluster is one node
(the control plane), API on `https://localhost:6500`, context `usms-eks-local`.

Things that differed from the lab text on this build:

- **`update-nodegroup-config` is unsupported**: `UnknownOperationException ... POST
  /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`. The PDF flags this for
  Floci 2.0.1; it is still true on 2.1.0. The node group stays 2/4/2, and `verify-lab-08.sh`'s
  "maxSize raised to 6" check fails for that reason alone (**PASS=33 FAIL=1**). I did not delete and
  recreate the node group as a workaround: that is destructive and proves nothing the error does not.
- **k3s ships metrics-server and its service load balancer (`svclb`)**, but **no ingress controller**
  (no Traefik, no IngressClass).
- **`_lb_ports_` did not publish host ports.** `docker port` on the cluster container shows only
  `6443 -> 6500`, so `localhost:8081/8082` refuse connections (curl exit 7).
- The Docker healthcheck marks the `floci` container `unhealthy` only because the image has no
  `curl`. The endpoint itself (`/_floci/health`) answers.

## Step 1-2 - checks and baseline

CPU request `{"cpu":"50m","memory":"32Mi"}`; `_lb_ports_` = `8081,8082` in both `lab-07.env` and
`describe-cluster`; `verify-lab-07.sh` **PASS=30 FAIL=0**. Baseline in `outputs/lab-08-baseline.txt`:
enrolment 2/2, gateway 1/1, results 2/2, timetable 1/1 (Lab 07 Exercise 1), every Service ClusterIP
with no external address, one node with 8 CPUs.

## Step 3 - "Your turn": ten times the traffic for usms-enrolment

1. **Dimension 1 (more pods) first.** Raise the HPA's `maxReplicas` and let it scale, because it is
   cheap, instant and reversible. *Check:* do the new pods go `Ready`, or `Pending`?
2. **Dimension 3 (more nodes) next**, because ten times the pods needs room. Raise the node group's
   `maxSize`/`desiredSize` (or let Cluster Autoscaler/Karpenter do it). *Check:* new nodes `Ready`,
   `Pending` pods scheduled, `describe node` allocated CPU below about 80%.
3. **Dimension 2 (bigger pods) only if one pod is the bottleneck** (per-request CPU or memory, not
   volume). *Check:* `kubectl top pods` at the limit, or OOMKills. Changing it restarts every pod and
   changes the HPA's denominator, so re-read the HPA target afterwards.
4. **Dimension 4 (bigger nodes) last and planned:** a new node group, cordon and drain the old, delete it.
   It can't be done in place, so it is never the first move for a Monday deadline.

## Step 4 - scale by hand

- `kubectl scale --replicas=5` changed **one field**. The same ReplicaSet `usms-enrolment-74f976b7`
  went 2 -> 5; no new ReplicaSet and no rollout.
- The watcher (`outputs/lab-08-step4-watch.txt`) shows the new pods `Running` but `0/1` for about 6 s:
  endpoints grow on **readiness**, not on start.
- **40 requests across 5 pods**: 12/10/7/6/5. Two takes were discarded and are noted here for honesty.
  The first ran right after the rollout and only 3 pods answered (endpoints not yet propagated). The
  second lost a `kubectl run` attach race ("falling back to streaming logs"), which double-counted to 80.
- Scale-in: pods went `Terminating` then `Completed`, after leaving the endpoint list.

## Step 5 - drift

Cluster `6`, file `replicas: 2` (line 35), `kubectl apply` -> `2`. With the file edited to 3,
`kubectl diff` showed `- replicas: 2 / + replicas: 3` and **exited 1** (a difference, not an error).
Restored to 2; no `.bak` left.

## Step 6 - QoS

All pods were `Burstable` (50m/200m). The node shows capacity = allocatable = 8 CPU on this build
(k3s reserves nothing by default; a real EKS node shows allocatable below capacity). Allocated
requests were 500m (6%).

**"Your turn" - gateway Guaranteed and back:** `kubectl set resources ... --requests=cpu=200m,memory=128Mi
--limits=cpu=200m,memory=128Mi` gave a **new pod** (`fc86c5d48`) with QoS `Guaranteed`. Re-applying
`40-gateway.yaml` gave another new pod, `Burstable` 50m/200m again. The pod was **replaced, not
adjusted**, because resources are part of the pod template (dimension 2). That's why
VerticalPodAutoscaler is used far less than HPA: every resize is a restart. I would want `Guaranteed`
for a latency-critical pod on a busy node that must be evicted last, such as a database or an ingress
controller, accepting that it can never burst.

## Step 7 - metrics pipeline

`v1beta1.metrics.k8s.io` registered, `metrics-server` 1/1, **metrics API: AVAILABLE**. Idle: every pod
**1m** (2% of 50m); node 104m. No install and no `--kubelet-insecure-tls` needed.

## Steps 8-9 - the HPA, observed

- `usms-enrolment-hpa` created; it read `<unknown>/50%` for the first seconds, then `cpu: 2%/50%`.
  Conditions: `ScalingActive True ValidMetricFound`.
- **Scale-out** (`outputs/lab-08-hpa-scaleout.txt`): 2% -> 42% -> **61%**, replicas **2 -> 3**, then CPU
  settled at about 42% across 3 pods. ceil(2 x 61 / 50) = ceil(2.44) = **3**.
- **Correction to the lab text:** the PDF's example says 71% "went to 4" because the scale-up policy
  "allowed doubling". `behavior` policies are a *ceiling* on how much may change per period; the
  formula still decides the target. My run is exactly that: the policy allowed +2, and the formula
  asked for +1.
- **Scale-in** (`outputs/lab-08-hpa-scalein.txt`): loadgen scaled to 0 at 06:01:35, CPU 2% by
  06:02:47, replicas **held at 3 until 06:07:15** (about 5 min after the last high recommendation),
  then 3 -> 2. The events, word for word:
  - `New size: 3; reason: cpu resource utilization (percentage of request) above target`
  - `New size: 2; reason: All metrics below target`

## Step 10 - node group from the AWS side

Before: 2/4/2, `t3.small`, private subnets, labels `workload=usms tier=app`. `update-nodegroup-config
--scaling-config minSize=2,maxSize=6,desiredSize=3` -> **UnknownOperationException**; `list-updates`
empty; after: still 2/4/2. **No third node**, and nothing to enact even in principle, because Floci's node
"group" is a record. On real AWS the call returns an `InProgress` Update object, the ASG launches an
instance, and it joins `Ready` within minutes.

## Step 11 - Cluster Autoscaler / Karpenter, nodeSelector

- **Cluster Autoscaler** sees `Pending` pods and raises the desired capacity of an Auto Scaling group
  *you defined*. **Karpenter** sees the same pods and launches right-sized EC2 instances directly
  from a NodePool's constraints. Neither is installed: both need IRSA and a real ASG/EC2.
- **The node group's labels did not reach the node**, so I labelled it by hand (`workload=usms tier=app`).
- nodeSelector `workload=usms` applied (rollout, pods on `638a0cfc7f6e`). With `workload=nonexistent`
  the new pod sat `Pending` with `0/1 nodes are available: 1 node(s) didn't match Pod's node
  affinity/selector`, **while both old pods kept serving** (`maxUnavailable: 0`). Restored.
- The manifest was updated so the repo matches the cluster. The lab's Python snippet would not have
  matched, because Lab 07 Exercise 4 put `topologySpreadConstraints` first, so I inserted after the
  pod-template `spec:` instead. `kubectl diff`: no spec difference.

## Step 12 - PDBs

**Ownership fix:** Lab 07 Exercise 4 had put a `usms-enrolment-pdb` (`minAvailable: 1`) inside
`manifests/lab-07/20-enrolment.yaml`. Lab 08 defines the same name with `maxUnavailable: 1`. With
both files declaring it, every `apply` of one flips the other (it showed as `configured` on every
apply in Step 5). I moved ownership to `manifests/lab-08/30-pdb-gateway.yaml` and left a pointer comment.

`usms-gateway-pdb` minAvailable 1 -> **ALLOWED DISRUPTIONS 0**; `usms-enrolment-pdb` maxUnavailable 1
-> **1**. The eviction API answered `Error from server (TooManyRequests): Cannot evict pod as it would
violate the pod's disruption budget.` A plain `kubectl delete pod` went straight through and the
ReplicaSet replaced it. The drain was run with `--dry-run=client` only: nothing was cordoned.

## Steps 13-16 - the exposure ladder

| Rung | Result here |
|---|---|
| ClusterIP | `curl 10.43.6.213` from the Mac fails: not routable (observed) |
| port-forward | `localhost:18080` -> gateway, enrolment and results JSON (observed) |
| NodePort | `usms-results-np` `80:30080`; in-cluster `wget 172.17.0.3:30080` answers (observed, one node only). `localhost:30080` fails (exit 7): the node container publishes only 6443 (Floci limitation); port-forward fallback used |
| LoadBalancer | `usms-gateway` `LoadBalancer`, `clusterIP=10.43.6.213 nodePort=30564 external=172.17.0.3`. **k3s's service-lb-controller fulfilled it** (`svclb-usms-gateway-*` DaemonSet), and in-cluster `wget 172.17.0.3` answers. `localhost:8081/8082` fail: `_lb_ports_` did not publish host ports on this build |
| Ingress | `usms-portal-ingress` stored with three Prefix paths, **CLASS `<none>`, no ADDRESS**: no controller (conceptual) |

One correction to my own evidence: my first LoadBalancer screenshot printed "no service load balancer
controller" because I grepped for `servicelb|klipper`, while k3s names the pods `svclb-*`. Retaken.

**Without a controller - the four Lab 05 `aws elbv2` calls the AWS Load Balancer Controller would make,
in order:** (1) `create-load-balancer` (internet-facing ALB in the two public subnets, from `scheme`);
(2) `create-target-group --target-type ip`, one per backend Service (`target-type: ip`,
`healthcheck-path`); (3) `create-listener` on HTTP 80 (`listen-ports`) with a default action; (4)
`create-rule` per path. Then it registers pod IPs from the Endpoints and keeps them in step, which in
Lab 05 was ECS's job.

**Longest prefix vs priority:** the Ingress sends `/enrolment/x` to usms-enrolment although `/` also
matches, because the longest matching Prefix wins. Lab 05's ALB used numeric rule priority, where
order is what you set.

## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | `desiredCount` of `usms-enrolment-svc` (2 now) | `spec.replicas` of Deployment `usms-enrolment` (2 now) |
| Who writes it? | Application Auto Scaling, via the scalable target `service/usms-ecs-cluster/usms-enrolment-svc` (2..10) | The HPA controller inside kube-controller-manager (`usms-enrolment-hpa`, 2..8) |
| Where does that thing run? | An AWS regional service, outside anything I own | In the cluster's control plane (AWS-operated on EKS; inside the k3s server here) |
| Where does the metric come from? | CloudWatch (`ECSServiceAverageCPUUtilization`, ALB request count) | metrics-server, which scrapes kubelets, via `metrics.k8s.io` |
| What does "50% CPU" mean - 50% of what? | Of the task's reserved CPU (256 units here) | Of the container's **request** (50m), i.e. 25m per pod |
| How is scale-in slowed down? | `ScaleInCooldown: 300` | `behavior.scaleDown.stabilizationWindowSeconds: 300` + 1 pod/60 s, `selectPolicy: Min` |
| What happens if there is no capacity for the new instance/pod? | Fargate provisions it: there are no nodes to run out of | Pods sit `Pending` until a node is added (Step 10/11); nothing else happens |
| What creates the alarms, if anything? | Target tracking creates two CloudWatch alarms for me | None: the controller polls every 15 s |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | ALB, target group, listener, rules, SG rules: about 5+ `elbv2`/`ec2` calls | Zero by hand; one Ingress object (the controller would create the ALB, TGs, listener, rules) |
| What is the target type, and why? | `ip`: Fargate tasks have their own ENI addresses | `ip` (`alb.ingress.kubernetes.io/target-type: ip`): pods have VPC addresses via the VPC CNI |
| How are targets registered and deregistered? | ECS registers and deregisters tasks with the target group | The controller watches Endpoints and registers ready pod IPs |
| How are competing routing rules disambiguated? | Numeric listener-rule priority | Longest matching path (`pathType: Prefix`) |
| What would I change to move this to another cloud? | Everything: ALB, TG, listener and ECS service are AWS APIs | The `alb.ingress.kubernetes.io/*` annotations and ingress class; the rules stay |
| What is the cost of exposing ten services? | One ALB with ten rules (if I build it that way) | One ALB with ten paths; ten LoadBalancer Services would be ten NLBs |

### Two paragraphs

1. **If the AWS control plane has a bad afternoon:** the ECS arrangement stops scaling entirely,
   because Application Auto Scaling, CloudWatch alarms and the ECS scheduler are all AWS services. The
   running tasks keep serving, but nothing moves `desiredCount` and I can only debug through the same
   AWS APIs that are struggling. On EKS the HPA lives in the cluster's own controller manager, so as
   long as the EKS API server for my cluster is up it keeps scaling pods within existing node
   capacity. I can still `kubectl describe hpa`, read events and `kubectl top`. What I lose is the AWS
   half: no new nodes (ASG/EC2), no new load balancer targets.
2. **For USMS I would choose ECS on Fargate.** The strongest argument against it is portability and
   tooling: the Kubernetes manifests in `manifests/lab-07` and `lab-08` would run on any conformant
   cluster, and Kubernetes gave me readiness-gated endpoints, rollback to any of five ReplicaSets, PDBs
   and an HPA I can watch and reason about locally. A team that might leave AWS, or that already
   runs Kubernetes elsewhere, should weigh that heavily.

## Step 18 - persistence

`outputs/lab-08-before-restart.txt` vs `...-after-restart.txt`: **PERSISTENCE PROVEN**: HPA 2/8/50, PDBs
1/1, `usms-results-np` 30080, **even `usms-gateway`'s auto-allocated nodePort 30564** (the Service
object persisted, so its allocation did too), Ingress paths, node group 2/4/2.

What the restart did that the diff doesn't show:
- After 30 s the cluster was still `CREATING`; the PDF's `update-kubeconfig` fallback failed with
  `Cluster status is CREATING`. Waiting for `ACTIVE` was enough; the kubeconfig was fine.
- The k3s container came back as a new node `a7a37a91c9a8`, leaving the old `638a0cfc7f6e` as a ghost
  (same as Lab 07). I deleted the ghost node object and pod GC rescheduled everything.
- **The new node had no `workload=usms` label**, so with Step 11's nodeSelector a rescheduled enrolment
  pod sat `Pending` (`didn't match Pod's node affinity/selector`) until I relabelled it. On real EKS the
  node group applies its labels to every node it launches; here a restart is a new, unlabelled node.
  Consequence: **after any Floci restart, relabel the node before expecting enrolment to schedule.**
- The HPA read `<unknown>/50%` for about a minute while metrics-server restarted, then `2%/50%`.
- `EXTERNAL-IP` stayed `172.17.0.3` (svclb came back on the new node with the same address).

## Step 19

`configs/lab-08.env`: **19 exports**. `hpa: 2..8 at 50% cpu, scale-in window 300s`, `nodeport: 30080`,
`gateway: LoadBalancer`, node group `2/4/2` (not 2/6/3, see Step 10). Expected exception:
`USMS_INGRESS_CLASS` is **empty** (no controller).

**macOS gotcha:** the lab's check `grep -n 'export .*=$\|None'` printed "all values populated" even
though `USMS_INGRESS_CLASS=` is empty. BSD grep (macOS) has no `\|` alternation in basic regex, so the
pattern matches nothing. `grep -nE 'export .*=$|None'` shows line 20 correctly.

## Section 14 - review questions

**1. "Scales when the node hits 50% CPU."** No: `averageUtilization: 50` is 50% of the
**container's CPU request**, averaged over the target's ready pods. With a 50m request the HPA aims
for 25m per pod, whatever the node is doing: here the node sat at about 1% while enrolment ran at 61%
and scaled out. If someone halves the request to 25m without touching the HPA, the same absolute
load reads as twice the percentage. The HPA scales out at 12.5m per pod, so it creates **more pods**
for the same traffic. Each pod also reserves less, so the scheduler packs more per node. Total capacity
reserved per unit of real load drops, and the recorded percentages are no longer comparable with
anything measured before. More pods, less real headroom per pod, and harder to reason about.

**2. Ten times by Monday.** See the Step 3 "Your turn" above: (1) raise `maxReplicas` and let the HPA
add pods; check they become `Ready`, not `Pending`. (2) Add nodes: raise the node group's
max/desired (or rely on Cluster Autoscaler/Karpenter); check new nodes `Ready` and the `Pending` pods
scheduled. (3) Only if a single pod is the bottleneck, raise requests/limits; check `kubectl top`,
OOMKills, and that the HPA target still means what I think. **Dimension 4, bigger instance types,
can't change in place:** create a second node group with the new `instanceTypes`, cordon and drain
the old one (PDBs keep the services up), then delete it.

**3. Outside vs inside.** (a) **Failure domain:** Application Auto Scaling depends on CloudWatch and
the ECS API, so an AWS regional incident stops ECS scaling. The HPA depends on my cluster's API server
and metrics-server, so a broken metrics-server (the `<unknown>` I saw after the restart) stops EKS
scaling while AWS is perfectly healthy. Each has a failure mode the other doesn't. (b)
**Ownership and visibility:** the HPA is a Kubernetes object in my repo (`10-hpa-enrolment.yaml`),
versioned and diffable, and debuggable with `kubectl describe` and events. Application Auto Scaling
state lives in AWS and is inspected through AWS APIs and CloudWatch alarms. (c) **Blast radius:** a
bad HPA edit affects one Deployment in my cluster; a bad scalable-target change is an AWS API call
that IAM must allow.

**4. 4 -> 8 replicas, four `Pending` for twenty minutes.** The HPA (loop 1, workload) did its job
and wrote `replicas: 8`. The scheduler has nowhere to put four of them (`Insufficient cpu`). The node
group's `desiredSize` (loop 2, infrastructure) is a different integer on a different API, and nothing
connects the two unless a **Cluster Autoscaler or Karpenter** is installed to watch `Pending` pods and
raise it. Lowering the CPU request would let the pods fit, but it changes the HPA's denominator: the
same load reads as a higher percentage, the HPA wants even more pods, every recorded percentage
becomes incomparable, and each pod reserves less than it actually needs, so the node is overcommitted.
The fix is capacity (nodes) or a lower `maxReplicas`, not a smaller request.

**5. NodePort vs LoadBalancer.** A NodePort opens one high port (30000-32767) on **every node**,
and callers must know node addresses and that port. A LoadBalancer *contains* a NodePort and adds one
stable address in front, provisioned by a controller (an NLB on AWS, `svclb` here). Requirement: "the
Examinations Office needs one stable address on port 80 that survives node replacement." A NodePort
fails it, because nodes come and go (I watched the node name change on every restart) and the port is
30080, not 80. A LoadBalancer meets it.

**6. `/enrolment` via the Ingress directly, or via the gateway?** I would route **everything through
the gateway** and delete the `/enrolment` and `/results` rules from the Ingress, leaving `/` ->
`usms-gateway`. The gateway is where the application's routing lives: it strips the prefix
(`proxy_pass .../;`), sets `Host` and `X-Forwarded-For`, and is the single place to add auth, rate
limits or logging later. The direct Ingress rule bypasses all of that, and on this build sends
`/enrolment/x` to enrolment *with* the prefix, which the gateway would have stripped. The cost of
going through the gateway is one extra hop and the gateway becoming a dependency, which Exercise 2's
two replicas and PDB address.

**7. A PDB didn't stop `kubectl delete pod`.** Correct behaviour: a PDB constrains the **eviction
API**, which cooperative, voluntary processes use (`kubectl drain`, node-group upgrades, Cluster
Autoscaler scale-in). `kubectl delete` is a direct deletion, not an eviction, so it bypasses the PDB;
I saw `TooManyRequests` from the eviction call and an immediate success from the delete. **Voluntary**
= something with an API asked (drain, upgrade, autoscaler); **involuntary** = nobody asked (kernel
panic, OOM, instance terminated, hardware). PDBs only govern the first. Real save: an EKS managed
node-group **version upgrade** drains nodes one by one. With `usms-enrolment-pdb` (maxUnavailable 1)
and two gateway replicas, the upgrade can never evict both enrolment pods or both gateway pods at
once. Without the PDBs, a drain could take every replica on that node down together during
registration week.

## Exercises (details and evidence in labs/lab-08-eks-scaling/exercises.md)

- Ex 1: `usms-results-hpa` 2..6 at 60%, 180 s scale-in window, +2 pods/30 s; both HPAs report percentages.
- Ex 2: gateway `replicas: 2` -> `usms-gateway-pdb` ALLOWED DISRUPTIONS 0 -> 1; clean `kubectl diff`.
  Ownership of the `usms-gateway` Service moved to Lab 08's `50-service-loadbalancer.yaml`, and
  `verify-lab-07.sh`'s "exactly 1 gateway replica" became "at least 1".
- Ex 3: the request fault did **not** give `<unknown>` on k8s v1.34: request defaulted to the 200m
  limit (pods `Guaranteed`). Fault 2 `minReplicas = maxReplicas = 4` -> `ScalingLimited`. Fixes: explicit
  `cpu: 50m` request, `maxReplicas: 8`. Deleted afterwards.
- Ex 4: `usms-results-ingress` (`/results` only), same IngressGroup -> one ALB, source-IP condition.
- Ex 5: `outputs/lab-08-scaling-evidence.json`, `outputs/lab-08-lab06-readiness.txt`, and the essay below.

## ECS or Kubernetes for USMS

**Recommendation: ECS on Fargate, with Application Auto Scaling.**

USMS is one small team in one region with a sharply seasonal load. Practicals 2 and 4 showed that for
that profile the operational surface matters more than the feature list.

Three observations from my own runs:

1. **Kubernetes needed two scaling loops; ECS needed one.** The HPA took enrolment from 2 to 3 pods in
   about 20 seconds, but `update-nodegroup-config` failed outright here. On real EKS the node side
   would still need a Cluster Autoscaler or Karpenter, with IRSA, before the HPA's extra pods could run
   anywhere. Fargate in Lab 06 has no node dimension to exhaust.
2. **State drifted in ways ECS never showed me.** Re-applying a manifest silently reverted a Secret
   (Lab 07), flipped a PDB between two files, and would have demoted the gateway from LoadBalancer to
   ClusterIP. After every Floci restart the node came back unlabelled, so the nodeSelector left
   enrolment `Pending`. Each was fixable, but each needed someone who knows to look.
3. **Exposure took four rungs and a controller.** ClusterIP, port-forward, NodePort and LoadBalancer
   all worked in-cluster, but the Ingress, the piece that maps to Lab 05's ALB, did nothing without a
   controller. Lab 05 gave me a working ALB with five `elbv2` calls.

**The strongest argument against my choice:** everything in `manifests/lab-07` and `lab-08` is
portable and reviewable. I could watch the HPA's arithmetic, read its events verbatim, prove PDBs
against the eviction API and roll back any of five ReplicaSets, all locally. ECS ties USMS to AWS APIs
for every one of those things. If the university ever needed to leave AWS, or standardise on Kubernetes
across departments, that lock-in would cost more than the operational overhead I am trying to avoid.
