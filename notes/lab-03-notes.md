# Lab 03: EC2 - Notes, Findings and Review Answers

## The connecting idea (Step 11)

`USMSStudentDataReadWrite` grants access to `arn:aws:s3:::usms-student-data`, a bucket that does not
exist yet. An IAM policy is a statement about ARNs, not a reference to objects, so the permission is
valid now and simply has no effect until Lab 04 creates the bucket. At that moment `usms-web-01`
can write transcripts with no access key anywhere on the machine.

## Choices recorded

- **AMI (Step 3):** neither Option A nor B was needed. This Floci build answers the SSM public
  parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` with
  `ami-0abcdef1234567891` (AL2023), so the AMI was resolved the way real AWS should do it.
  I did not use `Images[0]`, because that returns the Amazon Linux 2 image, and the user-data script uses `dnf`.
- **`.gitignore`:** the repository had none, despite Lab 01 saying it was the first commit. One was
  added before the key existed; `git check-ignore -v` names `.gitignore:6:outputs/*`.
  The Lab 02 files already committed under `outputs/` stay tracked, because ignore rules do not untrack them.

## Lab 02 repair (done before Lab 03 could be trusted)

Three VPCs named `usms-vpc` existed from repeated Lab 02 attempts, and `configs/lab-02.env` mixed
them: subnets in `vpc-384d1580`, security groups in `vpc-fab9912c`, IGW/NAT/route tables/NACL in
`vpc-e7850d3a`. No subnet had `MapPublicIpOnLaunch=True`, `usms-app-sg` had no port 80, and
`usms-public-subnet-a` was associated with a route table in another VPC. Floci accepted all of it,
including a `run-instances` with a subnet and security group from different VPCs, which real AWS
rejects. `verify-lab-02.sh` passed throughout because it never checks *which* VPC each ID is in.

`scripts/utilities/repair-lab-02-network.sh` made `vpc-384d1580` complete (IGW, public RT, NAT,
private RT + NACL, S3 endpoint, both SGs, auto-assign public IP) and regenerated
`configs/lab-02.env`. Before the repair, Step 14 checks 2 and 4 would have failed. Lesson: a
verification script that checks existence but not relationships is not evidence of a network.

## Floci vs real AWS - what this build actually did

This Floci build boots each instance as a Docker container (`amazonlinux:2023`), so several
"Floci cannot" statements in the lab text are wrong *for this build*. Observed, not reasoned:

| Lab expected | Observed here | Real AWS |
|---|---|---|
| user data stored, not executed | **executed**: nginx installed, `index.html`/`health.json` written; only `systemctl` failed (no systemd in the container) | runs once as root via cloud-init |
| IMDS not served | **served**: a `socat` proxy on `169.254.169.254:80`; the page shows the real instance ID and AZ | IMDSv1/v2 |
| user data returned byte-identical (Step 12) | **not returned**: `describe-instance-attribute userData` has no `<userData>` element, so Step 12's `diff` cannot pass | returned base64 |
| `verify-lab-03` "user data stored" check | passes as a **false positive**: `--output text` prints the string `None`, which `test -n` accepts | - |
| `curl` to the public IP times out | times out, but for a specific reason: nginx cannot bind `0.0.0.0:80` because the IMDS `socat` already holds `169.254.169.254:80` | page served |
| SSH impossible | **works** as `root` on host port 2200 with `outputs/usms-app-key.pem` | `ec2-user` on port 22 |
| private IP in `10.0.1.0/24` | `10.240.x.x` (Floci's Docker network), and it **changed** to `172.18.0.3` after stop/start | from the subnet CIDR; never changes |
| auto-assigned public IP | `127.0.0.1` once the container is up, and the EIP also reports `127.0.0.1` | routable address |
| public IP released on stop | **not released** (`127.0.0.1` while stopped) | always released |
| AZ mismatch on attach | **enforced**, as `InvalidParameterValue` | `InvalidVolume.ZoneMismatch` |
| root volume tags from `run-instances` | ignored; `create-tags` writes to `describe-tags` but `describe-volumes`/`describe-images` don't show them, and filters on `describe-volumes` miss them | tags shown everywhere |
| `instance-running` waiter | 30 s for the first launch (container pull), < 1 s after | 30-60 s |

Root-volume tags disappeared after the Step 19 restart; the explicitly created data volume kept
them. Persistence of instances, subnets, SGs, volumes and EIPs was otherwise proven.

---

## Review Questions

### 1. What if each Step 8 input had been wrong?

- **Subnet (Lab 2):** missing or nonexistent → immediate `InvalidSubnetID.NotFound`. *Wrong but
  valid* (e.g. a private subnet) → **silent**: the launch succeeds, and the instance just has no public
  address and no route to the IGW. This lab showed a worse silent case: a subnet from a different VPC
  than its security group, which Floci accepted and real AWS would have rejected immediately.
- **Security group (Lab 2):** missing → immediate `InvalidGroup.NotFound`. Wrong rules (no port 80,
  as `usms-app-sg` actually had) → **silent**: the instance runs and nobody can reach it.
- **Instance profile (Lab 1):** missing → immediate `InvalidParameterValue: iamInstanceProfile.name`.
  A profile whose role lacks the right policy → **silent until Lab 4**, when S3 calls return
  AccessDenied.
- **Key pair (Lab 3):** missing → immediate `InvalidKeyPair.NotFound`. Losing the `.pem`
  afterwards → silent until someone needs SSH and cannot get in.
- **User-data script (Lab 3):** a syntax error or unquoted heredoc → **completely silent**:
  `run-instances` succeeds, and the failure only appears in a log on a machine you may not be able to
  reach. That is why `bash -n` and Step 12 exist.

Pattern: *existence* errors are immediate; *correctness* errors are silent.

### 2. A policy for a bucket that does not exist

This is valid, not broken, because an IAM policy is a set of statements about ARNs:
"this principal may do these actions on resources matching this string". IAM never checks that the
resource exists when the policy is created or attached, so `arn:aws:s3:::usms-student-data` is just a
name that does not match anything yet. For `usms-web-01` today, this means the full chain
(instance → `usms-ec2-app-profile` → `usms-ec2-app-role` → `USMSStudentDataReadWrite`) is in place
and the instance would receive credentials. Any S3 call it made would fail, though, because the bucket
is not there: `head-bucket` returned **404 Not Found** (`outputs/lab-03-s3-readiness.txt`). That is
a 404, not a 403: permission is present, and the object is absent. When Lab 4 runs `create-bucket
usms-student-data`, nothing in IAM changes at all. A resource appears at an ARN the policy already
names, and from that moment `GetObject`, `PutObject` and `ListBucket` succeed for the instance with no
access key on disk. Deleting and recreating the bucket would also be covered without touching IAM, and
the explicit `Deny s3:DeleteBucket` protects it from the instance itself.

### 3. "Restarting the instance redeploys it"

That does not work, because cloud-init runs user-data scripts once per instance, on first boot.
It records completion under `/var/lib/cloud/instance/`, and a reboot or a stop/start finds that
record and skips the script. Restarting leaves the old version running. (Forcing `scripts-user` to
run on every boot is possible, but it makes every reboot a deployment, which is slow, unreviewable and
fails differently on each machine.) Two approaches that do work:
(a) **Immutable replacement:** bake each release into a new AMI or a launch-template version, then
roll the Auto Scaling group (instance refresh) so new instances replace the old ones. The user data
stays the same, but each instance is new, so it runs once on each.
(b) **A deployment tool that acts on running instances:** AWS CodeDeploy, or SSM Run Command /
State Manager, pushing a versioned artefact (e.g. from S3) to instances selected by tag, with health
checks and rollback. Containers (Lab 04's ECS) are a third route: you deploy a new task definition
revision.

### 4. Auto-assigned public IP vs Elastic IP

| | Auto-assigned (Step 10) | Elastic IP (Step 13) |
|---|---|---|
| Who owns it | AWS's pool; lent to the instance | Your account, until you release it |
| When it changes | Every stop/start; gone at termination | Never, until you release it |
| Cost | USD 0.005/h while assigned (all public IPv4 since Feb 2024) | USD 0.005/h always, **including while unassociated** |
| On instance stop | Released, so the stopped instance has no public IP | Stays allocated and associated; back in place on start |

On this Floci build both showed `127.0.0.1` and the address was not released while stopped, so the
"on stop" row is reasoned, not observed.

**Failover only possible because of the difference:** DNS for the portal points at the Elastic IP.
If `usms-web-01` fails, launch or start `usms-web-02` (from `usms-web-golden`), then run
`aws ec2 associate-address --allocation-id <usms-web-eip> --instance-id <web-02> --allow-reassociation`.
The address moves in seconds and DNS is never touched, so no TTL wait applies. An auto-assigned
address cannot be moved to another instance at all.

### 5. Volumes are AZ-bound; snapshots are regional

An EBS **volume** lives in one AZ's storage fabric, physically close to the hosts it serves, which is
why attach is refused across AZs (observed in Step 15: Floci rejected the `us-east-1b` volume). A
**snapshot** is stored in S3-backed, regional storage replicated across the region's AZs, which is
why it can be restored into any AZ. Design implication: losing one AZ loses every volume in it, so
anything that must survive needs data that already exists outside that AZ. That means regular
(automated) snapshots, or better, a service that replicates synchronously across AZs (RDS Multi-AZ,
which Lab 06 moves to, or EFS/S3). Compute must also be able to start in the other AZ (Auto
Scaling across both subnets, from an AMI that is itself regional). RPO is then the snapshot interval
or zero for synchronous replication, and RTO is the time to restore and launch.

### 6. Is the six-link check an adequate substitute?

It is adequate for what it claims, the **AWS-side configuration**, and it is the right first
diagnostic: those six links are where most real "can't reach my instance" problems sit. In this lab
it found two genuine faults (an IGW in another VPC and no port-80 rule) that a passing `curl`
would never have explained. But it is not a substitute for a request: it checks *configuration
that would permit* traffic, not *traffic*. The class of fault it cannot detect is everything
**inside the instance and the application**: no process listening, a service that crashed or never
started, a host firewall, the app bound to `127.0.0.1`, wrong content. This build demonstrated one
exactly: user data installed nginx, `systemctl` failed, and nginx could not bind port 80, so all six
links passed while nothing answered. Only an end-to-end check (a health check, `curl /health.json`)
catches that.

### 7. Every difference between `usms-web-01` and `usms-db-01`

| Difference | web-01 | db-01 | Property of |
|---|---|---|---|
| Subnet | `usms-public-subnet-a` | `usms-private-subnet-a` | instance (chosen at launch) |
| Private IP range | `10.0.1.0/24` | `10.0.3.0/24` | subnet |
| Public IP at launch | yes | none | subnet (`MapPublicIpOnLaunch`) |
| Elastic IP | `usms-web-eip` | none | instance (association) |
| Route to internet | `0.0.0.0/0 → usms-igw` (in and out) | `0.0.0.0/0 → usms-nat` (out only) | subnet (its route table) |
| Network ACL | VPC default (allow all) | `usms-private-nacl` | subnet |
| Security group | `usms-app-sg` (80/443/22 from anywhere) | `usms-db-sg` (5432 from `usms-app-sg` only) | instance (its ENI) |
| Instance profile | `usms-ec2-app-profile` | none | instance |
| User data | nginx bootstrap | none | instance |
| Data volume | `usms-web-data-vol` attached | none | instance |
| AZ | us-east-1a | us-east-1a (same) | subnet |
| Tags (`Name`, `Tier`) | `web` | `data` | instance |

Shared, and properties of the **VPC**: the `10.0.0.0/16` space and `local` route that lets them
talk at all, DNS support/hostnames, the IGW and NAT that exist for both subnets to use, and the S3
gateway endpoint on the private route table. The same AMI, instance type and key pair are instance
properties that happen to be equal.

The key distinction: whether an instance is "public" is not a property of the instance. It comes from
the subnet's route table, plus a public address. The security group decides *who* may connect;
the route table decides whether a path exists at all.
