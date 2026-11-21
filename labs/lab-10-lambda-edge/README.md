# AWS Practical Laboratory Report: Lab 10 - Edge Functions with AWS Lambda

## 1. Aim / Objective

To put code on the request path and on the event path, and to prove each piece did what it claims:

* create `usms-student-data`, the bucket `USMSStudentDataReadWrite` has named since Lab 01, as the CloudFront origin,
* build two **Lambda@Edge** functions (`viewer-request`, `origin-response`), invoke them with real CloudFront event shapes, publish versions, and check them against the edge restrictions,
* associate both with a CloudFront distribution and prove they **compose** with `usms-edge-simulate.sh`,
* build a **regional** S3-triggered notifier with an alias and a scoped resource policy, and prove it ran,
* prove everything survives a restart, and save the identifiers to `configs/lab-10.env`.

**Support path: A** (Floci 2.1.0: `cloudfront list-distributions` and `create-distribution` work, as a
record only). S3 → Lambda event delivery **works** on this build. `--log-type Tail` does not.

Run date: 2026-11-22 (UTC timestamps in evidence read 2026-11-21T19:xx).

---

## 2. Introduction

| Question | Edge function | Regional function |
|---|---|---|
| Triggered by | a viewer's request | an event (here: S3 `ObjectCreated`) |
| Is somebody waiting? | yes, the viewer | no |
| Configuration | constants in code (no env vars) | environment variables |
| Referenced by | a **published version** only | name, version or **alias** |
| Runs | at the point of presence nearest the viewer | in `us-east-1`, near the data |

| Concept | In this lab |
|---|---|
| **Trigger points** | `viewer-request` runs *before* the cache, so it can refuse for free. `origin-response` runs *after* the origin and *before* caching, so its headers are cached |
| **Version vs alias** | A version is frozen, an alias moves. CloudFront replicates non-transactionally, so it accepts only the frozen one |
| **Execution role vs resource policy** | What the code may do, versus who may invoke the code |
| **Confused deputy** | `--source-arn`/`--source-account` pin S3's permission to one bucket in one account |
| **Replace-only APIs** | `update-assume-role-policy`, `put-bucket-notification-configuration` |

---

## 3. Architecture (after this lab)

```
VIEWER ── GET /transcripts/2026/STU-00417.json
  │
  ▼  usms-transcript-cdn  (EBP0AGPSCFGMCQ, Deployed - a record in Floci)
  (1) viewer-request  → usms-edge-viewer-request:2   lowercases URI; no X-USMS-Student → 403, origin untouched
  [ cache ] miss
  (3) origin-response → usms-edge-origin-response:3  HSTS, nosniff, DENY, referrer, CSP, cache-control, chain marker
  │
  ▼  origin: usms-student-data.s3.us-east-1.amazonaws.com
        transcripts/evidence/*.json
        notification usms-transcript-upload  ObjectCreated:*  prefix=transcripts/ suffix=.json
           └──► usms-transcript-notifier:live → v1   (python3.12, env vars, resource policy: s3 + SourceArn)

ROLES
  usms-lambda-exec-role   trust: lambda (Lab 09 SourceAccount+SourceArn) + edgelambda   USMSLambdaBasic (recreated)
  usms-edge-exec-role     same trust (Ex 2)                                              USMSEdgeBasic (logs on /aws/lambda/usms-edge-* only)
```

Versions 1 of both edge functions (on `usms-lambda-exec-role`) still exist. The distribution and
`configs/lab-10.env` point at the Exercise 1-2 releases (viewer **:2**, origin **:3**).

---

## 4. Pre-flight (Steps 1-4)

- **Start-up:** `floci-up.sh` started the container. This repository's `floci-storage-check.sh` is the
  older three-section version, with no `PASS=16` total. All three sections pass: running, `hybrid`,
  data directory present.
- **Environment files:** all nine `configs/lab-NN.env` files sourced. `whoami.sh` reports
  `000000000000`. `USMS_BUCKET_NAME` was already set (`usms-student-data`).
- **Where state lives:** `COURSE_ROOT` and `FLOCI_HOST_DATA_DIR` point at the older copy under
  `~/Documents/.../aws-floci-course`, which holds `floci-data/`. The repository is `~/aws-floci-course`.
  The lab's `"$COURSE_ROOT/outputs/x.zip"` would have written the archives into the *other* copy, so
  I built them with the repository path instead. Nothing else changed.
