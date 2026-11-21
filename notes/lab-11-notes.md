Support path: A (probe, 2026-11-22). The pipeline → CodeBuild handoff behaves as Path B; see below.

# Lab 11 Notes - CI/CD Pipeline

Floci 2.1.0. CodeBuild, CodePipeline, ECR, CodeDeploy and EventBridge all answer the probe. IAM is
stored, never evaluated.

---

## What I observed versus what I only recorded (Section 11)

**Observed:**
- versioning, by two versions at one key, then deleted;
- the source zip's root layout;
- CodeBuild running the real buildspec standalone (build 8: release r3, buildId `usms-enrolment-build:8`);
- the smoke tests passing, and failing on purpose (locally, and in Floci CodeBuild in Exercise 2);
- the pipeline's **Source** action consuming the exact S3 version I uploaded, every time;
- a `pre_build` failure naming the command (local runner);
- `imagedefinitions.json` at the root of a real CodeBuild artifact.

**Recorded, not observed:**
- the build role's scoping, the explicit Deny, the scoped `iam:PassRole` and the single project ARN
  (Floci authorises everything);
- `start-build` refused on a CODEPIPELINE project (Floci accepted it);
- the pipeline's **Build** action building my source (Floci never hands it SourceOutput);
- `finally` running inside CodeBuild;
- the EventBridge trigger starting the pipeline.

**Not available:** the automatic first execution on create, build reports, approvals, KMS, real
timings and cost.

## Floci problems found by running the lab (all in README §5.5 and §8)

1. **The image pull is denied.** `aws/codebuild/standard:7.0` isn't on Docker Hub, so build 1 FAULTs.
   - Workaround: a local stand-in, `python:3.12-slim`, tagged with that name.
   - The project keeps the lab's image name.
   - `docker rmi aws/codebuild/standard:7.0` undoes it, and the cleanup script now does that.
2. **`source.buildspec` is read as inline YAML.** `"buildspec.yml"` runs **nothing**, and every phase
   still reports SUCCEEDED in 0 s.
   - Found with `docker events`: Floci copies the source in and never execs a command.
   - Fix: omit the field. It means the same on real AWS.
