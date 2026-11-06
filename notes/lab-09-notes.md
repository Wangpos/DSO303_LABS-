# Lab 09 Notes - Security Review

**Support path: B.** Floci 2.1.0. `simulate-principal-policy` answers, so Step 9 has a simulated
cross-check. `get-account-authorization-details` and `get-credential-report` are **not available**.
IAM and security groups are stored and returned but **never enforced**.

**`usms-student-data` did not exist when Step 6 ran:** `head-bucket` returned 404 (exit 254). Lab 10
creates it. Every transcripts claim in this lab is therefore a claim about policy documents, not
about objects.

Run date: 2026-11-06.

---

## Pre-flight repairs (before Step 1 could pass)

- **Lab 01's three users had gone** (`usms-dev-01`, `usms-admin-01`, `usms-audit-01`), probably after
  an earlier state reset.
  - I recreated them, tagged `RecreatedBy=lab-09-preflight`.
  - I created one access key for `usms-dev-01` into `outputs/usms-dev-01-access-key.json` (git-ignored)
    and pointed the `usms-dev` profile at it.
  - `~/.aws` was backed up first.
- **`configs/lab-01.env` lacked four names the lab sources:** `USMS_ADMIN_USER`, `USMS_AUDIT_USER`,
  `USMS_ROLE_EC2` and `USMS_ROLE_LAMBDA`. I appended them with a comment.
- **`usms-lambda-exec-role` was also missing.** I recreated it in Exercise 2 Part B, with a scoped
  trust policy instead of Lab 01's unconditioned one.
- **Baseline (`outputs/lab-09-pre-verify.txt`):**

  | Script | Result |
  |---|---|
  | lab-02 | `6 Passed, 0 Failed` |
  | lab-03 | `PASS=35 FAIL=1` (`usms-web-01` stopped) |
  | lab-04 | `39/0` |
  | lab-05 | `47/2` |
  | lab-06 | `39/3` |

  Every failure is a documented Floci limitation from its own lab. Step 18 only has to reproduce these
  lines. Lab 05 and 06 print remedy text after their summary line, so the baseline uses
  `grep -E 'PASS=|Passed' | tail -1` rather than the PDF's `tail -1`. Step 18 used the same extraction.

---

## "Your turn" answers

### Step 4 - two trust policies side by side

`usms-ec2-app-role` trusts a **service** (`ec2.amazonaws.com`): only EC2 can assume it, acting on
behalf of whatever instance wears the profile. Its risk is the confused deputy.

`usms-developer-role` trusted **`Principal: {"AWS": "*"}`**, so on real AWS any authenticated
principal in **any account** could assume it, limited only by that caller's own identity policy. That
is not a deputy problem; it is an open door.

The difference is not syntax but **who the assumer is**: one names a service that acts as a
middleman, the other names nobody, which means everybody. Exercise 2 Part B narrowed it to this
account's root (`policies/trust-account-developers.json`, Lab 01's own file).

### Step 6 - the two action lists

**The enrolment API, to display one student's transcript:**
- `s3:GetObject` on `arn:aws:s3:::usms-student-data/*`
- `s3:ListBucket` on `arn:aws:s3:::usms-student-data`

`s3:ListBucket` is there because without it S3 answers a missing key with **403 AccessDenied** instead
of **404 NoSuchKey**. The application could not tell "this student has no transcript yet" from "I am
not allowed".

**The registry's upload workflow, to store one:**
- `s3:PutObject` on `.../*`
- the same `s3:ListBucket`, to check before overwriting
- `s3:GetObject`, to read back what it wrote

**The single action in the second list and not the first: `s3:PutObject`.**

Lab 01's `USMSStudentDataReadWrite` also grants `s3:DeleteObject` and `s3:GetBucketLocation`, which
neither workflow needs. `DeleteObject` on the academic record is the dangerous one. It is a finding for
Lab 10: delete belongs to a records-retention process, not to the web tier.

### Step 10 - the rotation pause

Part 4 deactivated the old key and proved the profile still worked on the new one. On a real system I
would **wait a day to a week** at this point, watching `get-access-key-last-used`, before deleting.
**This lab compressed that pause to seconds.** Floci returns the last-used field, but with `N/A`.

### Step 11 - IMDSv2: the attacks and the rollout