- **Support probe** (`outputs/lab-10-support-probe.txt`): all six probes **SUPPORTED**, CloudFront
  included, so Step 15 takes **Path A**. The limitations found later in the lab are appended to the
  same file.

**Two Lab 09 consequences had to be handled before Step 6:**

| Found | Why | What I did |
|---|---|---|
| `usms-lambda-exec-role` had **no managed policy**; `USMSLambdaBasic` did not exist | Lab 09 recreated the role with an *inline* `usms-lambda-basic` (logs only) after Lab 01's reset | Recreated **`USMSLambdaBasic`** as a managed policy (`policies/usms-lambda-basic-managed-policy.json`): log writes scoped to `/aws/lambda/usms-*`, plus `s3:GetObject` on `usms-student-data/*` only. Attached it. The inline policy was left in place |
| The trust policy had Lab 09's `aws:SourceAccount` + `aws:SourceArn` conditions | Lab 09's confused-deputy fix | The lab's one-statement document would have **silently removed** that fix. `policies/trust-lambda-edge.json` has **two statements**: `lambda.amazonaws.com` keeps the conditions, and `edgelambda.amazonaws.com` is unconditioned, as in AWS's Lambda@Edge role example |

Because of the second row, the Step 6 verify query `length(Statement[0].Principal.Service)` returns 1
here. I used `length(Statement[].Principal.Service)`, which returns **2**. `verify-lab-10.sh` reads every
statement and passes.

---

## 5. Procedure, Evidence and Observations

### 5.1 Origin bucket (Step 5) - Checkpoint 1

- `create-bucket` with no `LocationConstraint` (us-east-1), tagged `Project=USMS, Tier=data, Lab=06`.
- `head-bucket` exits **0**, for the first time in the course. Lab 03's probe and Lab 09 Step 6 both
  got 404.
- `USMSStudentDataReadWrite`'s resources are `arn:aws:s3:::usms-student-data` and `.../*`, so the
  ARNs resolve now.
- The policy is held by `usms-ec2-app-role`, `usms-ecs-task-role` and `usms-eks-node-role`.
  `USMSStudentDataReadOnly` (Lab 09) is held by `usms-transcripts-reader-role`.

### 5.2 Execution role (Step 6) - Checkpoint 2

The trust policy now has `lambda.amazonaws.com` (scoped) and `edgelambda.amazonaws.com`. The
attached policy is `USMSLambdaBasic`. `EDGE_ROLE_ARN = arn:aws:iam::000000000000:role/usms-lambda-exec-role`.

### 5.3 viewer-request function (Steps 7-9) - Checkpoint 3

| Check | Result |
|---|---|
| `index.mjs` written with a **quoted** heredoc | 55 lines, `studentId` 3×, line 51 keeps `${studentId.toLowerCase()}` |
| Archive | one entry, `index.mjs`, no directory prefix |
| Function | `nodejs20.x`, `index.handler`, 128 MB, 5 s, `Active`, `$LATEST` |
| Allow invoke (`outputs/lab-10-viewer-allow.json`) | Status 200, Error None; `uri` → `/transcripts/2026/stu-00417.json`; new `x-usms-edge: viewer-request-allow;student=stu-00417` |
| Deny invoke, "Your turn" (`outputs/lab-10-viewer-deny.json`) | Status 200, Error None. The body is a **response object**: `status "403"`, `statusDescription`, `x-usms-edge: viewer-request-deny`, a JSON `body`, and **no `uri`** |

The first invoke took about 31 s, while Floci pulled the Node.js runtime image. Later invokes take
about 1 s.

### 5.4 Logs (Step 10)

`--log-type Tail` returned **`LogResult: None`**. The group `/aws/lambda/usms-edge-viewer-request`
exists with one stream and 0 bytes. This handler never logs, so the returned payloads are the
evidence, as the lab's limitation box allows. This is recorded in the probe file.

### 5.5 Version (Step 11) - Checkpoint 4

`publish-version` gave **1**: `arn:aws:lambda:us-east-1:000000000000:function:usms-edge-viewer-request:1`.
`list-versions-by-function` shows `$LATEST` and `1`, and the `:[0-9]+$` check reports *version-qualified*.