3. **The pipeline passes no source to CodeBuild.** The Build action fails at DOWNLOAD_SOURCE ("No
   buildspec found in source or request").
   - With the buildspec inline, it fails in `pre_build` instead: "VERSION file is missing".
   - Our own check caught the empty source.
4. **Smaller gaps:**
   - artifacts land at the bucket root as `<project>-<n>.zip`;
   - logs are empty;
   - `CODEBUILD_RESOLVED_SOURCE_VERSION` is unset;
   - the `--source-*-override` flags are ignored;
   - no execution starts on create;
   - `finally` is accepted but not run;
   - an EventBridge target's `RoleArn` isn't stored, and no event is delivered.
5. **The Docker `unhealthy` flag is benign:** the healthcheck runs `curl`, which the image doesn't
   contain.

## Answers asked for inside the steps

**Step 8 "Your turn" (port check).** A second `- |` block in `pre_build`. It has to be a literal block
because the pattern `'"port": 80,'` contains ": ", which YAML would otherwise parse as a mapping. The
message is: *PORT CHECK FAILED: config/service.json must say "port": 80 - the ALB target group and
the task definition both send traffic to port 80. Fix the port in config/service.json, then re-upload
the source.* Proved with port 8080 (figure 23).

**The nested-heredoc rule.** A quoted heredoc writes the **text**; an unquoted heredoc writes the
**result**.
- `<< 'BUILDSPEC'` is quoted, so `$USMS_RELEASE`, `$ARTIFACT_DIR` and `${CODEBUILD_BUILD_ID:-local}`
  reach the file literally, for the *build* to expand.
- The inner `<< META` is unquoted, because expansion is wanted *at build time*.
- `<< EOF` in Step 21 is unquoted, because the file must hold values computed *now*.

**The explicit Deny, in one sentence.** It states, in a form no later Allow can override, that a build
must never read or write student records. A compromised dependency in the build container therefore
can't exfiltrate transcripts, even if someone later attaches a broad S3 policy to the build role.

**Step 15: what if `iam:PassRole` had `Resource "*"` but kept `iam:PassedToService =
codebuild.amazonaws.com`?** The service condition limits *which service* receives the role, not
*which role*. So anyone holding this policy, or anything acting as the pipeline, could create or
update a CodeBuild project naming **any role in the account** that trusts `codebuild.amazonaws.com`.
- **The role an attacker would name:** the most powerful one CodeBuild can assume. Here that's any
  build role that also carries the ECR push permissions Lab 12 adds, or, worse, an
  administrator-like deploy role created for "convenience" with a CodeBuild trust.
- **What it buys them:** their buildspec then runs as that role. Privilege escalation by
  configuration, with no new credentials.
- **The fix:** keep the Resource as the one ARN (`usms-codebuild-role`), as `USMSCodePipelineBase`
  does, and as Lab 09's `USMSDeployBase` does with its three ARNs.

**Step 19 "Your turn" (r5).** Read from command output (figure 32):
- **3** versions of `source/usms-enrolment-src.zip` at that moment (r3, r4, r5),
- **0** objects under `usms-enrolment-pipeline/BuildOutput/`.

The numbers measure different things. A source version is written by *me*, one per upload. A
BuildOutput object is written by the pipeline, one per execution whose **Build action succeeds**.
- **Why they're unequal here:** every execution failed at Build, so 3 against 0.
- **Why they'd differ on real AWS too:**
  - the automatic execution at creation produces an output without a new upload;
  - an upload I never run produces a version without an output;
  - a re-run of the same version produces two outputs from one version;
  - a superseded execution produces none.

**Exercise 3: what `aws:SourceArn` closes that `aws:SourceAccount` alone doesn't.**
`aws:SourceAccount = 000000000000` only proves the *calling project* lives in this account. So any
CodeBuild project in the account, including one created by a developer, a test, or an attacker who has
`codebuild:CreateProject` and `iam:PassRole` on this role, can make CodeBuild assume
`usms-codebuild-role` and use its write access to the artifact bucket. That's enough to plant a
poisoned `BuildOutput` that Lab 12 would deploy.

`aws:SourceArn` pins the assumption to the named projects (`usms-enrolment-build`,
`usms-results-build`), so the confused deputy can only be confused on behalf of those two.

---

## Section 14 - Review Questions

### 1. Source and Build succeed, the deployed application is unchanged

**Explanation one: `artifacts.base-directory`.** The build wrote the new files to one place, while
`artifacts` collected another. Say `base-directory: dist` is right but the build copied into `build/`,
or the directory is right but `files` matches nothing new. The artifact is then empty or stale. The
Build action still succeeds, because "no files matched" isn't a build failure, and the deploy ships
whatever the artifact holds.

**Distinguish with one command:** list the newest BuildOutput zip's contents (`unzip -l`, or the
Python read-back from Step 19). Missing files, files under a `dist/` prefix, or an old `builtAt` in
`build-metadata.json` all point here.

