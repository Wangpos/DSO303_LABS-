# Lab 12 - Notes

**Support path: A** (`outputs/lab-12-deploy-probe.txt`: Docker, ECR, ECS answer; CodeDeploy answers too).
In practice two links behave like Path B:
- the CodePipeline ECS deploy provider doesn't exist on Floci 2.1.0;
- the pipeline → CodeBuild source handoff is still missing (Lab 11).

The deploy action's four steps were performed by `scripts/utilities/usms-ecs-deploy-action.sh`.
Report: `labs/lab-12-cicd-deploy/README.md`. Exercises: `labs/lab-12-cicd-deploy/exercises.md`.

---

## Step 12 - Your turn: my pipeline policy against the lab's (Step 15)

My draft is `notes/lab-12-my-pipeline-policy.json`, written before reading Step 15. **Four of its five
statements match the lab's v2:**
- the artifact store;
- start/watch the one build project;
- PassRole of the build role, only to CodeBuild;
- PassRole of exactly the two ECS roles, only to `ecs-tasks.amazonaws.com`.

**One differs, the ECS statement:**

- **Mine** put all four ECS calls in one statement, on two resources: the service ARN and
  `task-definition/usms-enrolment:*`. That scopes Register to the family.
- **The lab's** splits it into two statements. `DescribeServices`/`UpdateService` go on the service
  ARN, and `DescribeTaskDefinition`, `RegisterTaskDefinition`, **`ListTaskDefinitions`** go on `*`,
  because Register "creates a resource that has no ARN yet".

**Who is right:**
- **I missed `ListTaskDefinitions`.** The deploy action doesn't need it, but the lab's watcher and
  lookups do.
- **The lab's `*` is wider than it needs to be.** The Service Authorization Reference lists
  `task-definition` as Register's resource type, so the family pattern is a valid resource for the
  revision being created.
- **Describe/List genuinely have no resource type**, so `*` is right for those.

Exercise 4's v3 is effectively my draft, corrected: Register on the family, Describe/List on `*`, plus
an `ecs:task-definition` condition on UpdateService that neither draft had.

## Step 16 - Your turn: Deploy reading `SourceOutput` instead of `BuildOutput`

`SourceOutput` is the source zip as uploaded: `VERSION`, `buildspec.yml`, `Dockerfile`, `config/`,
`src/`, `tests/`. It has **no `imagedefinitions.json`**, because that file is written by the build,
into `dist/`, which becomes the root of `BuildOutput` through `base-directory: dist`.

- **The Source and Build stages would both succeed.** Build would even push an image, because Build
  still consumes `SourceOutput` correctly.
- **The Deploy stage would fail**, with the ECS action reporting that it can't find
  `imagedefinitions.json` in its input artifact.
- **The service wouldn't change**, so a correctly pushed image would never be deployed. The pipeline
  document alone shows it: the Input column would read `SourceOutput` for Deploy, and the only action
  that writes `imagedefinitions.json` has `BuildOutput` as its output.

## Step 18 - Your turn: what to do with `usms-enrolment:5`

**Decision: deregistered** (`deregister-task-definition`, README figure 33). It is INACTIVE and still
describable.

**Why:**
- Revision 5 names `…/usms-enrolment:r8`, an image that was never pushed. As long as it is ACTIVE, it
  reads as a valid, deployable revision, and it is the **highest** one. "Latest revision of the
  family" means revision 5 to anyone who looks:
  - `describe-task-definition --task-definition usms-enrolment` returns it;
  - an audit script counting ACTIVE revisions includes it;
  - a scale-out or a careless `update-service --task-definition usms-enrolment` would deploy it again.
