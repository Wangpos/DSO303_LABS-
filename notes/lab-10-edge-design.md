# Transcript Delivery Policy - Edge Design (Lab 10, Exercise 4)

**For:** the registrar's office and whoever implements this after Lab 10.
**Status:** design only. Nothing here was deployed. Items marked *verify* name the check I would run first.

## Requirements restated

| # | Registrar's words | What it means technically |
|---|---|---|
| R1 | Never served without a valid session token, and the check must not cost an origin request | Validate the token before the cache, and refuse at the edge |
| R2 | A corrected transcript stops being served within five minutes | The *viewer-visible* staleness window is at most 300 s |
| R3 | Don't re-fetch unchanged transcripts every five minutes | Edge revalidation must be cheap, or rare |
| R4 | Report of refused requests, by faculty | Refusals must be counted, with the faculty attached, somewhere central |
| R5 | Survive one edge location being unable to reach the origin | Requests must still be answered through that location |

## 1. Where each piece of logic runs

| Logic | Runtime and trigger | Why |
|---|---|---|
| Verify the session token (JWT signature and expiry), refuse with 403 | **CloudFront Functions, viewer-request**, using the `cloudfront-js-2.0` runtime's `crypto` HMAC and a key held in **CloudFront KeyValueStore** | It runs on every request, including cache hits, so it must be the cheapest option: sub-millisecond and priced per request at a fraction of Lambda@Edge. An HS256 signature check is CPU work with no network call, which is exactly what CloudFront Functions allows. *Verify:* if the portal signs with RS256, check that the runtime's crypto supports it. If it does not, this moves to Lambda@Edge viewer-request, which costs more but has full Node crypto |
| Lowercase the URI | Same CloudFront Function | Free once the function exists. It must run before the cache key is computed |
| Add `x-usms-faculty` to the refusal response, and log a structured line | Same function: `console.log` of `{refused, faculty, reason}` | The faculty is a claim in the token (or the URI prefix), so it is known at refusal time |
| Security headers, `Cache-Control` per object type | **Lambda@Edge origin-response**, or better a **CloudFront response headers policy** | A response headers policy is configuration, not code, and costs nothing per request. I would keep `usms-edge-origin-response` only for logic a policy cannot express (the chain marker, path-dependent `Cache-Control`) |
| Invalidate the corrected object | **Regional Lambda**, triggered by S3 `ObjectCreated` under `transcripts/` (the `usms-transcript-notifier` pattern) calling `CreateInvalidation` for that one path | Nobody is waiting for it, and it needs AWS API calls, so it belongs in a region. It also only runs when something actually changed |
| Faculty refusal report | **Regional**: a scheduled Lambda, or a CloudWatch Logs Insights query run monthly (see §4) | Aggregation over time is not a request-path job |

## 2. The cache key

**In the key:**
- the lower-cased URI.

**Deliberately not in the key:**
- **The session token or `Authorization` header.** Every student's token is different, so keying on it
  creates one cache entry per token and a 0% hit ratio. Authorisation happens *before* the cache, in
  the viewer-request function. The cache then holds objects that are safe to serve to anyone who got
  past the check.
- **Cookies and query strings.** Nothing at the origin varies on them. Lab 10 forwarded no cookies for
  the same reason.
- **`X-USMS-Student`.** Lab 10's distribution forwards it, and I would remove it. That is safe only if
  the function also checks that the token's subject matches the student id in the URI, so student A
  cannot fetch `/transcripts/2026/stu-B.json`. That check belongs in the same function, and without it
  R1 is not met at all.

## 3. Five minutes, without re-fetching every five minutes

Two caches, two directives:

| Cache | Directive | Value | Effect |
|---|---|---|---|
| Browser | `max-age` | 300 | A student sees a correction within five minutes, even from their own browser cache |
| CloudFront | `s-maxage` | 86400 (a day, not Lab 10's 3600) | The edge rarely goes back to S3 |
| Edge, on change | `CreateInvalidation /transcripts/<year>/<id>.json` | event-driven | A corrected object leaves every edge within the invalidation's propagation time, usually well under five minutes |

The **edge TTL is long because staleness is handled by events, not by expiry**. Unchanged transcripts
are fetched from S3 about once a day per location. Changed ones are purged when the change happens.

**Alternative design:** `s-maxage=300` plus conditional revalidation. CloudFront sends
`If-None-Match` with the ETag, and S3 answers `304`. That is a small origin request every five minutes
per hot object, with no invalidation machinery. It is simpler but violates the spirit of R3.

**What I would measure first:**
- the **correction rate**,
- the invalidation propagation time against the five-minute promise, and
- the cost of invalidations against `304`s.

If corrections exceed roughly 1,000 paths a month, invalidations stop being free, and the
revalidation design may be cheaper. That result would change my mind.

## 4. Where the refusal report comes from

Lambda@Edge and CloudFront Functions do **not** log to one region.
- **Lambda@Edge** logs to CloudWatch in the region nearest the viewer that ran it. A student in Thimphu
  lands in an Asia-Pacific region, and one abroad somewhere else.
- **CloudFront Functions** logs always go to `us-east-1`, in `/aws/cloudfront/function/<name>`, which
  is one reason to prefer them here.

So:

- **Primary source:** the viewer-request function's structured log line, in `us-east-1` only. One
  Logs Insights query:
  `filter refused | stats count() by faculty, bin(1d)`.
- **Cross-check:** CloudFront **standard or real-time access logs**. These record every request with
  its status (403) and URI path. The path carries the faculty if transcripts are keyed by faculty
  prefix; *verify* that the key layout allows this. If not, the faculty must be logged by the function.
- If any piece stays on Lambda@Edge, the report job must query **every region** the distribution
  serves from, or subscribe each regional log group to one central destination. That is the cost of
  choosing Lambda@Edge for logging.

## 5. Where an edge function is the wrong tool

**R5, origin unreachable from one edge location**, is not solved with code on the request path. A
function cannot reach an origin that the location itself cannot reach. Use CloudFront features
instead:

- **An origin group with failover:** a primary S3 bucket in `us-east-1`, and a secondary **replica
  bucket** (S3 Cross-Region Replication) in another region. CloudFront fails over on 5xx or connection
  errors.
- **Origin Shield**, so that edge locations fetch through a regional cache layer rather than all
  reaching S3 directly.
- **A long `s-maxage`** (§3), so most requests never need the origin at all. Optionally,
  `stale-if-error`, so a cached copy can be served while the origin is down. *Verify* how CloudFront
  honours `stale-if-error` in current docs before relying on it.

The **faculty report** is also not request-path work: it belongs in a regional, scheduled job (§1).

## Risks and open questions

- **The token-to-URI match (§2) is the real security control.** Without it, any authenticated student
  can read any transcript. It needs a test with two student tokens before go-live.
- **Key rotation for the HMAC secret** in KeyValueStore: who rotates it, and how two keys overlap
  during the change.
- **Cost:** CloudFront Functions on every request, plus Lambda@Edge only on misses. Measure the hit
  ratio for a week, because a low one makes the origin-response function the expensive part.