### 5.6 origin-response function (Steps 12-13)

- **Invoke** (`outputs/lab-10-origin-response.json`):
  - The four security headers and `cache-control: public, max-age=300, s-maxage=3600` are added.
  - The origin's `content-type`, `etag` and `server` survive.
  - `x-usms-edge-chain = viewer-request-allow;student=stu-00417;origin-response`. This is the first
    evidence that the two functions compose.
- **Version 1** was published.

### 5.7 Edge restrictions (Step 14) - Checkpoint 5

- **Setting environment variables succeeded.** That's correct: the mistake is legal *for Lambda* and is
  only rejected later by CloudFront at association time.
- **Cleared** with `Variables={}`.
- **`edge_eligibility`** (`outputs/lab-10-function-inventory.json`): six `ok` per function and
  **0 `NO` lines**.

### 5.8 CloudFront distribution, Path A (Step 15) - Checkpoint 6

- **Template** `templates/lab-10-distribution-config.json` (unquoted heredoc): both ARNs are
  substituted and end in `:1`.
- **`create-distribution`** exit 0: Id **`EBP0AGPSCFGMCQ`**, domain `EBP0AGPSCFGMCQ.cloudfront.net`,
  Status **`Deployed`** at once (real AWS shows `InProgress` for minutes).
- **`get-distribution`** returns both associations.
- **Path B, extra evidence:** I also ran the structural validator against the same file
  (`outputs/lab-10-distribution-validation.json`). Result: **11 `ok`, `errors: []`**.

After the exercises, `update-distribution` repointed the associations to viewer **:2** and origin **:3**
(§9). Floci accepted it and reports `Deployed`.

### 5.9 The chain end to end (Step 16) - Checkpoint 7

`scripts/utilities/usms-edge-simulate.sh`:

| Run | Chain | Result |
|---|---|---|
| allow event | viewer-request → origin (simulated) → origin-response | 200, 5 added headers, `x-usms-edge-chain = viewer-request-allow;student=stu-00417;origin-response` |
| deny event | viewer-request | 403, `cache-control: no-store`, `x-usms-edge: viewer-request-deny`; **origin never contacted** |

The allow trace was restored afterwards for Exercise 5.

**Change from the lab text:** the deny branch now also deletes its temporary `.edge-step1.json`. The
original left that file in `outputs/`.

### 5.10 Regional notifier (Steps 17-18) - Checkpoint 8

- **`notifier.py`** compiles, and its two `os.environ.get` lines are the contrast with the edge
  functions. `__pycache__` was removed.
- **Function:** `python3.12`, `notifier.handler`, 256 MB, 30 s. Env: `USMS_BUCKET=usms-student-data`,
  `USMS_NOTIFY_CHANNEL=stdout`.
- **Version 1**, and **alias `live` → 1**. `--qualifier live` reports `Version: "1"`.
- **"Your turn"** (`outputs/lab-10-alias-rollback.txt`): published **v2**, then `live` → 2, then
  `live` → 1. The versions list `$LATEST 2 1` throughout, so no version was deleted.

### 5.11 Resource policy (Step 19)

`add-permission --qualifier live`, statement `usms-s3-transcript-upload`: principal `s3.amazonaws.com`,
action `lambda:InvokeFunction`, resource `...:usms-transcript-notifier:live`. The assertion printed
*scoped to one bucket in one account*.

**Floci limitation:** `--source-account` was accepted, but `get-policy` shows only the `ArnLike
AWS:SourceArn` condition. The `StringEquals AWS:SourceAccount` block is missing.

### 5.12 Notification and the first object (Step 20) - Checkpoint 9

- `templates/lab-10-bucket-notification.json` (unquoted heredoc) targets `...:live`, with
  `s3:ObjectCreated:*`, `prefix=transcripts/` and `suffix=.json`.
- Uploaded `outputs/lab-08-scaling-evidence.json` → `transcripts/evidence/lab-08-scaling-evidence.json`
  (2822 B), the first object in the course's bucket.

### 5.13 Proof the notifier ran (Step 21)

- **Real delivery worked:**
  ```
  USMS_NOTIFY {"bucket": "usms-student-data", "event": "ObjectCreated:Put",
               "key": "transcripts/evidence/lab-08-scaling-evidence.json", "readable": true, "size": 2822}
  ```
  `readable: true` means the container reached Floci's S3 and `head_object` succeeded.