- **Deregistering is the only lever there is.** It's append-only, with no undo and no delete. It
  stops new deployments of revision 5 while keeping the record: the rollback drill really happened,
  and its evidence (`lab-12-deploy-evidence.txt`, the STOPPED tasks' reasons) refers to `:5`.

**Floci caveat:** its family lookup **still returns INACTIVE revision 5**. Real AWS returns the latest
ACTIVE revision, 4. So `configs/lab-12.env` derives the CI/CD revision from the ACTIVE list, sorted
numerically.

**How someone would notice later:**
- `list-task-definitions --status INACTIVE` shows `:5`.
- Comparing each revision's image against `describe-images` shows `r8` has no image. An audit should
  check exactly that: every revision ever deployed should name an image that exists, by digest.

## privilegedMode - what it grants

`privilegedMode: true` runs the build container with Docker's `--privileged`. That means all Linux
capabilities, access to the host's devices, and no seccomp/AppArmor confinement, so a Docker daemon
can run **inside** the build (Docker-in-Docker) and `docker build`/`push` work.

**The cost is that the build is no longer a sandbox.** Code in the buildspec, or anything the build
downloads, could load kernel modules, mount host devices, or try to break out to the build host.

**So control who can change the buildspec:**
- it comes from the source zip;
- anyone who can write `source/usms-enrolment-src.zip` can run privileged code;
- enable it only on projects that need it (only `usms-enrolment-build` here, not the results
  project).

The cleanup script turns it back off.

---

## Section 14 - Review Questions

### 1. Changes that cannot travel through this pipeline

The ECS deploy action rewrites one thing, **the image of each named container**, and copies the rest of
the current task definition. Three realistic changes therefore cannot travel through it:

1. **Resources: CPU or memory.** Example: the enrolment container needs 512/2048 for the start-of-term
   peak. Ship it as a new revision, derived by describe → strip → change `cpu`/`memory` → register,
   then `update-service`. Both commands live in a reviewed script or in an infrastructure template
   (the CloudFormation lab). The next pipeline run then copies the new values forward, because the
   action derives from the service's *current* revision.
2. **Configuration and secrets.** Examples: a new environment variable (`DB_POOL_SIZE`), a secret
   reference, a health check, a log setting. Same route: a deliberate revision registered outside the
   pipeline, or the values moved out of the task definition into Parameter Store/Secrets Manager, which
   the container reads at start. That way they change without a revision.
3. **A second container or a role change.** Examples: adding a sidecar (a log router, a proxy), or
   pointing the task at a narrower task role (Exercise 4's recommendation). The action replaces images
   only for containers that exist, so it can't add one, and it never touches roles. That's
   infrastructure: a template change, reviewed, and deployed by an identity allowed to pass the new
   role. The pipeline role should **not** be that identity.

What these have in common: they change what the service *is*, not which build it runs. Keeping them
out of the pipeline is a feature, as long as they have their own reviewed path. Otherwise someone
makes them by hand in the console and the next pipeline run copies them forward with no record.

### 2. `GetAuthorizationToken` and `RegisterTaskDefinition` on `"*"` - the same kind of exception?

**They are the same:** in both cases the policy author has no ARN to name at call time.
- `GetAuthorizationToken` has no resource type at all. The token is registry-wide, so `*` is the only
  value AWS accepts.
- `RegisterTaskDefinition` creates a revision that doesn't exist yet. The lab's v2 used `*` for the
  same reason.

Both are "the API gives you nothing narrower", not a lazy grant.

**They are different:**
- **The token is harmless on its own.** It authenticates; it authorises nothing. Every push or pull
  is still checked against `ecr:PutImage`/`BatchGetImage` on the specific repository ARN, so the `*`
  is fully bounded by the statements around it.
- **Register on `*` is not bounded.** It *is* the dangerous act: a new revision in any family, with
  any image, passable roles and the rest. The reference does list `task-definition` as its resource
  type, so `task-definition/usms-enrolment:*` works (Exercise 4, v3).

**My answer: not the same kind.** `GetAuthorizationToken` is a true exception: nothing narrower
exists, and nothing is lost. Register only *looks* like one. It can be scoped to the family, and should
be, and its remaining gap (no condition key on image or role) has to be closed by controls around it:
image provenance, a narrow task role and a separate deploy identity. Leaving it at `*` is a choice,
not a necessity.

### 3. Digest vs tag

**To a sceptical colleague:** a tag is a pointer that anyone with `PutImage` can move, and nothing
records that it moved. This lab moved one twice:
- **by accident:** a local test re-pushed `r6` and it changed bytes;
- **on purpose:** Exercise 5 pointed `r7` at different bytes for twelve seconds, and every record
  (revision 4, the service, the deploy evidence) read exactly the same before and after.

**A digest is the content's hash.** If the bytes change, the name changes. A task definition that
names a digest:
- runs the same bytes on every task, including ones started at 3 a.m. by autoscaling;
- rolls back to exactly what ran before;
- *is* audit evidence.

The inconvenience is a long string that a build script writes for you.

**The strongest case against pinning digests:** a digest also pins you to **old bytes forever**.
When `nginx:1.27-alpine` gets a security fix, a moving tag would pick it up on the next task start.
A pinned digest never will. Every base-image patch needs a rebuild, a new digest, a new revision and a
deploy, for every service. A team that doesn't run that loop reliably ends up with pinned, provably
identical, **unpatched** images, the exact property you wanted turned into a liability.

**The answer is to pin digests and automate the rebuild** (scheduled builds, scan-on-push, alerts on
base-image updates), not to let tags float.

### 4. A failure the circuit breaker would not catch

The circuit breaker watches whether **tasks reach RUNNING and stay healthy** (and, with a load
balancer, pass health checks) during a deployment. It can't catch a release that **starts, stays up,
passes `/` health checks, and is wrong**. Examples:
- an enrolment page that loads but submits to the wrong API path;
- a release that returns 200 with an error message in the body;
- a config change that sends writes to the wrong table;
- a 30% rise in latency.

Each one deploys "successfully", and the breaker declares victory.

**What catches it:**
- **application-level signals** tied to the deployment: CloudWatch alarms on 5xx rate, latency and
  business metrics (enrolments per minute), wired to the deployment so an alarm triggers rollback.
  With CodeDeploy blue/green that's `DEPLOYMENT_STOP_ON_ALARM` in the Step 19 deployment group;
- **a staged rollout** (linear 10% a minute) so the alarm fires while most traffic is still on blue;
- **a test listener** (Exercise 3's :8080) where post-deploy tests run against green before any
  production traffic shifts.

This lab's Floci run is an extreme version: even the failure the breaker *should* catch (an image that
doesn't exist) was reported as COMPLETED. Only reading the tasks' stop reasons showed the truth.

### 5. Replace-only APIs

**What they have in common:** each one sets **a single document that is evaluated as a whole**:
- a pipeline definition;
- a bucket's notification configuration;
- a role's trust policy;
- a bucket policy.

The meaning of each element depends on the others: stage order, artifact names that must chain,
overlapping prefix filters, an Allow that a Deny elsewhere overrides. The service validates the whole
thing and stores it atomically with a version. Replacement makes the stored state exactly what the
caller sent, so what you reviewed is what runs, and there is no "the result of merging my change with
whatever was there" to reason about.

**What a merge-based `update-pipeline` would have to decide**, and a replace-based one doesn't:

- **Identity:** how to match my stage to yours, by name or position? What happens if a name changed,
  or I rename a stage?
- **Deletion:** is an omitted stage or action deleted or kept? It needs a way to express "remove".
- **Order:** where does a new stage go, and what if two merges insert at the same place?
- **Depth:** are nested lists (actions, input artifacts, configuration maps) merged or replaced?
  Merging `inputArtifacts` element-wise could leave Deploy reading both `SourceOutput` and
  `BuildOutput`.
- **Validity:** is the *merged* result validated, and if it's invalid, whose change is rejected?
- **Concurrency:** what if the document changed since I read it? Replace makes that a lost update
  you avoid with get → modify → put and the `version` field. Merge hides it.

Replace pushes all of that to the client, which is why this lab's surgery script asserts the
current stages before it puts, and refuses to add a second Deploy.

### 6. Why `create-policy-version` doesn't set the default automatically

Because creating and activating are **two decisions that should be separable**. A new version is
evaluated for every principal attached to the policy the instant it becomes default. That's
production for everyone who uses it, with no staged rollout.

**The workflow the design protects:**
1. Create v3 alongside v2 (still default).
2. **Review** the stored document: the diff between versions, `get-policy-version`.
3. **Test** it: `simulate-principal-policy`/`simulate-custom-policy` against the actions the pipeline
   actually makes (Exercise 4 did this), Access Analyzer validation, perhaps a test principal.
4. Only then `set-default-policy-version v3`. It's one atomic switch, and **rollback is the same
   command with `v2`**. The old version is still there, unchanged (up to five versions).

If creation also activated, a typo would be live before anyone read it, and a rollback would mean
re-creating the old document from memory. This lab used the gap twice: each version was read back
before being made default. And Exercise 4 left v2 in place, so the one-line restore in the README
works.

### 7. "The service is running code that was never reviewed"

**What does not settle it:**
- **The pipeline execution history.** It shows which S3 *source version* each execution consumed and
  whether stages passed. It doesn't say which execution, if any, produced what is running now. On this
  emulator, every execution failed at Build, yet the service runs r7. Anything that calls
  `update-service` or `PutImage` directly bypasses it entirely.
- **`outputs/lab-12-deploy-evidence.txt` on its own.** It shows the service moved from revision 3 to
  revision 4, which names **`…:r7`**, a tag. Exercise 5 showed a tag can point at other bytes without
  changing a line of that file.

**What helps: `outputs/lab-12-image-digest.txt`, together with the runtime.** The ledger maps `r7` to
`c3c1150a…` at push time and records every later move of the tag (including the deliberate retag and
the restore). Comparing it with the running containers' `RepoDigests` shows whether the running bytes
are the ones pushed as r7. But it still links the bytes only to *a push*, not to *a reviewed commit*.
The ledger is written by whoever pushed, from wherever they pushed, and it's a local file anyone
can edit.

**What I would have needed to record at build time:** a binding of **digest → source commit → review**,
made by the build and stored where the build can't rewrite it later. For example:
- `build-metadata.json` (already in the image) gains the git commit SHA and the PR/approval ID;
- the build writes `imageUri` **by digest** into `imagedefinitions.json`;
- the build attaches a signed attestation (provenance) to the image digest in the registry.

Then one command settles it. Take the digest the running tasks report, then read that digest's
attestation, or `docker run --rm <digest> cat /usr/share/nginx/html/build-metadata.json`, and you get
the commit and its review, or you find none.

---

## Floci 2.1.0 limitations met in this lab

| Finding | Effect on the lab | Real AWS |
|---|---|---|
| ECR registry runs as a sidecar on 127.0.0.1:5100; publishing 5100-5104 on Floci fails to start | Step 4 doesn't apply; reverted; KEEP's "port range, published" isn't applicable on this build | n/a |
| CodePipeline ECS deploy provider absent | Deploy stage can't run; a stand-in performed its four steps | Native action |
| Pipeline → CodeBuild handoff missing; CodeBuild has no Docker | Images built and pushed by the same buildspec run locally | Build runs in privileged CodeBuild |
| Unpullable image → tasks STOPPED, deployment **COMPLETED**, no events, no circuit breaker | The rollback drill had to be diagnosed from task stop reasons | Breaker trips, automatic rollback |
| Family lookup returns INACTIVE revision; `--sort DESC` ignored | `lab-12.env` revision derived from the ACTIVE list; verify reads `:5` | Latest ACTIVE; sort honoured |
| `simulate-custom-policy` unsupported (`simulate-principal-policy` works); no IAM enforcement | Exercise 4 is evaluated, not enforced | Both simulators; enforced |
| Untagged images vanish from `describe-images` | Old digests are traceable only through the ledger | Listed as untagged |
| CodeDeploy answers but nothing executed | Blue/green specified (Step 19, Ex 3), not performed | Full blue/green |
| Tag immutability **enforced**; tasks **really run** in Docker | Exercise 2 and the "what really runs" proofs are real | Same |
