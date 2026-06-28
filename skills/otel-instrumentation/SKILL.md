---
name: otel-instrumentation
description: Add or change OpenTelemetry tracing, metrics, and structured logging in the Go API — OTLP exporter setup, custom spans via otel.Tracer, OTel metrics via meter.Counter / Histogram, log↔trace correlation. Use when adding observability, custom spans/metrics, or troubleshooting distributed traces.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill
---

# OpenTelemetry instrumentation

Source of truth: `.claude/rules/observability.md`,
[OpenTelemetry Go docs](https://opentelemetry.io/docs/languages/go/).

## Setup (one-time, in `cmd/api/main.go`)

```go
import (
    "context"
    "os"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/metric"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
)

func initOTel(ctx context.Context, svcName, version string) (func(context.Context) error, error) {
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(svcName),
            semconv.ServiceVersion(version),
            semconv.DeploymentEnvironment(os.Getenv("APP_ENV")),
        ),
    )
    if err != nil { return nil, err }

    // --- traces ---
    texp, err := otlptracehttp.New(ctx,
        otlptracehttp.WithEndpoint(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
        otlptracehttp.WithInsecure(),  // remove for prod TLS
    )
    if err != nil { return nil, err }

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(texp, sdktrace.WithBatchTimeout(5*time.Second)),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1))), // 10% in prod
    )
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, propagation.Baggage{},
    ))

    // --- metrics ---
    mexp, err := otlpmetrichttp.New(ctx,
        otlpmetrichttp.WithEndpoint(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
        otlpmetrichttp.WithInsecure(),
    )
    if err != nil { return nil, err }

    mp := metric.NewMeterProvider(
        metric.WithReader(metric.NewPeriodicReader(mexp, metric.WithInterval(15*time.Second))),
        metric.WithResource(res),
    )
    otel.SetMeterProvider(mp)

    // --- shutdown — flush both before exiting ---
    return func(ctx context.Context) error {
        ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
        defer cancel()
        _ = tp.Shutdown(ctx)
        _ = mp.Shutdown(ctx)
        return nil
    }, nil
}
```

In `main`:
```go
shutdown, err := initOTel(ctx, "{{ProjectName}}-api", version)
if err != nil { log.Fatal(err) }
defer shutdown(context.Background())
```

## Gin middleware

```go
import "go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"

r := gin.New()
r.Use(otelgin.Middleware("{{ProjectName}}-api"))
```

Adds a span per request named by the matched route (`GET /v1/projects/:id`), with
`http.method`, `http.route`, `http.status_code`, and `http.user_agent` attributes
populated automatically.

## Custom spans for sub-operations

```go
import "go.opentelemetry.io/otel"

var tracer = otel.Tracer("{{ProjectName}}/app/projects")

func (h *CreateProjectHandler) Handle(ctx context.Context, cmd CreateProjectCommand) (*CreateProjectResponse, error) {
    ctx, span := tracer.Start(ctx, "projects.create",
        trace.WithAttributes(
            attribute.String("tenant.id", string(cmd.TenantID)),
        ),
    )
    defer span.End()

    if err := h.validate(ctx, cmd); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err
    }
    // ... do work ...
    span.SetAttributes(attribute.String("project.id", string(p.ID())))
    return resp, nil
}
```

**Rules:**
- **One span per logical sub-operation.** Don't span every function; span every meaningful
  unit of work (a transaction, an external call, a non-trivial computation).
- **`defer span.End()`** immediately after `Start`.
- **`span.RecordError(err)` + `span.SetStatus(codes.Error, err.Error())`** on the error
  path — both. RecordError adds the event; SetStatus flags the span red.
- **Attributes for high-cardinality details** (tenant id, project id, query count).
  Avoid raw PII (use ids).

## OTel metrics

```go
var meter = otel.Meter("{{ProjectName}}/app/projects")

var (
    projectsCreated = mustCounter(meter, "projects_created_total",
        "Number of projects created, by tenant")
    projectsCreateDuration = mustHistogram(meter, "projects_create_duration_seconds",
        "Wall time of CreateProject use case")
)

func mustCounter(m metric.Meter, name, desc string) metric.Int64Counter {
    c, err := m.Int64Counter(name, metric.WithDescription(desc))
    if err != nil { panic(err) }  // init bug; happens at startup
    return c
}

// In the handler:
start := time.Now()
defer func() {
    projectsCreateDuration.Record(ctx, time.Since(start).Seconds(),
        metric.WithAttributes(attribute.String("tenant", string(cmd.TenantID))))
}()
// ... on success
projectsCreated.Add(ctx, 1, metric.WithAttributes(attribute.String("tenant", string(cmd.TenantID))))
```

- **Counter** — monotonically increasing (total counts).
- **Histogram** — distributions of values (latencies, sizes). Buckets default to OTel
  recommended sizes; customize via `metric.WithExplicitBucketBoundaries(...)`.
- **UpDownCounter** — for gauges that can go up or down (active connections, queue depth).
- **Observable Gauge** — for values fetched on demand (DB pool stats — register a callback).

## Log ↔ trace correlation

`internal/api/middleware/slog_logger.go` already pulls the span context and adds
`trace_id` / `span_id` to the per-request slog logger. Confirm in the trace backend: search
for `request_id` in logs → click through to the trace.

If you create a custom span inside a handler, the slog logger's trace_id is the **parent
span**'s id — the new span's id won't be in the log unless you re-derive the logger after
the `tracer.Start`:

```go
ctx, span := tracer.Start(ctx, "projects.persist")
defer span.End()
logger := slog.With("span_id", span.SpanContext().SpanID().String())
logger.InfoContext(ctx, "persisting project", "id", p.ID())
```

In practice, the request-level trace_id is usually enough — the trace itself shows the
span hierarchy.

## Common patterns

### Span for an external HTTP call
```go
client := http.Client{
    Transport: otelhttp.NewTransport(http.DefaultTransport),
}
// Every request through this client is auto-traced + propagated.
```

### Span for an external service call (non-HTTP)
```go
ctx, span := tracer.Start(ctx, "llm.complete",
    trace.WithAttributes(
        attribute.String("model", model),
        attribute.Int("prompt_tokens", promptTokens),
    ),
)
defer span.End()
resp, err := llmClient.Complete(ctx, ...)
if err != nil {
    span.RecordError(err); span.SetStatus(codes.Error, err.Error())
    return nil, err
}
span.SetAttributes(attribute.Int("completion_tokens", resp.UsedTokens))
```

### Database span
Either use `otelpgx` (when approved) — auto-instruments every pool call — or wrap manually
in the repository.

## Sampling

- **Production**: `ParentBased(TraceIDRatioBased(0.1))` — 10% of root traces, 100% of child
  spans on a sampled trace.
- **Errors should always be sampled.** A standard pattern: emit a "tail-based" decision via
  the OTel Collector's `tail_sampling` processor — keep traces with `status=error` or
  `duration > X`. Configure in the Collector, not in code.
- **Dev / test**: AlwaysSample. Cheap; you want to see everything.

## What this skill does NOT do

- Edit the OTel Collector config (that's infra).
- Choose between OTLP/HTTP and OTLP/gRPC (OTLP/HTTP is the default; gRPC needs a per-module
  approval).
- Configure log forwarding (the slog handler writes to stdout; the container runtime ships).

## Common mistakes (don't)

- Spanning every function. 5–15 spans per request, not 50.
- Forgetting `span.End()` (or putting it after a `return` without `defer`). Always
  `defer span.End()`.
- Adding the same attribute to every span (e.g. `service.version`) — that's a Resource
  attribute, set once.
- Logging `slog.Info("doing X", "span_id", ...)` manually when the middleware already adds
  it. Trust the middleware.
- Forgetting `span.SetStatus(codes.Error, ...)` on an error path. RecordError alone leaves
  the span "OK" in some backends.
