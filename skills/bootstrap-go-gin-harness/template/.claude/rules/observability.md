---
description: OpenTelemetry traces + metrics, log/slog structured logging, log↔trace correlation, request id. Auto-loads on Go files and cmd/api/main.go.
paths:
  - "**/*.go"
  - "cmd/api/**"
---

# Observability

Authoritative refs: `docs/projectStandards/observability-standards.md`, `otel-instrumentation`
skill, [OpenTelemetry Go docs](https://opentelemetry.io/docs/languages/go/).

## The three signals — what goes where

| Signal | Used for | Identity |
|---|---|---|
| **Logs** (`log/slog`) | What happened, with context, for a human to read in dev / on-call. | Structured key/value; always carries `request_id`, `trace_id`, `span_id`, `tenant_id`. |
| **Traces** (OTel spans) | Causal flow across services. Slow request → which span owns the latency. | Auto: `otelgin` per HTTP request, pgx-instrumentation per DB call. Custom: `tracer.Start(ctx, "name")` for sub-operations worth a span. |
| **Metrics** (OTel) | Aggregable counts / latencies / gauges. RED + USE per critical resource. | Defined in code (`meter.Int64Counter("orders_created")`); exported via OTLP. |

## slog setup

`cmd/api/main.go` configures slog once, at startup:

```go
opts := &slog.HandlerOptions{Level: levelFromEnv(), AddSource: true}
handler := slog.NewJSONHandler(os.Stdout, opts) // structured JSON in prod
// dev: slog.NewTextHandler with tint-style colour is fine; do not commit if env-specific
logger := slog.New(handler).With(
    slog.String("service", svcName),
    slog.String("version", version),
)
slog.SetDefault(logger)
```

`internal/api/middleware/slog_logger.go` attaches a per-request logger to context:

```go
reqLogger := slog.Default().With(
    slog.String("request_id", requestID),
    slog.String("trace_id", trace.SpanContextFromContext(ctx).TraceID().String()),
    slog.String("span_id",  trace.SpanContextFromContext(ctx).SpanID().String()),
    slog.String("method", c.Request.Method),
    slog.String("path",   c.FullPath()),
    slog.String("tenant", string(tenant)),
)
c.Set("logger", reqLogger)
ctx = ContextWithLogger(ctx, reqLogger)
c.Request = c.Request.WithContext(ctx)
```

**Rules:**
- **No `fmt.Println` / `log.Println` / `log.Printf`** in production code paths. Linters
  flag bare `log.*` calls.
- **Pull the logger from context** (`LoggerFrom(ctx)`) — never use `slog.Default()` in a
  request handler; you lose request_id / trace_id correlation.
- **Use slog attributes, not Printf-style formatting:**
  ```go
  // YES
  logger.Info("project created", "project_id", id, "tenant_id", tenant)
  // NO — loses the attributes
  logger.Info(fmt.Sprintf("project %s created for tenant %s", id, tenant))
  ```
- **Never log secrets, tokens, PII.** If a struct has a field that's sensitive, give it a
  `LogValue()` method that redacts:
  ```go
  func (c Credentials) LogValue() slog.Value {
      return slog.GroupValue(slog.String("user", c.User), slog.String("password", "***"))
  }
  ```
- **Levels:**
  - `Debug` — chatty per-call info, off by default in prod
  - `Info` — significant events (request finished, job completed)
  - `Warn` — degraded behaviour, recoverable failure (retry succeeded)
  - `Error` — failure that won't recover on its own (bug, infra outage)
  - `Fatal`-equivalent is `os.Exit(1)` after a log; only `cmd/api/main.go` does this.

## OTel traces

- **Service-wide tracer** initialized in `cmd/api/main.go`:
  ```go
  exp, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpoint(endpoint))
  tp := sdktrace.NewTracerProvider(
      sdktrace.WithBatcher(exp),
      sdktrace.WithResource(resource.NewWithAttributes(
          semconv.SchemaURL,
          semconv.ServiceName(svcName),
          semconv.ServiceVersion(version),
      )),
      sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(sampleRate))),
  )
  otel.SetTracerProvider(tp)
  otel.SetTextMapPropagator(propagation.TraceContext{})
  ```
- **`otelgin` middleware** auto-creates a span per request, named by handler. Don't create
  a duplicate span at the handler entry.
- **Sub-operations worth a span**: external HTTP call, DB transaction, expensive computation.
  Default to ~5–15 spans per request — not 50 (noise), not 1 (useless).
  ```go
  ctx, span := tracer.Start(ctx, "projects.persist")
  defer span.End()
  if err := repo.Save(ctx, p); err != nil {
      span.RecordError(err)
      span.SetStatus(codes.Error, err.Error())
      return err
  }
  ```
- **`span.SetAttributes(...)`** for high-cardinality details (tenant id, project id, query
  count). Avoid PII.
- **Pgx instrumentation**: use `otelpgx` (when approved as a dep) to auto-trace DB calls,
  or hand-wrap `Acquire`/`Query` calls.
- **Sampling**: parent-based + ratio (10% in prod typical). Errors should be sampled at 100%
  — use a sampler that always keeps spans with `Error` status (custom sampler or post-export
  filter).

## OTel metrics

- **Service-wide meter** in `cmd/api/main.go`. Counters/Histograms/Gauges per resource:
  ```go
  meter := otel.Meter("{{ProjectName}}/api")
  reqCounter,    _ := meter.Int64Counter("http_server_requests_total",
      metric.WithDescription("HTTP requests by route + status"))
  reqLatency,    _ := meter.Float64Histogram("http_server_request_duration_seconds",
      metric.WithDescription("HTTP request latency"))
  ```
- **RED on every endpoint**: Rate, Errors, Duration. The `otelgin` middleware already emits
  these via semantic conventions — confirm in production once.
- **USE on every critical resource** (DB pool, cache, queue):
  - Utilization (e.g. `pgx_pool_in_use_connections`)
  - Saturation (e.g. `pgx_pool_waiting_count`)
  - Errors (e.g. `pgx_pool_acquire_errors_total`)
- **Custom domain metrics**: counters for important business events
  (`projects_created_total`, `documents_uploaded_total`), labeled by tenant where cardinality
  permits (per-tenant for ≤ thousands; otherwise aggregate).

## Log ↔ trace correlation

The slog handler adds `trace_id` and `span_id` from the context — Grafana / Datadog / etc.
join logs to traces on those fields. Verify in one place: search for a request id in logs,
click through to the trace, see the same id in span attributes.

## Health checks

- **`GET /healthz`** — liveness (process up). No DB call, no auth. Returns 200 always
  while the process is healthy.
- **`GET /readyz`** — readiness (dependencies up). Checks DB pool + each critical dependency
  with a short timeout. Returns 503 if any check fails. Used by load balancers / k8s.
- **`GET /metrics`** — Prometheus-format metrics endpoint (if you scrape rather than push
  via OTLP). Locked-down or unexposed in prod depending on infra.

## What's NOT in this rule

- Profile export to Pyroscope / Parca — add when you actually need continuous profiling.
- Frontend / RUM signals — out of scope for the API harness.