**Explanation two: the source zip's internal layout.** The source was zipped with a top-level `app/`
directory, and some build steps ran from the wrong root. One possibility: a project-level buildspec
was used (so the source's `buildspec.yml` was never consulted), the build packaged a stale copy, and
the new `VERSION` sat unread at `app/VERSION`. The pipeline fetched a new *version* of the zip, but
the build never read the new *bytes*.

**Distinguish with one command:** `unzip -l outputs/usms-enrolment-src.zip`. If every path starts
with `app/`, it's this.

The two separate cleanly: the first shows a correct source zip and a wrong artifact, the second a
wrong source zip.

### 2. Why CodePipeline requires versioning on an S3 source

An execution must record **exactly which input it ran on**, so that every later stage, retry and
audit refers to the same bytes. With versioning, the Source action records the object's version ID
(figure 31: the Source action's external ID *is* the uploaded version). That ID is immutable: a later
upload to the same key creates a new version and can't change what this execution consumed.

Without versioning there's only "whatever is at the key now". An execution that runs for minutes
could have its input replaced under it. A Build retry might fetch different bytes from the ones Source
saw. And the execution history couldn't say what it built. Rollback is a side effect; the requirement
is about an execution being a well-defined function of a specific input.

### 3. `iam:PassRole` for someone who thinks it's redundant

The objection is reasonable: if you may create the project, why ask again about its role? The answer
is that **creating a project and choosing its role are different powers.**

- **Creating a project** lets you define *what code runs*.
- **Naming its role** decides *with whose permissions that code runs*.

A project is a container for arbitrary code: the buildspec is whatever the source says. So
"permission to create a project with role X" is in practice "permission to run any code as X".

If `CreateProject` alone were enough, anyone allowed to create projects could name the most privileged
role CodeBuild may assume, and get those privileges without ever being granted them. `iam:PassRole`
makes the handover an explicit grant on **specific role ARNs**. `iam:PassedToService` makes it
specific to the receiving service.

The person keeps the right to build things, but can only lend out roles someone deliberately allowed
them to lend. It's the same reason you can be allowed to start a car without being allowed to choose
whose house key is on the keyring.

### 4. Two roles versus one

**For two roles:**
- **Blast radius.** The pipeline role can start one project, read and write artifacts, and pass one
  role. The build role can write its own logs and the artifact bucket, and runs **arbitrary code from
  the repository**.
  - Merged, every line in every buildspec, including third-party install scripts, could also
    start/stop builds, pass roles, and (after Lab 12) update the ECS service.
  - Split, a compromised build can't redeploy production on its own.
- **Auditing.** CloudTrail attributes actions to the role that took them, so "the pipeline started a
  build" and "the build wrote an object" stay distinguishable.
- **Independent change.** Lab 12 adds ECR push to the build and `ecs:UpdateService` to the pipeline,
  each where it belongs.

**The strongest argument against:**
- The separation is weaker than it looks: the build role can **write the artifact the pipeline
  deploys**. A compromised build can still ship a malicious artifact through the pipeline's
  legitimate deploy.
- Meanwhile two roles double the policy surface, the PassRole wiring and the places to get a
  condition wrong. This lab hit several such mistakes (the trust `SourceArn` had to list two
  projects; the log ARN didn't cover the results project).

Real separation needs artifact integrity (signing, or a separate approval) as well as separate roles.

### 5. The three heredoc forms

- **`<< 'BUILDSPEC'` (quoted) made unquoted.** The shell expands `$USMS_RELEASE`, `$ARTIFACT_DIR`,
  `${CODEBUILD_BUILD_ID:-local}` and `$(...)` *while writing the file*. In my shell they're unset, so
  the file holds empty strings, `local`, and today's timestamp baked in.
  - The YAML stays valid and the build runs.
  - It writes `release ""`, the smoke tests fail far from the cause, and `buildId` reads `local` even
    in CodeBuild.
  - **No error,** because writing a file with empty substitutions is a successful write.
- **`<< META` (unquoted, nested) made quoted.** The metadata file would contain the literal text
  `$SERVICE_NAME`, `$USMS_RELEASE`, `${CODEBUILD_BUILD_ID:-local}`. It's still valid JSON (they're
  strings), so `json.tool` passes.
  - The release check in Step 19 would read `"$USMS_RELEASE"` rather than `r4`.
  - **No error,** because a string that looks like a variable is still a string.
- **`<< EOF` (Step 21, unquoted) made quoted.** `configs/lab-11.env` would contain
  `export USMS_SOURCE_VERSION_ID=$(aws s3api head-object …)`, the command text instead of its value.
  - The `grep 'export .*=$\|None'` check passes, because the line isn't empty.
  - Sourcing it would *run* the AWS calls every time, against whatever endpoint the current shell
    points at, or fail with credentials errors in Lab 12, far from the cause.

In all three, the shell did exactly what it was told. The error is in intent, which no parser can
see.

### 6. Removing `pre_build`'s configuration validation

**They're right when:**
- the deploy stage really does check the same thing,
- it runs on every path to production,
- it fails *before* anything changes,
- and its failure is as cheap and as clear as the build's.

An example is a single pipeline whose deploy validates `imagedefinitions.json` against the task
definition before touching the service, with no other route to production. Then the build check is
duplication.

**They're expensively wrong when:**
- **The deploy check comes after something irreversible.** Lab 12 pushes an image to ECR before
  deploying, and CodeDeploy may have started a task set.
- **The deploy's error doesn't name the cause.** The lab notes that a container-name mismatch fails
  the deploy "with a message that does not name the container".
- **There are other consumers of the artifact.** A second pipeline, a manual `update-service`, or Lab
  12's ECS action reading `imagedefinitions.json` directly.
- **Time matters.** `pre_build` fails in seconds and names the command (figure 34). A failed deploy
  can mean a rollback, a paged on-call engineer, and 15 minutes of a half-updated service.

Validation is cheapest at the earliest stage that has the information, and `pre_build` has it.

### 7. Proving r4 was built from the source in the repository on a given date

Using only what this lab created, the evidence chain is:

1. **Git.** The commit that set `labs/lab-11-cicd/app/VERSION` to `r4`, with its date and author,
   and the tree hash of `labs/lab-11-cicd/app` at that commit.
2. **The packer.** `usms-pack-source.sh` turns that tree into the zip deterministically, apart from
   timestamps in the zip header.
3. **S3 versioning.** `list-object-versions` shows version `f7783912-…` of
   `source/usms-enrolment-src.zip`, with its `LastModified` and ETag. `get-object --version-id`
   retrieves the exact bytes, which can be unzipped and compared file by file with the git tree.
4. **The pipeline execution.** Its Source action recorded external execution ID `f7783912-…`, the
   same version. Its Build action recorded the CodeBuild build ID.
5. **The artifact.** `build-metadata.json` inside BuildOutput carries `release`, `builtAt`,
   `buildId` and `sourceVersion`. Matching `buildId` to step 4, and `sourceVersion` to step 3, closes
   the loop.

**The weakest link is between steps 1 and 3: the upload from my laptop.**
- Nothing proves the zip I uploaded was made from the *committed* tree rather than uncommitted local
  edits. The packer zips the working directory, not a commit.
- The upload was done by a human with S3 write access, so the bytes at version `f7783912` are only as
  trustworthy as that person and that laptop.
- On this Floci build there's a second weak link: `sourceVersion` reads `local`
  (`CODEBUILD_RESOLVED_SOURCE_VERSION` unset) and no BuildOutput exists, so steps 4-5 are broken.
- The fix is to build the source zip from a commit in CI (or tag the S3 object with the commit SHA),
  so the chain starts in version control, not on a disk.

---

## Exercises (summary; full write-up in `labs/lab-11-cicd/exercises.md`)

1. `usms-results-build`: standalone builds succeed, and the artifact says `results r1`. The shared
   log policy would need the results log group on real AWS.
2. `finally` writes `build-summary.txt`. Floci ignores `finally`, so CodeBuild ordering was shown in
   a scratch harness: `tests_exit=1` on the failed build.
3. The JSON parse check passes with 4-space indentation and names both values on mismatch. The trust
   policy has `SourceAccount` + `SourceArn` for both projects.
4. The EventBridge rule, target, role and bucket setting were all created; no execution fired on
   Floci. The S3 notification and CloudTrail paths are explained.
5. `imagedefinitions.json` (from `service.json` + `${IMAGE_URI:-placeholder}`) sits at the artifact
   root, with an 8th smoke test and the readiness file for Lab 12.