- **`--http-tokens required` prevents SSRF credential theft.** A web bug that makes the server GET an
  attacker-chosen URL can no longer read `169.254.169.254/latest/meta-data/iam/security-credentials/`.
  IMDSv2 first needs a **PUT** with a custom header to get a session token, and a typical SSRF primitive
  cannot issue one.
- **`--http-put-response-hop-limit 1` prevents a different attack:** a process **one network hop away**
  obtaining a token. That covers a container in bridge networking on the instance, or an open proxy or
  forwarder running on it. The token response's IP TTL is 1, so it dies at the first hop.
- **Rollout order that avoids an outage:**
  1. Watch the per-instance `MetadataNoToken` CloudWatch metric, so you know who still calls IMDSv1.
  2. Upgrade those SDKs and agents.
  3. Set `required` on one instance and verify the application still gets credentials.
  4. Then do the fleet, and make `required` the launch-template default so new instances start correct.

  The metric does not exist on Floci, so that step was reasoned about, not observed.

`usms-web-01` read back `optional -> required`, hop limit `1 -> 1`, endpoint enabled. Floci **stored**
the change, but there is no metadata service behind it to enforce anything.

### Step 11 - usms-db-01, which has no instance profile

Applied `--http-endpoint disabled --http-tokens required` and read back `HttpEndpoint: disabled`,
`HttpTokens: required`. **Justification:** with no role there are no credentials to protect, so the
safest metadata service is none at all. Every SSRF and hop-limit question disappears.

**The same setting on `usms-web-01` would break its instance-profile credentials:** the SDK's
`s3:GetObject` and `sts` calls would fail with no credentials. Anything else reading metadata (region
discovery, user-data or `cfn-init`) would fail too.

### Step 15 - what written egress does not stop

`usms-db-sg` now allows only tcp/443 to `0.0.0.0/0`. DNS out, SSH out, database connections out, SMTP
and HTTP on 80 are denied. **Port 443 to the whole internet still permits an HTTPS POST of the
database to anywhere.** Stopping that needs **hostname filtering**: AWS Network Firewall domain lists,
or an egress proxy. Security groups match addresses and ports, never names. Exercise 4 prices it.

The same is true of `usms-enrolment-sg`, whose second 443 rule is `0.0.0.0/0` for the AWS APIs that
have no prefix list.

### Step 17 - Review Question 5 sentences

- **If control 3 failed** (an IGW route appeared on the private subnet), `usms-db-01` would still have
  no public address and its subnet would not auto-assign one. Nothing on the internet would have an
  address to send to, and `usms-db-sg` would still admit only `usms-app-sg`.
- **If control 4 failed** (`usms-db-sg` opened 5432 to `0.0.0.0/0`), no packet from the internet could
  arrive anyway: there is no public address and no IGW route. Only something already inside the VPC
  could exploit the wider rule, and `usms-private-nacl` would still apply its explicit allow list.

### Step 17 - the single point of control, said in the report as asked

`usms-alb-sg` admits the internet on two rules (80 and 443). `usms-bastion-sg`, `usms-db-sg`,
`usms-eks-cluster-sg` and `usms-enrolment-sg` are each protected by **exactly one ingress rule**. For
those, one mistaken edit to that one rule is the whole of the security-group protection.

For the data and enrolment tiers, the private subnet and the absence of public addresses are further
controls that the matrix does not model. Exercise 3's report models both axes for that reason.

---

## Findings (everything this lab found, fixed or not)

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | `usms-developer-role` trust `Principal AWS "*"` | HIGH | **Fixed**, Ex 2 (account root) |
| 2 | `usms-app-sg` SSH from **`0.0.0.0/0`**, not the `10.0.0.0/16` the lab expected | HIGH | **Fixed**, Step 16 (from `usms-bastion-sg` only) |
| 3 | `usms-app-sg` 80/443 from `0.0.0.0/0`: a second internet entry point | HIGH | Open: Exercise 4 argues for removing it |
| 4 | `usms-alb-sg` also admits 443 from `0.0.0.0/0` (no HTTPS listener exists) | MED | Open: remove until a 443 listener with ACM exists |
| 5 | Default allow-all egress on alb/enrolment/db SGs | MED | **Fixed**, Steps 13-15 |
| 6 | Default allow-all egress on `usms-app-sg` | MED | **Fixed**, Ex 1 |
| 7 | `usms-bastion-sg`, `usms-eks-cluster-sg`, `default` keep allow-all egress | MED | Open (bastion should be tcp/22 to `usms-app-sg` only, see exercises.md) |
| 8 | `USMSStudentDataReadWrite` grants `s3:DeleteObject`, and is on **three** roles incl. `usms-eks-node-role` | MED | Open: Lab 10 / IRSA (Lab 08 Ex 5) |
| 9 | Unconditioned service trust on ecs-task, ecs-exec, lambda-exec, eks-cluster | HIGH | **Fixed** (Step 7 and Ex 2) |
| 10 | Unconditioned `ec2.amazonaws.com` trust on ec2-app and eks-node roles; service-linked role | HIGH | **ACCEPTED** with reasons, `configs/lab-09-accepted-findings.tsv` |
| 11 | No role has a boundary except where this lab set one (and Floci does not store it) | MED | Recorded |
| 12 | `usms-enrolment-sg` is a single point of control | - | Stated, not fixed |
| 13 | Floci holds **three VPCs named `usms-vpc`** and two `usms-db-sg` groups | ops | Recorded: any tag-only lookup is ambiguous |