- **Synthetic fallback:** run anyway, because it produces the committed `templates/lab-10-s3-event.json`.
  It returned `{"processed": 1, ...}` with `read_error: ClientError`. That is expected, since the
  probe key doesn't exist.
- **Floci quirk:** the invoke through `--qualifier live` reports `ExecutedVersion: $LATEST`. Real AWS
  reports `1`.
- **Filter "Your turn"** (`outputs/lab-10-filter-proof.txt`): `notes/ignore-me.json` (wrong prefix)
  and `transcripts/evidence/ignore-me.txt` (wrong suffix) were both uploaded, and neither produced a
  `USMS_NOTIFY` line.

### 5.14 Restart (Step 22) - Checkpoint 10

- **Inventory:** I added the distribution to the lab's `inventory()`, since it exists on Path A.
  The inventory was taken before and after `floci-down.sh`/`floci-up.sh`, and the `diff` printed
  **IDENTICAL**.
- **Code survived too:** `usms-edge-simulate.sh` still produced the full chain header after the
  restart, so the code survived, not only the names.

### 5.15 `configs/lab-10.env` (Step 23)

- **Written:** with an unquoted heredoc. **25 exports**, `all values populated`, and it sources
  cleanly. The CloudFront lines carry real values (`yes`, `EBP0AGPSCFGMCQ`, the domain).
- **Refreshed after Exercises 1-2:** the four edge version lines, the version ARNs and
  `USMS_EDGE_ROLE_ARN` now describe what the distribution uses (viewer:2, origin:3,
  `usms-edge-exec-role`). Without that, `VERSION=3` would have sat next to `VERSION_ARN=...:1`.

---

## 6. Verification (Section 8)

`scripts/utilities/verify-lab-10.sh` → **`PASS=51  FAIL=0`**. It was run after Step 23 and again
after the exercises (`outputs/lab-10-verify.txt`).

`scripts/cleanup/lab-10-cleanup.sh` was written and syntax-checked, and **not run**. One change from
the lab text: step 2/6 now actually **disables** the distribution (`update-distribution` with
`Enabled: false`) before deleting it. The original only printed that it would, and real CloudFront
refuses to delete an enabled distribution. It also states that `USMSLambdaBasic` is left in place.

---

## 7. Results

| Item | Result |
|---|---|
| `usms-student-data` | exists, tagged, 4 objects (3 under `transcripts/`), no bucket policy (correct) |
| Edge functions | 2, `nodejs20.x`, 128 MB, 5 s, no env vars, versions 1-2 (viewer) and 1-3 (origin) |
| Regional function | `python3.12` 256 MB 30 s, env vars, versions 1-2, `live` → 1 |
| Distribution | `EBP0AGPSCFGMCQ`, 2 version-qualified associations |
| Composition | allow: 3 stages + chain header; deny: 1 stage, 403 |
| S3 → Lambda | delivered; filter excludes wrong prefix and wrong suffix |
| Restart | IDENTICAL |
| `verify-lab-10.sh` | **51/0** |

---

## 8. Floci vs Real AWS (observed on this build)

| Feature | Floci 2.1.0 (observed) | Real AWS |
|---|---|---|
| create/update/publish/invoke | Works; runtime image pulled on first invoke (~31 s) | Works |
| **Version immutability** | **Metadata only.** v1 keeps its own `CodeSha256`/size, but `invoke --qualifier 1` runs `$LATEST` code and reports `ExecutedVersion $LATEST` (Exercise 1) | Each version runs its own frozen code |
| `--log-type Tail` | `LogResult: None` | Last 4 KB, base64 |
| Log groups | Created; the notifier's `print()` lines are captured | Always |
| `add-permission --source-account` | Accepted, **not stored** | Stored as `AWS:SourceAccount` and enforced |
| Resource policy and execution role | Stored, not enforced | Enforced on every call |
| S3 → Lambda notification | **Delivered** within seconds; filter honoured | Same |
| `boto3` inside the container | Reached Floci's S3 (`readable: true`) | Execution-role credentials |
| CloudFront distribution | Record only; `Deployed` instantly; associations not validated | Minutes to deploy; association rules enforced |
| Lambda@Edge execution | Never; `usms-edge-simulate.sh` stands in | Replicated to every point of presence |
| CloudWatch Logs filter pattern with `-` in a quoted term | No match (Exercise 5) | Matches |

