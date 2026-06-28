# {{ProductName}} — Observability standards

> The observability program: traces, metrics, logs — what we collect, how it correlates,
> what we expect to find in a production trace. The rules are in
> `.claude/rules/observability.md` (auto-loaded on `*.go`); this doc is the *why*.

## The three signals

| Signal | Tool | Used for | Default backend |
|---|---|---|---|
| **Logs** | `log/slog` (stdlib) | What happened, structured, in dev / on-call. Always has request_id, trace_id, tenant. | JSON to stdout → container runtime / Loki / Datadog |
| **Traces** | OpenTelemetry (otelgin + custom spans) | Causal flow across services; latency attribution. | OTLP → Tempo / Datadog / Honeycomb |
| **Metrics** | OpenTelemetry meter | Aggregate counts / latencies / gauges. RED on endpoints + USE on resources. | OTLP → Prometheus / Datadog / OTel Collector |

## The correlation

The killer feature: log line → trace → span → SQL query. Every log carries `trace_id` +
`span_id`. Every span has the `request_id` + tenant + handler name as attributes. The
loop:

1. See an error in logs (`level=ERROR`).
2. Grab the `trace_id`.
3. Open the trace — see every middleware, every handler, every DB call.
4. Spot the slow / failing span.
5. Read its attributes (tenant, query text, error message).
6. Cite `file:line` from the span name.

Master this loop. It's the foundation of every RCA.

## Setup

`cmd/api/main.go` initializes (see `.claude/skills/otel-instrumentation/SKILL.md` for the
full code):

```go
// 1. Resource — identifies this service across signals
res := resource.NewWithAttributes(semconv.SchemaURL,
    semconv.ServiceName("{{ProjectName}}-api"),
    semconv.ServiceVersion(version),
    semconv.DeploymentEnvironment(os.Getenv("APP_ENV")),
)

// 2. Traces — OTLP exporter, batch processor, parent-based sampling
otel.SetTracerProvider(sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(traceExporter),
    sdktrace.WithResource(res),
    sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1))),
))

// 3. Metrics — OTLP exporter, periodic reader
otel.SetMeterProvider(metric.NewMeterProvider(
    metric.WithReader(metric.NewPeriodicReader(metricExporter, metric.WithInterval(15*time.Second))),
    metric.WithResource(res),
))

// 4. slog — JSON handler in prod, with default attributes
slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
    Level: levelFromEnv(),
    AddSource: true,
})).With(
    slog.String("service", "{{ProjectName}}-api"),
    slog.String("version", version),
))
```

## Middleware chain (load-bearing order)

```go
r.Use(
    gin.Recovery(),                  // catches panics from everything that follows
    middleware.RequestID(),           // generates / extracts request_id
    middleware.SlogLogger(),          // per-request logger; carries trace_id, span_id, tenant
    otelgin.Middleware(svcName),      // per-request span
    middleware.Timeout(15 * time.Second),
    middleware.Auth(),
    middleware.Tenancy(),
    middleware.ProblemDetails(),      // last — sees every error
)
```

## What goes into a log line

```json
{
  "time": "2026-06-20T12:34:56Z",
  "level": "INFO",
  "msg": "project created",
  "service": "{{ProjectName}}-api",
  "version": "v0.4.1",
  "request_id": "req-abc-123",
  "trace_id": "0123456789abcdef0123456789abcdef",
  "span_id":  "0123456789abcdef",
  "tenant":   "01HN...",
  "method":   "POST",
  "path":     "/v1/projects",
  "project_id": "01HM..."
}
```

**Rules:**
- **slog attributes, not Printf strings.** `logger.Info("created", "id", id)` — not
  `Sprintf`.
- **Pull from context** — `LoggerFrom(ctx)` — so the per-request attributes are attached.
- **No secrets / PII.** Sensitive fields implement `slog.LogValuer` to redact.
- **Levels**: `Debug` (chatty diagnostic, off by default), `Info` (significant events),
  `Warn` (degraded), `Error` (real failure).