### Mistakes in the lab text, found by running it

1. **`` IpProtocol==`-1` `` never matches.** In JMESPath, backticks make a JSON literal, so `` `-1` `` is
   the **number** -1, and `IpProtocol` is the **string** `"-1"`. The PDF's allow-all count returned 0
   on a group that still had its default rule. Every count here uses `'-1'`: Step 18, `lab-09.env` and
   `verify-lab-09.sh`.
2. **Queries starting at `IpPermissionsEgress`** (without `SecurityGroups[0].`) error, because the
   response is `{"SecurityGroups":[...]}`. The PDF does this in Step 18, `lab-09.env` and three
   verify checks.
3. **`verify-lab-09.sh`'s boundary-attachment check** used `\\\"`, which survives `eval` as literal `"`
   characters inside `--query`. It failed with `AttachmentCount` really 0. I fixed the quoting.
4. **"No unexpanded variable" (`grep '\$'`)** flags Lab 01's
   `policies/usms-self-manage-credentials.json`, whose `${aws:username}` is a correct **IAM** policy
   variable. The check now looks for shell-style variables only.
5. **"No secret is tracked by git" (`! git ls-files | grep '^outputs/'`)** fails on `outputs/.gitkeep`,
   which the course tracks deliberately. That file is now allowed.
6. **Step 16's revoke-by-rule-ID filter** looks for `10.0.0.0/16`. On this build the SSH rule was
   `0.0.0.0/0`, so the PDF's command would have printed "already removed" and left SSH open to the
   internet. I removed whatever CIDR rule existed, then proved zero CIDR sources with
   `describe-security-groups`.
7. **Step 18's tag-only `usms-db-sg` lookup** picked the group in a **different** `usms-vpc`. The first
   persistence diff therefore said **PERSISTENCE FAILED** (figure 32a). The fix is to derive the VPC
   from `usms-web-01` and scope every group lookup to it. The second diff (figure 32b) is clean.
8. **`usms-sg-audit.sh` always exited 0** in the PDF's version. Mine preserves the Python exit code.
9. **`lab-09-cleanup.sh`** could never delete `usms-bastion-sg`, because Step 16's rule on
   `usms-app-sg` still references it. Mine revokes that rule first.

---

## Floci limitations hit, and what real AWS would have done

| What | Floci 2.1.0 | Real AWS |
|---|---|---|
| Permissions boundary | `--permissions-boundary` and `put-role-permissions-boundary` both succeed, but `get-role` has **no `PermissionsBoundary` key** | Stored and enforced as a ceiling on every call |
| Session policy (Step 9) | Credentials returned, session name `floci-session` instead of `lab09-scoped-review`, and `iam list-users` **answered** despite the session policy | Effective = identity ∩ session; `list-users` AccessDenied |
| Any IAM evaluation | None: any credentials do anything | Every call |
| `simulate-principal-policy` | Works, and agreed with my hand-computed intersection | Same |
| `get-account-authorization-details`, credential report, Access Analyzer | Not available | Available |
| `modify-instance-metadata-options` | Stored and read back; no metadata service exists | Enforced at the hypervisor on return |
| `describe-security-group-rules` | **Stale**: lists revoked rules. A revoke with a nonexistent rule ID still returns `True` | Accurate; a bogus ID is `InvalidSecurityGroupRuleId.NotFound` |
| Security groups and NACLs | Stored, never evaluated, no traffic | Every packet |
| Public addresses | Instances report `127.0.0.1`; ENIs carry no association; the NAT ENI is not listed by `describe-network-interfaces` | Real Elastic or auto-assigned IPv4 on the ENI |
| Restart | k3s comes back as a **new node**, leaving a ghost (NotReady) node; the new node lacks Lab 08's labels | N/A (managed node group relabels) |
| `MaxSessionDuration` | 900 rejected, minimum 3600 (matches AWS) | Same |

