---
name: query-telemetry
description: Query the {{ProductName}} observability stack (OTLP → Grafana/Loki/Tempo/Prometheus, or your provider equivalent) for logs, traces, and metrics during diagnosis. Use when investigating an issue via telemetry — errors, latency, request traces, custom metrics. Preloaded by the rca-investigator agent.
allowed-tools: Read, Glob, Grep, Bash, WebFetch
---

# Query telemetry

This skill is preloaded by the `rca-investigator` agent. The harness assumes telemetry
flows via OpenTelemetry (OTLP) to a backend stack — in the default scaffold, Grafana +
Loki (logs) + Tempo (traces) + Prometheus / OTel Collector (metrics). Substitute Datadog,
Honeycomb, etc., as your product uses.

## What you query

| Signal | Backend (default) | What it answers |
|---|---|---|
| Logs | Loki (via Grafana Loki API or LogQL) | "what did the service say at time X" |
| Traces | Tempo (via Tempo Search / TraceQL) | "what spans ran for request ID X; which one was slow" |
| Metrics | Prometheus (via PromQL) | "what's the rate / error rate / latency percentile over time" |

## How to ask the right question

1. **Start with the symptom.** "Requests to `/v1/projects` started returning 500 at
   14:32 UTC. Show me the error logs for the affected tenant."
2. **Pick the signal that maps to your symptom:**
   - **An error spike** → logs at `Error` level + trace search filtered by `status=error`.
   - **A latency spike** → metric histograms for that endpoint + a sample trace from the
     slow window.
   - **A specific request** → request ID → trace (every log has `request_id`; every trace
     has `request_id` as a span attribute).
3. **Bound the time window.** Always include start + end (UTC).
4. **Tenant scope.** Narrow to the affected tenant via the `tenant` log/span attribute.
5. **Read the actual data.** Don't paraphrase; quote the log lines / span attributes.

## Example queries (Grafana stack)

### LogQL (Loki) — error logs for a tenant in a window
```
{service="{{ProjectName}}-api"} |= "level=ERROR" | json | tenant="01HN..." | line_format "{{.timestamp}} {{.msg}} req={{.request_id}} trace={{.trace_id}}"
```

### LogQL — search by request_id (the killer query)
```
{service="{{ProjectName}}-api"} | json | request_id="req-abc-123" | line_format "{{.timestamp}} [{{.level}}] {{.msg}}"
```

### TraceQL (Tempo) — slow traces for an endpoint
```
{ name="POST /v1/projects" && duration > 2s }
```

### TraceQL — failed traces
```
{ name="POST /v1/projects" && status=error }
```

### PromQL — p95 latency by route
```
histogram_quantile(0.95, sum by (route, le) (rate(http_server_request_duration_seconds_bucket{service="{{ProjectName}}-api"}[5m])))
```

### PromQL — error rate
```
sum by (route) (rate(http_server_requests_total{service="{{ProjectName}}-api", status=~"5.."}[5m]))
/
sum by (route) (rate(http_server_requests_total{service="{{ProjectName}}-api"}[5m]))
```

### PromQL — pgx pool saturation
```
sum(pgx_pool_in_use_connections{service="{{ProjectName}}-api"})
/
sum(pgx_pool_max_connections{service="{{ProjectName}}-api"})
```

## Correlating logs and traces

Every log line carries `request_id`, `trace_id`, `span_id`. Every span carries the same
ids as attributes. So:

1. Find an erroring log line.
2. Copy its `trace_id`.
3. Open the trace in Tempo. See the full request: which middleware, which handler, which
   DB call took how long.
4. Click each span: read its attributes (tenant id, user id, query text).

This loop is the core of telemetry-driven RCA. **Master it.**

## What this skill DOES NOT do

- Mutate telemetry (you can't anyway — the stack is read-mostly by design).
- Run on a production stack without authentication. The harness expects you have read
  credentials configured.
- Sample data. The stack should already sample at the export side (`ParentBased` +
  `TraceIDRatioBased` in `cmd/api/main.go`); don't filter further unless you know what
  you're dropping.

## Reporting evidence

Quote the actual log line / span / metric:

```
> LogQL: {service="api"} | json | request_id="req-abc-123"
2026-06-20T14:32:11.244Z [ERROR] handler=projects.Create tenant=01HM... err="pgx: ErrNoRows" trace_id=t-456...
2026-06-20T14:32:11.241Z [INFO]  handler=projects.Create tenant=01HM... msg="creating project" name="x" trace_id=t-456...

> TraceQL: t-456...
- middleware.RequestID    0.1ms
- middleware.Tenancy      0.4ms
- handler                 1240ms  ← slow
  - app.CreateProject     1238ms
    - pgxpool.Acquire     1230ms  ← this is the cause
    - sqlc.UpsertProject  6ms
- middleware.ProblemDetails 0.2ms
```

In the report: "The pool was saturated — `pgxpool.Acquire` took 1.23s out of 1.24s total."

## Common pitfalls (avoid)

- Querying a wide time window for logs. Tight bounds keep the query fast and the output
  small. Default to ≤ 1 hour.
- Forgetting the service label. Without it, you'll pull noise from other services.
- Trusting paraphrases. Quote the actual data.
- Asking "why is it slow" without first asking "where is it slow" (the trace tells you).
