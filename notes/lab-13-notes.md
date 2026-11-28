# Lab 13 Notes - Centralized Logging and Monitoring with CloudWatch and X-Ray

**Build:** Floci 2.1.0 (`floci/floci:latest`), `hybrid` storage. Run date 2026-11-28.
**Support path:** Insights **unsupported** (Step 23 path B). X-Ray **absent** (Steps 15-18 structural
validation). Metric filters and composite alarms **unsupported** (documents + stand-in scripts).
Metric alarms **evaluated**. Full list: `outputs/lab-13-support-probe.txt`.

## Observed vs recorded vs not available

- **Observed:** log groups and retention; events with millisecond timestamps; a `USMS_NOTIFY` line
  from a real S3 → Lambda delivery; patterns tested server-side; custom metrics with and without
  dimensions (SampleCount 2 / Max 1.91); the alias repointed to v3 then v4 with `Active` tracing; a
  forced OK → ALARM → OK transition; **evaluated** transitions of both metric alarms;
  configuration *and* metric/log data surviving a restart.
- **Recorded only:** metric filters (document + emulator), the composite alarm (document + evaluator),
  X-Ray segments and sampling (documents, structurally valid), alias rollback behaviour, IAM
  enforcement.
- **Not available:** Insights, X-Ray, alarm history, AWS-published metrics, a rendered dashboard,
  the CloudWatch agent, cost.

---

## Review questions

### 1. "We have logs, so we do not need metrics"

First, **answering a numeric question over time is cheap with metrics and expensive with logs.** A
metric is a pre-aggregated time series: "how many transcripts per minute for the last month" reads a
few hundred numbers. The same question from logs means scanning every event in the window, every
time it is asked. Insights bills per GB scanned, and a dashboard that refreshes every minute asks
continuously. Second, **alarming needs metrics.** CloudWatch alarms evaluate metrics, not log text,
and an alarm on silence (Step 19) needs a series in which a gap is meaningful. Logs only tell you
about things that happened; they cannot tell you something stopped. Logs remain the cheap place to
keep *detail* (the one student, the exact error) that a metric deliberately throws away.
**They are right** when the question is a one-off, investigative, or high-cardinality: "what did
stu-01044's request do on Tuesday". You would never build a metric for that, and a log query is the
correct tool.

### 2. Metric filter (Step 9) vs direct publish (Step 11)

| | Metric filter | `put-metric-data` |
|---|---|---|
| Retroactive? | No, it applies from creation onward | No, it measures only what the code publishes from deployment |
| Cost | log ingestion (already paid) + one metric | one metric + an API call per publish |
| Adding a measurement | a new filter; no deployment | a code change and a deployment |
| Emitting code not yours | still works, as long as the code logs | impossible |

For **"how many transcript downloads happened"** I would use a metric filter. The event is already
logged, a count needs nothing but a match, and if downloads are served by code we don't own
(CloudFront, a vendor), a filter is the only option. For **"how long the render took"** I would
publish directly. It is a measured value our own code knows precisely, and it should not depend on a
log format staying stable. Extracting it from text (Exercise 1) is possible but costs extra
ingestion. The answers differ because one is a *count of an event that is already visible* and the
other is a *measurement only the code can take*.

### 3. `notBreaching` on lag-high, `breaching` on silence

Lag-high with `breaching`: every quiet minute (3 a.m., weekends) would count as "slow", and it would
page all night when nothing is happening. No transcripts means no latency to complain about, so
missing really is fine. Silence with `notBreaching`: the alarm exists *only* to notice that data
stopped. If missing data counts as fine, it can never fire, because the condition it watches for
produces no data points. It would look correctly configured forever. **An incident the second
catches and the first cannot:** the S3 bucket notification is overwritten by a
`put-bucket-notification-configuration` that forgets the Lambda entry (Section 3's warning). Uploads
continue, the notifier is never invoked, no latency is ever published, so lag-high stays OK. Only
silence notices, after 15 minutes. **The dashboard during it:** every latency graph flat and empty,
the "notifications in the last 5 minutes" tile blank or 0, and every alarm except silence green.
That is exactly the registrar's "all green because the graphs were empty". I watched the silence
alarm do this on Floci: it went to ALARM on its own with "missing datapoints treated as breaching".

### 4. Metric dimension vs X-Ray annotation

A **dimension** is part of a metric's identity. Each distinct combination is a separate, billed time
series, indexed for *aggregation over time*: sum, max and percentiles of that series, graphable and
alarmable. As distinct values grow, cost and `list-metrics` sprawl grow linearly, and series can
never be deleted (this lab left three junk `Faculty` values behind, permanently). An **annotation**
is an indexed key on an individual *trace*, for *finding requests*: "show me traces where
faculty = science and the bucket faulted". Growth in distinct values costs nothing extra, because
you pay per trace, not per value. You can filter and group traces by it, but you cannot graph or
alarm on it.

- **Faculty:** both. It is a dimension (about 8 values, and you want per-faculty throughput graphs
  and alarms) and an annotation (for filtering traces).
- **Student id:** an annotation (and a log field), never a dimension. 30 000 values would mean
  30 000 billed metrics, and you want to find one student's request, not graph each student.
- **Origin's HTTP status:** in the trace's `http.response.status`, which X-Ray uses to classify
  error/fault/throttle. As a metric, roll it up into a small set (2xx/4xx/5xx) as a dimension or
  separate counts, which is low cardinality and alarmable.
- **Renderer name:** an annotation. It has few values, but you would use it to compare traces ("are
  slow renders all wkhtmltopdf?"), not to graph. If one renderer is suspected, promote it to a
  dimension later.

### 5. Why the tracing change needed its own version

A published version is an immutable snapshot of code **and** configuration (Lab 10 Step 11).
`TracingConfig` is configuration, so changing it modifies only `$LATEST`. If I had left `live` on
v3 (my instrumented version), S3 notifications would have kept invoking an untraced snapshot.
`$LATEST` would show `Active`, `get-function-configuration` without a qualifier would look correct,
and no trace would ever be produced by real traffic. Publishing v4 and moving the alias is the only
way the trigger, which names `live`, sees the change. The same applies to environment variables:
the Step 13 environment update was only effective because the version was published *after* it.

### 6. What Step 20's forced alarm proves

It **proves** that the alarm exists, is addressable by name, accepts a state, reports that state
and reason back, and can return to OK. On a real account it would also prove that its actions fire
(the SNS message is sent, the runbook link works, the pager rings). It does **not** prove that the
threshold, statistic, period or missing-data policy are right, or that the metric it watches is
actually being published. `set-alarm-state` bypasses evaluation entirely. On this build I happened
to get both halves: the forced transition, and later two *evaluated* transitions. You test what
happens *after* the alarm fires because that is the part nobody exercises until the outage. A
perfect threshold attached to an SNS topic nobody subscribes to is a silent alarm. This is the
course's rule in another form: `put-metric-alarm` returning nothing proves only that the call was
accepted, just as this build accepted `--treat-missing-data` and then didn't return it. Only reading
back, and perturbing, shows that it did what you meant.