**Observed vs reasoned.**
- **Observed:** every document stored and returned as written, every rule change (from the authoritative
  view), the restart persistence of nine facts, the regression diff, the audit and report outputs, and
  the simulator's decisions.
- **Reasoned only:** any enforcement (IAM, boundary, session policy, MFA, ExternalId, SG and NACL
  packets), SSRF and the hop limit, prefix-list routing through the gateway endpoint, and every cost.

---

## Section 14 - Review Questions

**1. Why "NOTHING BROKE" is strong, what could have broken it, and what I would do.**
This lab changed the two things every earlier lab depends on, identity and network rules. The five
verification scripts assert 172 separate facts between them (6 + 36 + 39 + 49 + 42). Identical summary lines mean that
no property they assert moved, including ones I was not thinking about. That is a regression test
written by people who did not know this lab would exist.

A plausible break: if Step 16 had removed the SSH rule and **then** failed to add the bastion rule, no
script would notice, because none asserts SSH. But if Step 13 had revoked `usms-enrolment-sg`'s
**ingress** instead of egress, `verify-lab-05.sh` would have gone from 47 to 46.

I would read the failing check, decide whether my change or the check is wrong, and either restore the
rule (`policies/usms-egress-allow-all.json` exists for exactly that) or update the check with a
comment saying why, as Lab 08 did for the gateway replica count.

**2. A colleague attaches `USMSPermissionsBoundary` with `attach-role-policy`.**
As an ordinary policy it **grants** everything in it. The role gains `ecs:*`, `elasticloadbalancing:*`,
`application-autoscaling:*`, `logs:*`, `cloudwatch:*`, `s3:PutObject` on `*`, and more. That is far
more than `USMSDeployBase`.

At the same time it stops being a **ceiling**, so nothing caps whatever is attached later. Effective
permissions go **up** (broad grants) and the protection goes **away** (no ceiling).

It becomes dangerous the moment anyone attaches another policy, or the moment the role is used. It
already lets the deploy role write any S3 object and change any load balancer.

Section 8 catches it with **"the boundary is attached to NOTHING as an ordinary policy"**
(`AttachmentCount = 0`). I had to fix that check's quoting before it could catch anything. The
**"usms-deploy-role HAS a permissions boundary"** check would also keep failing, as it does on Floci.

**3. A breach with every ingress rule correct.**
A dependency of the enrolment service (a compromised npm or PyPI package) runs inside a legitimate
task. It needs no inbound connection at all. It reads the task role's credentials from the container
credentials endpoint, calls `s3:GetObject` on every transcript (the role is allowed), and sends them
out.

- **Steps 13-15 narrow it:** the task can only connect out on tcp/443, so it cannot use SSH, raw TCP
  C2, or DNS tunnelling to an arbitrary resolver.
- **But 443 to `0.0.0.0/0` remains**, so an HTTPS POST to an attacker's server still works. They
  removed perhaps half the techniques and none of the data.
- **Preventing it entirely** needs two things:
  - hostname-based egress (Network Firewall or a proxy allowing only `*.amazonaws.com` and named
    partners)
  - a bucket policy plus VPC endpoint policy that only allows the bucket's data to leave through the
    endpoint (`aws:SourceVpce`)

  Better still, a role that cannot read every transcript.
- **This course cannot build it:** Floci models neither Network Firewall nor packet flow, and the
  bucket does not exist yet.

**4. An attacker calling `sts:AssumeRole` from their own machine.**
- **`usms-ecs-task-role` and `usms-transcripts-reader-role`:** the principal is a **service**
  (`ecs-tasks.amazonaws.com`). An attacker's IAM user is not that service, so their AssumeRole is
  refused whatever conditions say. The conditions defend a different attack: the attacker's **own
  ECS account** asking ECS to assume our role on their behalf (the confused deputy). `aws:SourceAccount`
  and `aws:SourceArn` refuse that. The roles' different permissions don't matter here, because neither
  can be assumed.