**Observed:** functions created and invoked, event shapes, a request modified and refused, a response
modified, composition, versions and aliases, the resource policy document, the bucket, the
notification and its filter, delivery, and persistence.

**Recorded only:** the two-principal trust rule, the association rules (qualified ARN, no env vars,
caps), and the distribution's effect on a real request path.

**Not available at all, and not claimed as tested:** latency, caching, cost, and edge-log regions.

---

## 9. Independent Exercises (summary; full answers in [exercises.md](exercises.md))

| Exercise | Outcome |
|---|---|
| 1. CSP header | Added as one `SECURITY_HEADERS` line; origin-response **v2**. `$LATEST` returns 5 security headers. v1's metadata still describes the 4-header code (1092 B, its own SHA), but Floci **executes `$LATEST` for every qualifier**, so `--qualifier 1` also returned 5. This is a Floci limitation, documented |
| 2. Edge role | `usms-edge-exec-role` + `USMSEdgeBasic` (log writes on `/aws/lambda/usms-edge-*:*` only). Viewer **v2** and origin **v3** use it; `--qualifier 1` still reports `usms-lambda-exec-role` |
| 3. Edge report | `usms-edge-report.sh`: JSON on stdout, diagnostics on stderr, works from `/tmp`, no hard-coded list. The notifier is `edge_eligible: false` for **one** reason under the stated rules (env vars); see exercises.md |
| 4. Design | `notes/lab-10-edge-design.md` |
| 5. S3 hand-over | The draft's resources and principals all resolve. **2 mismatches reported, not fixed**: its deny-all-but-holders statement would deny `usms-lambda-exec-role` (breaking the notifier's `GetObject`) and `usms-edge-exec-role`. Trace uploaded and seen by the notifier. `outputs/lab-10-s3-readiness.txt` is produced by `usms-s3-readiness.sh` and is git-ignored. `get-bucket-policy` → `NoSuchBucketPolicy` |

---

## 10. Files Produced

| Kind | Files |
|---|---|
| Source | `labs/lab-10-lambda-edge/{edge-viewer-request/index.mjs, edge-origin-response/index.mjs, transcript-notifier/notifier.py}` |
| Policies | `trust-lambda-edge.json`, `usms-lambda-basic-managed-policy.json` (pre-flight), `usms-edge-basic-policy.json` (Ex 2) |
| Templates | `lab-10-viewer-request-event.json`, `-denied.json`, `lab-10-origin-response-event.json`, `lab-10-distribution-config.json`, `lab-10-bucket-notification.json`, `lab-10-s3-event.json` |
| Scripts | `scripts/utilities/{usms-edge-simulate.sh, verify-lab-10.sh, usms-edge-report.sh, usms-s3-readiness.sh}`, `scripts/cleanup/lab-10-cleanup.sh` (not run) |
| Config | `configs/lab-10.env` (25 exports) |
| Evidence (git-ignored) | `outputs/lab-10-*`: support probe, viewer allow/deny, origin response, function inventory, distribution (+ validation), edge trace, alias rollback, notifier logs/direct, filter proof, pre/post restart, verify, ex1, ex2, ex5, edge report, s3 readiness; 3 × `.zip` |
| Write-up | this report, [exercises.md](exercises.md), `notes/lab-10-notes.md`, `notes/lab-10-edge-design.md` |

---

## 11. Conclusion

The bucket that four policies had named since Lab 01 now exists. Two edge functions compose into one
request path, one regional function reacts to uploads, and all of it survives a restart and passes
51 checks.

The most useful results were the ones the lab text did not predict:
- **The lab's trust policy would have undone Lab 09's confused-deputy fix.** A two-statement document
  keeps both.
- **Floci's versions are immutable on paper only.** A Lambda@Edge rollback really does depend on old
  versions still running their old code, so that rule can be *read* here but not *observed*.
- **Lab 09's bucket-policy draft would lock out the notifier** the moment the S3 lab applies it. That
  is reported in the readiness file for the next lab to decide.

The lab's own rule turned out to be the right one: *a command appearing to succeed is not evidence it
did what you meant.* Three of the five Floci limitations above were found by reading back what an
apparently successful call had stored.
