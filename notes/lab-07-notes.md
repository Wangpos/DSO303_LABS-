# Lab 07 notes

## Lab 07 support path
Probed on 2026-11-04T14:27:09Z
PATH A  - use aws eks throughout

**Path A in full.** `aws eks list-clusters` answered, `kubectl` at `/opt/homebrew/bin/kubectl`,
`k3d` MISSING (not needed on Path A). Floci (`floci/floci:latest`) runs the cluster as one k3s
container, `floci-floci-course-eks-usms-eks-cluster`, publishing the API on **host port 6500**
(`https://localhost:6500`), not the 6443 the lab text shows. The kubeconfig context is `usms-eks-local`.
Floci also runs the cluster at k3s **v1.34.1**, though `describe-cluster` reports the requested `1.30`.

## Step 3 - "EKS is just ECS with different names"

**False:** the data-plane column. On EKS the nodes are EC2 instances in my account that I patch,
upgrade (`update-nodegroup-version` is a separate operation from the control plane's) and give their
own IAM role. ECS on Fargate has nothing in that column at all. EKS also has two IAM roles,
trusting two different principals, where Fargate ECS has a task role and an execution role and no
machine identity.

**Nearly true:** both are a control plane that keeps N copies of a container spec alive behind a
stable name and replaces them on a rolling update. Task definition ~ pod template, service ~
Deployment + Service, desiredCount ~ replicas. The concepts map almost one to one; the operating
burden does not.

## Step 9 - "Your turn": version and OIDC issuer side by side

```
aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.[version,identity.oidc.issuer]' --output text
1.30    https://oidc.eks.us-east-1.amazonaws.com/id/41C362328DF44931A95BD74C24A130B9
```

The OIDC issuer is the URL where the cluster publishes the public keys that sign its ServiceAccount
tokens. IAM trusts that issuer (as an OpenID Connect provider), so a pod's projected token can be
exchanged for role credentials with `sts:AssumeRoleWithWebIdentity`. That exchange is IRSA.
**This build returns a URL rather than `None`**: it supports more than most (see Step 21).

`_lb_ports_` was present at creation: `cluster.tags._lb_ports_` = `8081,8082`. No `tag-resource` fix
was needed.

## Step 10 - node group, as recorded vs as provisioned

`usms-eks-nodes` is ACTIVE in `subnet-8414d8e6` + `subnet-4083c7d2` (the two private subnets),
min 2 / max 4 / desired 2, `t3.small`, `AL2023_x86_64_STANDARD`. **None of that is provisioned.**
`kubectl get nodes` shows a **single** k3s node, which is also the control plane. desired=2 is a
number Floci stores. Consequences seen later: Step 19's FailedScheduling said `0/1 nodes`, and
Exercise 4 cannot spread across nodes.

## Step 16 - "Your turn": who created the replacement pod

Deleted `usms-enrolment-6965b8dbbb-2sshl`. The tally afterwards (`outputs/lab-07-tally-after-delete.txt`)
shows `...-b78mm` (survivor) and a new `...-589gb`, and no request failed.
**The ReplicaSet `usms-enrolment-6965b8dbbb` created the replacement:** its controller saw 1 pod
where its spec said 2. The Deployment owns the ReplicaSet but does not create pods itself.

## Step 17 - Secret

- `50-secret.yaml` was moved to `outputs/lab-07-secret.yaml` (chmod 600, git-ignored) rather than
  committed. The manifests directory therefore has no `50-` file.
- `base64 -d` of `.data.ENROLMENT_API_TOKEN` printed `floci-dummy-token-not-a-real-secret`. No key
  needed, only `get secret`.
- **Found on 2026-11-06:** re-applying `20-enrolment.yaml` for Exercise 4 removed the
  `envFrom.secretRef` that `kubectl set env --from=secret/...` had added, because the manifest
  did not contain it. `kubectl apply` makes the live object match the file. Fixed by adding the
  `secretRef` to the manifest itself. An imperative change you never write back to the manifest
  gets reverted by the next `apply`.

## Step 18 - rollout and rollback

- The ConfigMap change to 1.1.0 did not reach running pods until `rollout restart` (the `annotate`
  on Deployment metadata did not roll, as the lab warned).
- After `rollout undo` the pod still said 1.1.0: undo reverts the **pod template**, and the
  ConfigMap is not part of it. Restored the ConfigMap to 1.0.0 and restarted.

**"Your turn" on usms-results:** `set image ... results=nginx:1.27`, then `rollout undo`.
`rollout history` showed **two revisions** (the original was renumbered on undo).
The watch (`outputs/lab-07-results-watch.txt`) peaked at **three pods** (two old Running + one new),
and a ready count never dropped below 2. **It did not differ from usms-enrolment.** The default 25%
of 2 replicas rounds `maxSurge` up to 1 and `maxUnavailable` **down to 0**, the same 0/+1 as
enrolment's explicit setting. The lab's "one pod may be unavailable" applies only at 4+ replicas.

## Step 19 - three failures

All three produced and diagnosed (`outputs/lab-07-failures.txt`):
- `ImagePullBackOff`: describe events `Failed to pull image ... not found`, then `ErrImagePull`.
  The two old pods stayed `Running`. Fixed with `rollout undo`.
- `FailedScheduling`: `0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory`.
  One node, confirming Step 10.
- `CrashLoopBackOff`: `logs` / `logs --previous` showed `fatal: no database configured`, Exit Code 1.
All three temporary pods deleted.

## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | Task definition `usms-enrolment:2` (a versioned, immutable AWS resource) | Pod template inside the Deployment `usms-enrolment` |
| What keeps N copies alive? | The ECS service scheduler (`desiredCount` 2, `runningCount` 2) | The ReplicaSet the Deployment owns (`replicas: 2`) |
| What gives it a stable name? | The ALB / target group (`usms-enrolment-alb`) in front of the service | The ClusterIP Service `usms-enrolment` (10.43.137.249) |
| How does another service find it? | ALB DNS name, or Cloud Map service discovery | CoreDNS: `usms-enrolment.usms.svc.cluster.local`, kube-proxy picks an endpoint |
| What does a rolling update create? | A new deployment in the service using a new task definition revision | A new ReplicaSet (new pod-template hash) |
| Where does rollback state live? | Previous task definition revisions; you update the service back to one | Old ReplicaSets scaled to 0, up to `revisionHistoryLimit` (5) |
| Which IAM role does the app code use? | Task role `usms-ecs-task-role` (per task) | The node role `usms-eks-node-role` (every pod on the node), or IRSA per ServiceAccount on real EKS |
| What would I have to change to move to another cloud? | Everything: task defs, service, ALB wiring are all AWS APIs | Not the manifests. The IAM roles, VPC/subnets, node group, LoadBalancer annotations and IRSA |

For USMS I would choose **ECS on Fargate**. A small team with no node patching, IAM per task
without IRSA plumbing, and Application Auto Scaling covers the eight-quiet/two-busy profile. I'd
reconsider Kubernetes only if portability across providers or a much larger service count
became a requirement.

## Step 21 - IRSA

| # | IRSA step | This build |
|---|---|---|
| 1 | Cluster publishes an OIDC issuer | **Yes**: `describe-cluster` returns `https://oidc.eks.us-east-1.amazonaws.com/id/41C3...30B9`. The document behind it is not reachable (the cluster is local) |
| 2 | Register it in IAM as an OIDC provider | **Yes**: `list-open-id-connect-providers` returns `arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/41C362328DF44931A95BD74C24A130B9` |
| 3 | Role trusting `system:serviceaccount:usms:usms-enrolment-sa` | Not created (no workload role in the lab spec) |
| 4 | Annotate the ServiceAccount | `usms-enrolment-sa` created (`60-serviceaccount.yaml`), **not annotated** |
| 5 | Webhook injects token + env vars | **No**: there is no EKS pod-identity webhook in k3s |
| 6 | SDK calls `AssumeRoleWithWebIdentity` | No: depends on 5 |

So: "I wrote the ServiceAccount, registered the provider Floci reported, and recorded that the
injection half does not exist on this build." Not "I configured IRSA".

## Step 22 - persistence

`outputs/lab-07-before-restart.txt` and `...-after-restart.txt` match: cluster ACTIVE 1.30,
node group ACTIVE desired 2, three Deployments 2/1/2, the same three ClusterIPs. **PERSISTENCE PROVEN**
(the after-read waited until the cluster finished reconciling from `CREATING` to `ACTIVE`).

**Restart caveat, observed 2026-11-06:** after a fresh `floci-up.sh` the cluster went `CREATING` ->
`ACTIVE` in ~10 s, but the recreated k3s container had a **new hostname**, so a second node
`db462e773ab9` registered. The old node `6dcff04e23f8` kept `Ready=True` with a heartbeat from two days
earlier, and every pod (CoreDNS included) was still bound to it. Inside the cluster the smoke test
failed with `bad address` until the node controller marked the ghost NotReady and evicted the pods
onto the live node. Object state persists; **pod placement does not survive the restart for a few
minutes.** Wait for that before running verify after any Floci restart.
After the eviction I deleted the ghost node object (`kubectl delete node 6dcff04e23f8`; its container
no longer existed) and force-deleted the orphaned `Terminating` pods. The smoke test passed on all four
routes, and `verify-lab-07.sh` gave `PASS=30 FAIL=0` (`outputs/lab-07-verify-2026-11-06.txt`).

## Exercises 4 and 5 (details in labs/lab-07-eks/exercises.md)

- Ex 4: one schedulable node, so the spread constraint is configured but cannot be shown spreading.
  The PDB was shown under a real `kubectl drain`: one eviction allowed, the second refused
  ("would violate the pod's disruption budget"), smoke loop 40/40 ok.
- Ex 5 Part 1: the metrics API **is** available (k3s ships metrics-server), but only after it moved
  off the ghost node. Idle enrolment pods use 4m and 5m, 8-10% of the 50m request.

## Step 23

`configs/lab-07.env`: 21 exports, no empty values. Note `USMS_EKS_ENDPOINT=https://localhost:6500`.

## Section 14 - review questions

**1. ACTIVE cluster, every pod Pending.** `ACTIVE` describes the control plane only: API server,
etcd and scheduler are up, so the cluster accepts objects. Pods need the data plane: a node with
room that will accept them. Two configurations that give exactly this: (a) no node group, or a node
group whose nodes never registered (node role missing `eks:DescribeCluster`, or nodes in subnets
with no route to the endpoint). The only node is the control plane, whose `NoSchedule` taint
repels pods (Troubleshooting entry 4). (b) Pods requesting more CPU/memory than any node has, as
`usms-toobig` did: `FailedScheduling ... Insufficient cpu`.

**2. Swapped trust policies.** The cluster role would trust `ec2.amazonaws.com` and the node role
`eks.amazonaws.com`. On real AWS, `create-cluster` in Step 8 fails straight away: EKS cannot assume a
role that does not trust `eks.amazonaws.com`. Had that somehow passed, Step 10 would fail: the
instances could not assume the node role, so kubelets get no credentials and the node group goes
`CREATE_FAILED` with nodes never joining. Floci does not evaluate trust, so here nothing breaks
and only `verify-lab-07.sh`'s trust checks would catch it.

**3. Readiness vs liveness.** Readiness answers "should this pod get traffic now?" Failing it takes
the pod out of the Service's endpoints, and nothing restarts. Liveness answers "is this process
wedged beyond repair?" Failing it kills and restarts the container. Getting it backwards: put a
check that depends on the database or on load (slow responses) on **liveness**. When the database
blips or traffic spikes, every replica fails liveness together and is restarted together, which
turns a brief slowdown into a full outage that feeds on itself. That check belongs on readiness,
where the pods would just drop out until they recover. Exercise 3 showed the readiness side: a 404
on `/healthz` left the pods `Running` but with zero endpoints.

**4. Rollback still said 1.1.0.** `rollout undo` restores an older ReplicaSet's pod template. The
template only *references* `usms-app-config` by name, and that ConfigMap still held 1.1.0, so the
"rolled-back" pods read the new value. "Kubernetes rollback is not really a rollback" is **fair for
releases that change config**: it is an image/template rollback, not a release rollback. The fix is
to version configuration with the workload: immutable, content-named ConfigMaps (`usms-app-config-v2`,
or a hash suffix as Kustomize's `configMapGenerator` does) referenced from the template, so a
rollback points the template back at the old config too. Or deploy through GitOps, where reverting
the commit reverts both.

**5. maxUnavailable 0 vs default with 2 replicas.** `maxUnavailable: 0, maxSurge: 1` always keeps
2 ready pods and briefly runs 3. Suited to user-facing services that must keep full capacity, such
as enrolment during registration week. With **2** replicas the default 25%/25% rounds to the same
0/+1 (observed in Step 18). The default only diverges at 4+ replicas, where it allows one down
pod. That suits stateless workers or batch consumers where speed or quota matters more than full
capacity during a roll. Lab 04's ECS `minimumHealthyPercent 100` / `maximumPercent 200` is closest
to the explicit `maxUnavailable: 0`.

**6. "A Secret is encrypted, so committing it is fine."** Wrong. A Secret is **base64**, an
encoding. Step 17 decoded it with `base64 -d` and needed no key. What a Secret does give you: the
value stays out of the image and the pod spec, access can be RBAC-restricted separately from
ConfigMaps, and `describe` hides it. It gives no confidentiality at rest unless etcd encryption is
on, none inside the pod (`printenv` shows it in plain text), and none in Git: a committed manifest
is plaintext in history forever. On real EKS I would enable **KMS envelope encryption** of Secrets
at cluster creation, keep values out of Git entirely (AWS Secrets Manager plus the Secrets Store CSI
driver or External Secrets), and use **IRSA / Pod Identity** instead of stored AWS keys. That's why I
moved `50-secret.yaml` into `outputs/`.

**7. ECS or Kubernetes for USMS.** **ECS.** Harder in this lab than in Lab 04: (a) two extra IAM
roles plus stand-in policies before a single container ran, and a node group whose capacity, AMI
and upgrades are mine; (b) a second tool and endpoint (`kubectl` on 6500 alongside the AWS CLI on
4566), with a kubeconfig context to get wrong; (c) per-pod AWS permissions need IRSA's OIDC chain,
where ECS has a task role field. For a small team, a quiet eight months pays for a cluster and
nodes that sit idle, while Fargate plus Application Auto Scaling (Lab 06) scales to the busy two
with nothing to patch. What Kubernetes gave that ECS could not: **portable, declarative
manifests** (the `usms` namespace would apply unchanged to any conformant cluster), plus built-in
DNS service discovery and rollback to any of the last five ReplicaSets with one command.

## Exercise 5 Part 3 - which `configs/lab-07.env` variables Lab 08 needs

- `USMS_EKS_CLUSTER`: every `aws eks` call and `update-kubeconfig` names the cluster.
- `USMS_EKS_NODEGROUP`: Lab 08 Step 10 changes node-group scaling with `update-nodegroup-config`.
- `USMS_EKS_NAMESPACE`: every `kubectl` command works inside `usms`.
- `USMS_EKS_LB_PORTS`: without `8081,8082` no LoadBalancer/Ingress gets a host port, and the fix
  is to recreate the cluster.
- `USMS_EKS_ENDPOINT`: confirms `kubectl` points at this cluster (`https://localhost:6500`) after a
  restart. It matters here because Floci did not use 6443.
- `USMS_K8S_DEPLOY_ENROLMENT`: the Deployment the HPA targets.
- `USMS_K8S_DEPLOY_GATEWAY` / `USMS_K8S_SVC_GATEWAY`: the Service that becomes NodePort, then
  LoadBalancer, then sits behind the Ingress.
- `USMS_K8S_CPU_REQUEST`: 50m is the denominator of the HPA's utilisation, needed to check its
  arithmetic.
- `USMS_EKS_CLUSTER_STATUS`: a quick ACTIVE check before starting.
- Not needed by Lab 08: role/policy ARNs, SG ID, version and the results Deployment/Service names.
  They are inventory for Lab 09's IAM review and for cleanup.
