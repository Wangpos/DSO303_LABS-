# Lab 10 Notes - Edge Functions with AWS Lambda

**Support path: A.** Floci 2.1.0 (`floci/floci:latest`). CloudFront is supported as a record, S3 →
Lambda delivery works, and `--log-type Tail` returns `None`. Nothing in IAM, function policies or
CloudFront associations is enforced.

Run date: 2026-11-22 (the evidence's UTC timestamps read 2026-11-21T19:xx).

---

## Pre-flight

- **Storage check:** `floci-storage-check.sh` in this repository is the older version with three
  sections (running, `hybrid`, data directory) and no `PASS=16` line. All three passed.
- **Two copies of the course:** `COURSE_ROOT` and `FLOCI_HOST_DATA_DIR` point at
  `~/Documents/Year IV Sem I/DSO303/Lab/aws-floci-course`, while I work in `~/aws-floci-course`. The
  Floci state lives in the first. The lab builds archives with `"$COURSE_ROOT/outputs/..."`, which
  would have dropped the `.zip` files into the *other* copy, so I used the repository path.
- **`USMS_BUCKET_NAME`** was already set; nothing was added to `lab-01.env`.

## "Your turn" answers

### Step 9 - the deny path

I built `templates/lab-10-viewer-request-denied.json` from the allow event in Python: removed
`x-usms-student` and set `requestId` to `lab06-deny-0001`. The invoke returned Status 200, Error None.
The output is a **response**: `status "403"`, `statusDescription "Forbidden"`,
`x-usms-edge: viewer-request-deny`, `cache-control: no-store`, and a JSON `body`. There is no `uri`
anywhere. The function did not fail; it made a decision.

### Step 18 - roll forward and back

Published v2 from unchanged `$LATEST`, then `update-alias live → 2`, then `list-aliases` showed
`live 2`. Then `update-alias live → 1`, and it showed `live 1`. `list-versions-by-function` showed
`$LATEST 2 1` both times, so repointing never deleted anything. No trigger was touched: the S3
notification targets `:live`, not a number.

### Step 21 - the filter

- `notes/ignore-me.json` → **excluded by the prefix rule** (`transcripts/`).
- `transcripts/evidence/ignore-me.txt` → **excluded by the suffix rule** (`.json`).

Both uploads succeeded (`list-objects-v2` shows them). This build *does* deliver events, and no new
`USMS_NOTIFY` line appeared, so the exclusion was observed, not just reasoned.

## Findings (everything this lab found)

| # | Finding | Action |
|---|---|---|
| 1 | `USMSLambdaBasic` did not exist; the role had only Lab 09's inline logs policy | Recreated it as a managed policy: logs on `/aws/lambda/usms-*:*` + `s3:GetObject` on `usms-student-data/*`. Attached |
| 2 | The lab's `trust-lambda-edge.json` would **remove** Lab 09's `SourceAccount`/`SourceArn` on `lambda.amazonaws.com` | Two statements: scoped `lambda` + unconditioned `edgelambda` |
| 3 | `add-permission --source-account` accepted, but not stored | Recorded. The `SourceArn` condition is present |
| 4 | Versions are immutable in metadata only; invoke always runs `$LATEST` | Recorded (Exercise 1). Version-specific behaviour cannot be observed here |
| 5 | Lab 09's bucket-policy draft would deny the notifier's role | Reported in the readiness file, not fixed (Exercise 5) |
| 6 | The lab's cleanup script never disables the distribution before deleting it | Added `update-distribution` with `Enabled: false` before the delete |
| 7 | `usms-edge-simulate.sh` leaves `outputs/.edge-step1.json` behind on the deny path | Added `rm` in that branch |
| 8 | The lab's Step 6 verify reads only `Statement[0]` | Read `Statement[]` instead (finding 2 makes two statements) |
| 9 | Exercise 3's "two independent reasons" does not follow from its own rules | Reported one reason honestly; see exercises.md |

## Floci limitations hit

| Limitation | Real AWS |
|---|---|
| `LogResult: None` with `--log-type Tail` | Last 4 KB of the log |
| Viewer function log group created with 0 events (it never logs) | Same; the code prints nothing |
| `ExecutedVersion: $LATEST` for `--qualifier live` and `--qualifier 1` | The resolved version number |
| `AWS:SourceAccount` dropped from the function policy | Stored and enforced |
| CloudFront `Deployed` instantly, associations not validated | Minutes; `InvalidLambdaFunctionAssociation` on env vars, aliases or over-cap memory |
| Quoted filter pattern containing `-` doesn't match | Matches |

---

## Section 14 - Review Questions

### 1. "Move the whole enrolment API to Lambda@Edge, it'll be faster for everyone."

**The two strongest arguments against:**

1. **The data does not move with the code.** Enrolment reads and writes the database (`usms-db-01`,
   in one VPC in `us-east-1`). An edge function runs near the viewer but must cross the continent for
   every query. Lambda@Edge cannot attach to a VPC at all, so it could not even reach a private
   database without a public endpoint. A request that does three queries becomes three
   intercontinental round trips: slower, not faster.
2. **The edge is a hostile place to run an application.** There are no environment variables, no
   layers, no VPC, no reserved concurrency and no aliases. Viewer triggers have hard 5 s and 128 MB
   caps. Every deployment is a replication that takes minutes, and logs scatter across regions.
   Enrolment is a write-heavy, stateful API that needs transactions and rollbacks, which is the
   opposite of what the edge is for.

**When they would be right:** for a part of the API that is **read-mostly, cacheable and needs no
origin data**. For example, serving the public course catalogue, or rejecting unauthenticated or
malformed requests before they cost an origin trip. Then the viewer is answered from the nearest
location, and the edge really is faster.

### 2. CloudFront Functions vs Lambda@Edge

| | CloudFront Functions | Lambda@Edge |
|---|---|---|
| Runtime | `cloudfront-js` (a restricted JavaScript subset) | Node.js or Python |
| Trigger points | **viewer-request, viewer-response only** | all four |
| Limits | sub-millisecond execution budget, 2 MB memory, 10 KB package, **no network or file access** | viewer 5 s/128 MB, origin 30 s/10 GB; network access allowed |
| Body access | none | yes (`IncludeBody`) |
| Runs at | every edge location (more of them) | regional edge caches |
| Relative cost | about 1/6 of Lambda@Edge per request, no duration charge | per request + GB-second |

- **Add `/index.html` to a URI:** a **CloudFront Function**, viewer-request. It is a string operation
  on every request, with no network access needed, so the cheapest runtime wins.
- **Check a JWT signature:** a **CloudFront Function** if it is HMAC (HS256) with the key in
  KeyValueStore, because that is pure CPU work. **Lambda@Edge** viewer-request if it needs RS256 with
  key fetching (JWKS), since that needs full crypto or the network.
- **Fetch a per-user redirect from DynamoDB:** **Lambda@Edge**. It needs a network call, which
  CloudFront Functions cannot make. Origin-request is the best trigger: it runs only on misses, and
  with the redirect cached per user via the cache key, each user costs one lookup per TTL.

### 3. origin-response vs viewer-response for the security headers

- **origin-response** runs on a **cache miss only**: once per object per edge location per TTL. Its
  output is **stored in the cache** with the object, so the headers are added once and served from
  cache to everyone afterwards.
- **viewer-response** runs on **every response**, cache hits included, and its changes are **not
  cached**.

The output is identical, but viewer-response costs one invocation per request instead of one per
miss. At a 95% hit ratio, that is about 20 times more invocations.

**A requirement that forces viewer-response:** any header that must differ **per viewer** while the
object stays shared. For example:
- a per-request `Content-Security-Policy` nonce,
- a `Set-Cookie` or `X-Request-Id` per viewer,
- a header that depends on the viewer's country (`CloudFront-Viewer-Country`) for the same cached
  object.

A header added at origin-response would be computed once and served to everyone, which is wrong for
those.

### 4. "The execution role and the resource policy are redundant"

They govern **different calls, made by different callers**:

| Policy | Caller | Call it governs |
|---|---|---|
| Execution role (`usms-lambda-exec-role` + `USMSLambdaBasic`) | **the function's own code**, using the role's temporary credentials | `s3:GetObject`/`head_object` on the transcript, `logs:PutLogEvents` |
| Resource policy on `:live` | **S3**, acting as `s3.amazonaws.com` | `lambda:InvokeFunction` on the notifier |

**Delete the resource policy:** S3 can no longer invoke the function. On real AWS the notification
fails **silently**: no error to the uploader, and no log, because the function never ran. (S3 also
refuses to *save* such a notification configuration: "Unable to validate the following destination
configurations".)

**Delete the execution role's policy:** the function still runs on every upload, but `head_object`
gets `AccessDenied`, so `readable` becomes false. The log lines vanish too, because `PutLogEvents` is
denied, which makes the failure invisible as well.

Neither policy can do the other's job. One is about who may **call** the function, the other about
what the function may **call**.

### 5. `--source-arn` and `--source-account`

**The attack.** Without them, the statement says "the S3 service may invoke this function". S3 acts
for *every* customer. An attacker in another account creates `attacker-bucket`, adds a notification
pointing at `arn:aws:lambda:us-east-1:000000000000:function:usms-transcript-notifier:live`, and
uploads objects. S3, a trusted deputy, invokes our function on the attacker's behalf. The result:
- our code runs on attacker-chosen events (crafted keys, floods that we pay for),
- it is reading with **our** role's credentials,
- and anything the notifier does with an event (soon, an SNS publish to the registrar) happens on the
  attacker's say-so.

**The defence.** `--source-arn arn:aws:s3:::usms-student-data` and `--source-account 000000000000`
become `aws:SourceArn` / `aws:SourceAccount` conditions. S3 includes the real source in its request,
so the call is allowed only when S3 is acting **for our bucket in our account**.

**Lab 09's equivalent:** the `aws:SourceAccount` + `aws:SourceArn` conditions added to
`usms-ecs-task-role`'s **trust policy**. They are the same idea because in both cases a **service
principal** is trusted, and a service acts for many customers. The conditions pin *on whose behalf*
the service is acting. One is on a role's trust policy (who may assume), the other on a function's
resource policy (who may invoke). Both are resource-based policies that name a service, and both
close the confused-deputy gap.

### 6. Environment variables on an edge function: "it succeeded"

**Where validation happens:** in **CloudFront**, when a distribution is created or updated with a
`LambdaFunctionAssociation` naming the function version. CloudFront rejects the call with
`InvalidLambdaFunctionAssociation: The function cannot have environment variables` (and similarly for
aliases, `$LATEST`, the wrong region, or over-cap memory).

**Why not immediately:** `update-function-configuration` is a **Lambda** API about a **Lambda**
resource. To Lambda, environment variables are a normal feature, and the function is not yet "an edge
function". It only becomes one when CloudFront associates it, in a different API call, at a different
time, against a different resource. Lambda cannot know whether you intend to associate it later.

**What that implies:**
- Edge configuration has to be checked **statically, against the edge rules, before association**.
  That is Step 14's `edge_eligibility`, the `verify-lab-10.sh` checks, and Exercise 3's report.
- On Floci, the association is not validated at all, so the static check is the *only* check.

**The general rule:** a command that exits 0 tells you the service accepted the request on *its own*
terms. It does not tell you the result is fit for the purpose *you* had in mind. Here the call
succeeded and the configuration was still invalid. This lab hit the same thing three more times:
`add-permission --source-account` "succeeded" without storing the condition, `--qualifier 1`
"succeeded" while running `$LATEST`, and the Lab 09 draft "validates" while it would lock out the
notifier. Each was found only by **reading back** what was stored, or what actually ran.

---

## Exercises (summary; full write-up in `labs/lab-10-lambda-edge/exercises.md`)

1. CSP header added; origin-response v2. v1's metadata is unchanged, but Floci executes `$LATEST`.
2. `usms-edge-exec-role` + `USMSEdgeBasic` (logs only); viewer v2 and origin v3; v1 keeps the old
   role, so rolling back also rolls back the privilege.
3. `usms-edge-report.sh`: 2 eligible, notifier not (environment variables).
4. `notes/lab-10-edge-design.md`.
5. Draft valid against the bucket and roles, with 2 deny-statement mismatches reported; trace
   uploaded and seen; readiness file reproducible and git-ignored.
