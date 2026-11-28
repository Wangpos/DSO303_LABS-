# Lab 13 - "Your turn" answers and Independent Lab Exercises

Floci 2.1.0. Run on 2026-11-28. Captured output lives in the `outputs/lab-13-*` file named in each
section (git-ignored). What this build cannot do, and what was substituted, is listed in
`outputs/lab-13-support-probe.txt`.

---

## Step "Your turn" answers

### Step 7 - a negative case

Wrote `healthcheck ok: usms-central-application probe` to stream `lab-13-20261128`, timestamped after
the four `USMS_EVENT` lines. `rejectedLogEventsInfo` was `null`; `filter-log-events` returned 5 rows.
Neither `USMS_NOTIFY` nor `ERROR` matches it.

### Step 8 - the ERROR pattern, and its false positive

`test-metric-filter` is unsupported here, so I put the samples into a scratch group
(`/usms/lab-13-filter-test`, deleted afterwards) and asked the server with
`filter-log-events --filter-pattern`, which uses the same term dialect
(`outputs/lab-13-filter-test.json`):

| Pattern | Against | Matches |
|---|---|---|
| `USMS_NOTIFY` | the 4 notifier line shapes | exactly #1 |
| `usms_notify` | same | 0 (case-sensitive) |
| `ERROR` | the 4 Step 7 lines | exactly #4, the `transcript.failed` line |
| `ERROR` | `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}` | **1 - a false positive** |
| `"ERROR USMS_EVENT"` | both | 0 on this build (multi-word phrases don't match here) |

`ERROR` matches any line that has `ERROR` as a token anywhere, including inside a free-text field.
I would **not** accept that in production: a user-controlled string (a reason, a filename, a
student's comment) could inflate `CentralErrorCount` and page someone. The fix is to anchor the error
to the structure, not the text. Either emit a level field and filter on it in the JSON dialect
(`{ $.level = "ERROR" }`), or use a phrase that only the logger writes (`"ERROR USMS_EVENT"`), which
real CloudWatch supports and this build does not.

### Step 10 - what `defaultValue` does

- Window 60-45 minutes ago, period 300: `[]`, an **empty Datapoints list**.
- Window including the upload: one point, `Sum 2.0`.

An empty list means *no data point was ever published* for that period, so an alarm sees *missing
data*. A list full of zeroes means *the filter was running and saw nothing*, so an alarm sees a
real `0`. My build produced the **empty list**: there is no running filter, so `defaultValue=0` never
had a chance to publish anything. That is exactly the distinction `usms-notify-silence`'s
`breaching` policy depends on.

### Step 13 - roll back, confirm, roll forward

`update-alias live → 1`, invoke, then `update-alias live → 3`, invoke. `list-versions-by-function`
showed `$LATEST 1 2 3` throughout and nothing was deleted.

**Honest result:** both invokes through `live` returned the *same* v3-shaped payload (with
`trace_id`). The versions are correct: `get-function --qualifier 1` has the Lab 10 code hash
(`4DuT…`, 1345 bytes), v3 has `r40P…` (2130 bytes), and invoking `usms-transcript-notifier:1`
directly returns the old payload `{"processed": 1, "keys": [...]}`. Floci's routing of an *alias*
to a version is what is missing. The rollback is therefore **recorded** (the alias moved), not
**observed** in behaviour.

On real AWS this rollback is one `update-alias` call and takes effect for the next invocation, a
second or two. The Lambda@Edge rollback from Lab 10 Step 11 means re-associating a version with the
CloudFront distribution and waiting for it to replicate to every edge location, which takes minutes,
not seconds.

---

## Exercise 1 - extract a value instead of counting events

**Choice: change what the emitter writes.** Neither dialect can pull `seconds` out of
`USMS_EVENT {...}`. The JSON dialect needs the *whole* message to be JSON, and the space-delimited
dialect sees exactly two fields (`USMS_EVENT` and a JSON blob with no spaces), with no way to reach
inside the blob. So `usms-emit-telemetry.sh` now writes a second, whole-message-JSON line:

```
{"usms_event":"transcript.processed","faculty":"law","seconds":2.6,"trace_id":"1-..."}
```

The key is lower-case `usms_event`, so the case-sensitive `USMS_EVENT` term pattern does not count
it twice (the `USMS_EVENT` count stayed at one per emitter run).

**Filter** (`templates/lab-13-metric-filters.json`):

```json
{ "filterName": "usms-transcript-seconds", "logGroupName": "/usms/central/application",
  "filterPattern": "{ $.usms_event = \"transcript.processed\" }",
  "metricTransformations": [{ "metricName": "TranscriptSecondsFromLogs",
    "metricNamespace": "USMS/Application", "metricValue": "$.seconds", "unit": "Seconds" }] }
```

**Pattern test** (`outputs/lab-13-ex1-filter-test.txt`). `test-metric-filter` is unsupported and
Floci's `filter-log-events` has no JSON dialect, so the matcher in `usms-metric-filter-emulate.sh`
was used:

```
#1 -     USMS_EVENT {"event":"transcript.processed",...}     (not whole-message JSON)
#2 MATCH {"usms_event":"transcript.processed",...,"seconds":0.77}   -> metricValue 0.77
#3 -     {"usms_event":"transcript.failed",...}
#4 -     ERROR USMS_EVENT {...}
```

**Result:** emitter runs `science 0.77`, `engineering 1.35`, `law 2.60`, then
`usms-metric-filter-emulate.sh 1 usms-transcript-seconds` produced
`3 value(s) [0.77, 1.35, 2.6]`. These match the command line.

**Mistake, recorded:** my first attempt looped over `"science 0.77"` as a single unquoted zsh
variable. zsh doesn't word-split, so three runs went in with faculty `"science 0.77"` and the default
0.42 s. Three junk `Faculty` dimension values now exist in `USMS/Application`
(`science 0.77`, `engineering 1.35`, `law 2.60`). **CloudWatch metrics cannot be deleted**, so they
stay until they expire. This was a live demonstration of why dimension values must be validated.

**Cost:** one extra log line per event. That doubles ingestion for this event type, which is the
largest single CloudWatch Logs cost on real AWS. The alternative, making the `USMS_EVENT` line itself
pure JSON, would have broken the `USMS_EVENT` marker interface, which Steps 9, 17 and 23 depend on.

**Which to keep:** `TranscriptLagSeconds` (Step 11) and `TranscriptSecondsFromLogs` measure the same
duration by two routes. The first is published by the code (`put_metric_data`): exact, immediate,
but it needs a code change for every new measurement and fails silently if the API call fails. The
second is derived from a log line: no code change, but it costs log ingestion and depends on the
log format staying stable. I would keep **`TranscriptLagSeconds`**, because the notifier is our
code and the metric is what the alarm uses. The log route is the one to reach for when the emitting
code is not ours.

## Exercise 2 - portable dashboard, sixth widget

`scripts/utilities/usms-dashboard-generate.sh [--put]` rebuilds `templates/lab-13-dashboard.json`
from `USMS_ACCOUNT_ID` (`configs/lab-01.env`) and `AWS_REGION_COURSE` (`configs/course.env`). The
script contains no account literal, and the alarm ARNs are built from those variables. The generated
file contains `000000000000` only because that *is* the account. Running it with another account
produces another file.

Widget 6 is `CentralErrorCount`, Sum per 5 min, `"start": "-PT3H"`, full width at `y=12`, with a
horizontal annotation at **5**. That is a *proposed* threshold: no alarm exists on this metric yet,
and 5 per 5 minutes is well above the single error this lab ever produced. "It seemed reasonable",
stated honestly.

`put-dashboard` → `[]`. Verify: 6 widgets, no overlaps, `PASS=49 FAIL=0` after changing the widget
check to `-eq 6`.

**Hard-coded count:** it is *useful* because it catches a widget silently lost by a bad merge or a
partial `put-dashboard` (a replace-only API). It is *annoying* because every legitimate addition
breaks verification until someone edits the check. A middle ground is to compare the deployed count
with the count in the committed template.

## Exercise 3 - are these thresholds defensible?

`scripts/utilities/usms-threshold-report.sh` reads every `usms-*` alarm from `describe-alarms`, with
no names hard-coded. It queries each alarm's own metric with its exact dimension set, over 24 h for
the observed min/avg/max/samples and at the alarm's own period and statistic for
`threshold_ever_breached`. It outputs valid JSON only, writes diagnostics to stderr, and was run
from `/tmp` (output: `outputs/lab-13-threshold-report.json`).

| Alarm | Threshold | Observed (24 h) | Ever breached |
|---|---|---|---|
| usms-transcript-lag-high | Max > 2 | min 0.009, avg 1.04, max 3.10, 14 samples | **true** |
| usms-enrolment-queue-high | Avg > 100 | **no data** | false |
| usms-notify-silence | Sum < 1 | 2.0, 1 sample | false *by data* (it fired on missing data) |
| usms-transcript-pipeline-down | composite | null | null |

**Findings.** `usms-enrolment-queue-high` (Lab 6) has had no data at all, so its threshold of 100 has
never been approached, let alone tested. It is an alarm in name only. `usms-notify-silence` shows why
`threshold_ever_breached` is not the whole story: its value never went below 1, yet it alarmed,
because `breaching` turns *absence* into a breach. The report says so in `missing_data`. Note:
`TreatMissingData` and `DatapointsToAlarm` come from the deployed document, not the service
(`missing_data_source: document`), because this build doesn't return them. The composite comes from
its document because `PutCompositeAlarm` is unsupported.

## Exercise 4 - observability plan

See `notes/lab-13-observability-plan.md`.

## Exercise 5 - alarms the next alerting lab can attach to

`scripts/utilities/usms-alerting-readiness.sh --emit` does all five points in one re-runnable command:

1. **Draft:** `outputs/lab-13-alarm-actions-draft.json`. Composite = *page*
   (`arn:aws:sns:us-east-1:<USMS_ACCOUNT_ID>:usms-oncall-page`), children = *ticket*
   (`usms-ops-tickets`) with `actions_enabled: false`, so one incident means one page. The account
   comes from `configs/lab-01.env`.
2. **Validation:** every ARN has six fields and passes the regex. **Mismatch reported, not fixed:**
   `usms-transcript-pipeline-down: not a live alarm (exists only as templates/... -
   PutCompositeAlarm unsupported)`.
3. **Not applied.** `AlarmActions` on both metric alarms is `[]`.
4. **Baseline:** six emitter runs (science 0.48, engineering 1.72, law 0.95, science 2.85,
   medicine 1.10, engineering 0.63) on top of the earlier ones →
   `outputs/lab-13-latency-baseline.json`, max **3.1 s**. Every value above 2 s came from an emitter
   run where I *chose* the latency; the real notifier invocations took 0.01-0.18 s. So a 2 s
   threshold sits an order of magnitude above observed real behaviour, but it is argued from a
   small and mostly synthetic sample.
5. **Report:** `outputs/lab-13-alerting-readiness.txt`, generated, not typed, and git-ignored
   (`.gitignore:6:outputs/*`).

A side effect worth recording: the 2.60 s and 2.85 s runs drove `usms-transcript-lag-high` into
ALARM **by evaluation** ("Threshold Crossed: 2 datapoint(s) breaching"), and the emulated composite
followed. That is the evaluation the lab said Floci would not do.
