# USMS Observability Plan - transcript delivery

Lab 13 Exercise 4. A design for the registrar's office, written so a colleague could implement it.
Numbers carry their origin in brackets: **[lab]** observed in Lab 13, **[AWS]** an AWS limit or
pricing fact to re-check before committing, **[judgement]** chosen and open to argument.

## 1. The four complaints, and which layer answers each

| Complaint | Layer | Why not the other two |
|---|---|---|
| Nobody noticed for six hours that delivery had stopped; the dashboard was green because the graphs were empty | **Metrics**, with an alarm on *absence* | Logs record events that happened, and nothing happened. Traces only exist for requests that were made. Only a metric series, where a gap can be *treated as breaching*, can notice that something stopped. |
| We could not tell whether it was the upload, the function or the bucket | **Traces** | A metric says *that* latency rose, not *where*. Logs from three services must be joined by hand, and the join key is often missing. One trace holds the S3 segment, the notifier segment and its subsegments on one timeline, and `service("usms-student-data") { fault }` answers it directly. |
| Who downloaded a particular transcript in March | **Logs**, an audit log group | It is a question about one student and one object months ago. A metric throws identity away by design (and a student-id dimension is forbidden by cost). Traces are sampled and kept 30 days [AWS]. Only a retained, access-controlled log can answer it. |
| Monitoring costs more than the system | **All three, as a cost exercise** | See section 5. Usually the cause is log ingestion and retention, high-cardinality metrics and unsampled traces, not any one feature. |

## 2. Log group taxonomy

A log group is a unit of **retention and access control**, so groups follow who reads them and how
long they are kept, not which component writes them.

| Group | Holds | Retention | Readers |
|---|---|---|---|
| `/usms/central/application` | structured application events from every tier | 30 d [lab] | platform team, developers |
| `/aws/lambda/usms-*`, `/ecs/usms-*`, `/usms/ecs/*` | runtime output (START/END/REPORT, stack traces) | 14 d [judgement] | platform team, developers |
| `/aws/codebuild/usms-*` | build logs | 14 d [judgement] | developers |
| **`/usms/audit/transcript-access`** | one event per transcript read or download: who, which object, when, from where, decision | **2557 d (7 y)** [judgement: in line with common academic-records retention; to be confirmed with the registrar and the institution's records policy] | the audit office and security only; **developers cannot read it** |

**Longest, the audit group (7 years):** it answers a legal and records question, and the March
complaint is precisely the cost of keeping it for too short a time. Its volume is small (one line
per download, not per request), so long retention is cheap. Access is restricted by an IAM policy
scoped to that group's ARN, and writes come from the application role only. Separately, it would be
exported to S3 with Object Lock, so that even an administrator cannot delete history. I need to
verify the current CloudWatch Logs export/subscription options before committing to that design.
**Shortest, function runtime output (14 days):** it is debugging data. If nobody looked in two weeks,
nobody will, and it is the highest-volume, lowest-value group.

## 3. Service level indicators

An SLI is something a student would notice.

| SLI | Target | Alarm or graph |
|---|---|---|
| **Delivery success:** transcripts with a `USMS_NOTIFY` within 5 min of upload ÷ transcripts uploaded | 99.5 % per 30 days [judgement] | **Alarm.** A failed delivery is the thing the student notices. |
| **Delivery latency:** p95 of `TranscriptLagSeconds` | ≤ 2 s [lab: real invocations measured 0.01-0.18 s, so 2 s is roughly 10× the norm] | **Alarm** on the maximum over 2 of 3 minutes (`usms-transcript-lag-high`), graph p95 |
| **Freshness:** minutes since the last successful notification during office hours | ≤ 15 min [judgement] | **Alarm** (`usms-notify-silence`) |
| Render time per faculty | none | **Graph only** |

Render time per faculty is graphed but not alarmed. Nobody acts at 3 a.m. on "engineering renders
are 20 % slower", but the graph is what you open *during* an incident, and it is the baseline from
which a future threshold will be argued. Without the graph, the Exercise 3 question "is this
threshold defensible" has no data to answer it. An un-alarmed SLI is not wasted: it is evidence that
hasn't been needed yet.

## 4. Alarms

| Alarm | Watches | Missing data | Pages? |
|---|---|---|---|
| `usms-transcript-lag-high` | max `TranscriptLagSeconds` > 2 s, 2 of 3 × 60 s | `notBreaching`: no transcripts means no latency to complain about | no, it is a child |
| `usms-notify-silence` | sum `NotifyCount` < 1, 3 of 3 × 300 s | **`breaching`**: absence *is* the failure | no, it is a child |
| `usms-delivery-errors` (new) | sum `CentralErrorCount` > 5 per 5 min, 2 of 3 [judgement; see the dashboard's proposed line] | `notBreaching` | no, it is a child |
| `usms-transcript-pipeline-down` | composite: any of the above | n/a | **yes, the only page** |

**`usms-notify-silence` would have caught the six-hour outage** within 15 minutes. A threshold alarm
on a *value* could not have: when delivery stops, no values are published, so the series is empty.
With the default `missing` policy the alarm keeps its last state (OK) forever. That is why the
dashboard was green. I watched this exact alarm go to ALARM on its own in Lab 13 when the pipeline
went quiet. **Change before production:** students upload far less at night, so a flat 15 minutes
would page every night. Either silence only during office hours (a suppressor composite on a
schedule-driven alarm), or derive the window from measured overnight gaps. I would measure a month
of real `NotifyCount` before choosing; see section 6.

## 5. Where the bill goes, and cardinality

Order-of-magnitude, to be checked against current pricing [AWS]: log **ingestion** is the largest
line (per GB ingested), then **storage** of groups left on never-expire, then **custom metrics**
(per metric per month, where each dimension combination is a metric), then **Insights scans** (per GB
scanned), then **traces** (per trace recorded). Alarms and the first three dashboards are small.

The two changes with the largest effect:

1. **Retention on every group, and stop logging per-request noise.** Lab 13 found every group on
   *never expire*. Retention converts an ever-growing storage bill into a bounded one. Dropping
   debug output from steady-state code cuts ingestion, the largest line, at the source.
2. **Cap dimension cardinality.** Every proposed dimension is bounded:

| Dimension | Values |
|---|---|
| `Faculty` | about 8 [judgement], from a fixed allow-list, **not** from the object path. Lab 13's notifier derived it from the path and immediately produced `Faculty=evidence`, and a quoting mistake produced three junk values that can never be deleted. |
| `Stage` | 3-4 (`notify`, `origin`, `viewer-request`, `render`) |
| Student id | **never** a dimension; log field + trace annotation only |

Third: sample traces with a reservoir plus a rate (2/s plus 10 % [lab sampling rule]) rather than
tracing everything.

## 6. What I would not build yet

**Logs Insights dashboards and saved queries over the central group.** Every question we know we
will ask repeatedly is cheaper behind a metric filter. Insights is billed per scan, and the audit
question is a rare, targeted search that does not need a dashboard. **What would change my mind:**
if, over a term, the team runs the same ad-hoc query more than about once a week, that is a constant
question pretending to be an investigation. I would then promote it, first to a metric filter, and
to a saved query only if it needs log detail.

Before committing to any of this I would **measure**: a month of real `NotifyCount` by hour (for the
silence window), the real distribution of `TranscriptLagSeconds` (for the 2 s threshold, which today
rests on a few synthetic samples), and actual GB ingested per log group (for the cost ranking).