- **No `fmt.Println` / `log.Println` in production code.** The linter would flag them.

## What goes into a trace

A typical request span tree:

```
POST /v1/projects                                       (span: otelgin)
├─ middleware.RequestID                                  ~0ms
├─ middleware.Tenancy                                    ~0ms
├─ handler                                               (span name = route)
│  └─ app.projects.create                                (span: custom)
│     ├─ app.projects.validate                           (span: custom — if non-trivial)
│     ├─ domain.projects.New                             (no span — pure)
│     └─ infra.persistence.projects.upsert               (span: custom)
│        └─ pgx.exec                                     (span: otelpgx, if wired)
└─ middleware.ProblemDetails                             ~0ms
```

**Rules:**
- One span per logical sub-operation: 5–15 per request. Not 50 (noise), not 1 (useless).
- `defer span.End()` immediately after `Start`.
- On error: `span.RecordError(err)` AND `span.SetStatus(codes.Error, msg)`.
- `span.SetAttributes(...)` for high-cardinality details (tenant id, project id, query
  count). Avoid PII; use ids.

## What goes into metrics

### Auto (from `otelgin`)
- `http.server.request.duration` — latency histogram per route.
- `http.server.requests.total` — request count per route + status.

### USE (per critical resource — wire manually)
- `pgxpool.connections.acquired` — utilization.
- `pgxpool.connections.waiting` — saturation.
- `pgxpool.acquire.errors` — errors.
- (Same triplet for any external resource: HTTP client pool, cache, queue.)

### RED (per endpoint — auto from otelgin, but cross-check)
- **Rate** — requests / second.
- **Errors** — error rate (4xx + 5xx, by status class).
- **Duration** — latency p50 / p95 / p99 (histogram quantiles in PromQL).

### Custom domain metrics
- `projects_created_total{tenant=...}` — counter.
- `projects_create_duration_seconds{tenant=...}` — histogram.
- (Use sparingly; high cardinality on tenant id breaks the metrics store.)

## Health endpoints

- `GET /healthz` — liveness. Always 200 while process is healthy. No DB call, no auth.
- `GET /readyz` — readiness. Checks DB pool + critical deps; 503 if any fail. Used by
  load balancer / k8s.
- `GET /metrics` (optional) — Prometheus format, if you scrape rather than push via
  OTLP. Locked-down in prod.

## Pull-from-context discipline

The single most important observability convention: **the request's slog logger and OTel
span context travel via `ctx`.** Every internal function takes `ctx`. Helpers like:

```go
func LoggerFrom(ctx context.Context) *slog.Logger {
    if v, ok := ctx.Value(loggerKey).(*slog.Logger); ok { return v }
    return slog.Default()
}
```

…ensure every log line and every span lands in the right place.

**Never** call `slog.Default()` in a handler — you'd lose request_id / trace_id / tenant
correlation.

## Sampling

- **Production**: parent-based + 10% ratio. Errors should be 100% sampled — configure
  in the OTel Collector's `tail_sampling` processor (keep traces with `status=error` or
  `duration > X`).
- **Dev / staging**: AlwaysSample. You want to see everything.

## What we DON'T do

- **Continuous profiling** (Pyroscope, Parca, Datadog Profiler) — add when you actually
  need longitudinal flame graphs.
- **Trace level diagnostics in prod** (`runtime/trace`) — useful but expensive; pull on
  demand.
- **Custom span events for every function call.** Spans are for sub-operations, not
  function boundaries.
- **Log everything at `Info`.** Production logs are noisy enough; `Debug` for chatty
  diagnostic.

## See also

- `.claude/rules/observability.md` — auto-loaded rules.
- `.claude/skills/otel-instrumentation/SKILL.md` — wiring procedure.
- `.claude/skills/query-telemetry/SKILL.md` — diagnostic procedure.
- `cmd/api/main.go` — actual setup code (once scaffolded).