- **`usms-deploy-role` trusts a user** (`usms-admin-01`). An attacker holding that user's keys **can**
  assume it. What they get is then limited twice: by `USMSDeployBase` (PassRole only for three named
  roles, only to ECS) and by the boundary (no identity changes, no network deletion).

So the answers differ because one trust names a service an outsider cannot impersonate, while the other
names a human whose credentials can be stolen. That is why Exercise 2's break-glass role adds MFA and
an ExternalId on top of naming the user.

**5. Why five controls on `usms-db-01` are not "five times better" than one on `usms-enrolment-sg`.**
Controls only multiply if they fail **independently**.
- Controls 1 and 2 (no public IP, no auto-assign) fail together if someone launches into the wrong
  subnet with `--associate-public-ip-address`.
- Controls 3 and 5 (route table and NACL) are both subnet-level and are often changed by the same
  Terraform module.
- So it is closer to three independent failure modes than five.

The enrolment tasks are **not** much less well protected in reality. They also sit in private subnets
with no public addresses (`assignPublicIp DISABLED`), behind a NAT, reached only via the ALB. The matrix
shows "one control" because it **models security groups only**. Exercise 3's exposure report, which
adds the route table and public address, would classify them ISOLATED, like the database. The single
rule is a single point of control **for the security-group layer**, not for the system.

**6. The two extra rotation steps.**
- **Step 3, move consumers to the new key before deactivating:** guards against an outage. The old
  key is still active while every consumer switches, so nothing loses access mid-rotation. The incident
  it prevents is the "we rotated and the nightly job failed" page.
- **Step 4, deactivate before deleting:** guards against the consumer nobody knew about.
  Deactivation is reversible, and `get-access-key-last-used` tells you whether anything still tries.
  Deletion is not reversible.

A long-lived key is a compromise because it is a bearer credential that works from anywhere, for ever,
until someone remembers it. Leaked keys in git history and laptop backups are the classic incident.

A real system would use IAM Identity Center (SSO) with MFA for humans: short-lived role sessions,
nothing on disk that outlives a day. For workloads it would use instance profiles, ECS task roles or
IRSA, which are short-lived credentials issued by the platform. There would be no access keys at all.

**7. Is review an adequate substitute for testing?**
Not alone, and here it had to be. Floci enforces nothing, so a refused call proved nothing.

- **Reading catches what testing does not.** `USMSStudentDataReadWrite` grants `s3:DeleteObject`.
  A test of "can the enrolment API read a transcript" passes whether or not delete is granted, and only
  reading shows the extra verb. The same goes for `Principal "*"`, which no positive test exercises.
- **Testing catches what reading does not:** a condition key the service never sends. My EKS cluster
  trust policy reads perfectly, but if EKS did not send `aws:SourceArn` the cluster would fail to
  create. Only a real `create-cluster` on real AWS proves it. The same goes for the IMDSv2 rollout:
  reading the policy cannot tell you which SDK still uses v1.

For student transcripts I would want **reading first**. The question that matters is "who can read or
change the academic record", which is a claim about what *cannot* happen, and only exhaustive reading
(or Access Analyzer, which also reads) can establish it. Then I would want a targeted test on real AWS
that the read-only role gets AccessDenied on `PutObject`.

---

## Exercises (summary; full write-up in `labs/lab-09-security/exercises.md`)

| Exercise | Result |
|---|---|
| Ex 1 | `usms-app-sg` egress written (S3 prefix list, AWS HTTPS, ALB, DB, DNS UDP+TCP to 10.0.0.2); no allow-all left; ingress fingerprint unchanged |
| Ex 2 | `usms-breakglass-role` (admin-01 + MFA AND ExternalId, 3600 s, boundary, two actions). Four trusts fixed, three accepted from a committed TSV; audit `HIGH=0 ACCEPTED=3` exit 0, and exit 1 when reasons are removed |
| Ex 3 | `usms-exposure-report.sh`: EXPOSED=3 (web-01, web-02, NAT) ISOLATED=2 (db-01, db-02); identical from `~` and from the lab folder |
| Ex 4 | The ISO review, the transcripts access list, and the unexecuted cut-over plan |
| Ex 5 | Bucket policy draft (6 statements, 4 role principals, bucket name derived); readiness file; `lab-09.env` now has **17** exports |
