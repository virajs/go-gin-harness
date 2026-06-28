# {{ProductName}} — Backend Architecture

> **Status: PRE-SCAFFOLD (governance written).** No production code is scaffolded yet,
> but the decisions below are **ratified into enforceable rules + skills** under
> `.claude/rules/backend/` and `.claude/skills/`. This document is the rationale.

The conventions here cover *domain modelling, layering, persistence patterns, CQRS, and
the failure model* for a Go HTTP API on Gin + pgx + sqlc.

> ## Governance: no module without owner approval
> **Never introduce, assume, or default to a third-party Go module without the owner's
> explicit, per-module approval.** Prefer the standard library or a minimal hand-rolled
> solution. This overrides any "best practice" that reaches for a package. Already on
> the approved set (canonical for this harness): Gin, pgx, sqlc-generated code, goose,
> testify, testcontainers-go, golang-jwt, go-playground/validator, otel (and contrib),
> uuid. Anything else is a fresh decision.

---

## 0. TL;DR

| Concern | Decision |
|---|---|
| **API style** | Gin, **feature folders** at the API layer, hand-maintained `Register(...)` per feature, thin handlers (bind → validate shape → dispatch → map result). |
| **Layers** | Domain ← App ← Infra ← API. Domain has zero project refs. Group by feature inside each layer. |
| **Domain** | Rich, mutable structs with **unexported fields**; `NewX(...) (*X, error)` constructor; UUIDv7 minted in domain; invariants enforced inside methods; `tenant_id` first-class. |
| **App layer** | Use cases as commands/queries + handlers + business validators, feature-sliced. Interfaces only for cross-layer (repositories, external adapters). |
| **Errors & validation** | Handlers return typed `*result.Error` (in `internal/shared/result/`). Three validation scopes: contract (Gin tags) / business (use-case `validate`) / invariant (domain throws sentinels). **Every API failure → RFC 9457 ProblemDetails**. |
| **CQRS** | Commands mutate, queries read. One file per use case. Naming `{Verb}{Noun}Command`, `Get{Noun}Query`. No mediator library — direct invocation. |
| **Infra** | `internal/infra/persistence/<feature>/` for pgx + sqlc repos; `internal/infra/<adapter>/` for external services. |
| **Persistence** | **pgx + sqlc** (typed queries from SQL). Repository per aggregate root (write side). Thin `UnitOfWork` (transaction verbs only), implemented by a tx-aware ctx pattern. |
| **Transactions** | A decorator (middleware-style) wraps every command handler in `ExecuteInTransaction`. Queries skip it. |
| **Migrations** | goose; `*.up.sql` + `*.down.sql` pairs in `migrations/`. Applied in integration tests too. |
| **Concurrency** | `context.Context` first parameter; every goroutine has an owner; race detector on every test run; `errgroup` for fan-out. |
| **Observability** | OTel (OTLP exporter) traces + metrics; `log/slog` JSON logs; log↔trace correlation via context. |
| **API documentation** | **OpenAPI 3.0 is mandatory.** Spec at `docs/api/openapi.yaml`; served by the API at `GET /openapi.{json,yaml}`; CI gate via `make openapi-validate`. Generator approach (spec-first / code-first / manual) is a per-project ADR — see `docs/decisions/*-openapi-generation.md` and `.claude/rules/backend/openapi.md`. |
| **Tenancy** | `tenant_id` mandatory on every persisted row; sqlc query parameter; server-derived from JWT; PostgreSQL RLS as backstop. |

---

## 1. Project layout

```
{{ProjectName}}/
├─ cmd/
│  └─ api/main.go                    composition root: wiring, server, shutdown
├─ internal/
│  ├─ domain/<feature>/              pure entities + value objects (no third-party imports)
│  ├─ app/<feature>/                 use cases + repository interface + business validators
│  ├─ infra/
│  │  ├─ persistence/<feature>/      pgx + sqlc repository implementations
│  │  └─ <adapter>/                  external adapters (mail, storage, identity, LLM)
│  ├─ api/
│  │  ├─ features/<feature>/         Gin handlers (REPR style, one file per use case)
│  │  ├─ middleware/                 auth, tenancy, request-id, slog, otel, timeout, problem-details
│  │  └─ router.go                   composition: applies middleware + calls feature.Register
│  └─ shared/                        Result, Error, primitives (referenced by all layers)
├─ pkg/                              public modules (usually empty — no public API surface)
├─ migrations/                       goose SQL
├─ test/integration/                 testcontainers-driven tests
├─ evals/                            LLM evals (if applicable)
└─ docs/
   ├─ product-overview.md
   ├─ projectStandards/              this folder
   ├─ exec-plans/                    approved implementation plans
   └─ evals/                         eval methodology + history
```

**Hard rules:**
- Domain has **zero** imports from `internal/api`, `internal/infra`, or third-party
  drivers (except `uuid`).
- App imports Domain + Shared only. App declares cross-layer interfaces (repository,
  adapters); Infra implements.
- API imports App (interfaces) + Shared + Gin. **API MUST NOT import `internal/infra`.**
- `cmd/api` is the only place everything composes together.

---

## 2. Feature folders at the API layer

Inspired by Vertical Slice Architecture — applied AT THE API BOUNDARY ONLY. The inner
core stays layered + CQRS.

```
internal/api/features/projects/
├─ create_project.go    request + response + handler (REPR style)
├─ get_project.go
├─ list_projects.go
├─ rename_project.go
├─ archive_project.go
└─ register.go          func Register(r *gin.RouterGroup, h Handlers)
```

`internal/api/router.go` enumerates the features (hand-maintained list — Go has no
reflection-based discovery; we trade a tiny coupling cost for compile-time correctness).

---

## 3. Domain layer — rich, mutable structs

Pattern: exported struct with unexported fields; private constructor checks invariants;
behaviour methods enforce invariants; identity equality.

See `.claude/rules/backend/domain-model.md` for the canonical template and rules. Key
decisions:

- **Base-class-free, no domain events.** Each entity owns its `id`/`tenantID`/equality.
  Domain events deferred until product needs an outbox.
- **UUIDv7 minted in the constructor** (`uuid.NewV7()` via `github.com/google/uuid`).
- **`time.Time` is UTC.** Constructors take `now time.Time` from a clock (never call
  `time.Now()` inside the domain).
- **Optimistic concurrency via PostgreSQL `xmin`** mapped to a `Version uint32` field.

---

## 4. App layer — use cases

Feature-sliced. Each use case is one file holding: command/query struct, response struct,
handler struct + constructor, `Handle(ctx, cmd) (*Response, error)`, optional
`validate(ctx, cmd) error`.

### 4.1 Validation — three distinct scopes

| Scope | Where | Validates | Failure → |
|---|---|---|---|
| **Contract** | API — Gin `binding:` tags on the request DTO | Shape, required, types, authz from JWT | 400 ProblemDetails (`urn:problem:validation`) |
| **Business** | App — `validate(ctx, cmd) error` in the use case | Rules needing data / external state ("name not in use", "buyer >=18") | `result.Validation({...})` → 400 |
| **Invariant** | Domain — inside `NewX(...)` / `<Entity>.<Method>(...)` | Object can never enter an invalid state | Returns typed sentinel; use case wraps to `result.Validation(...)` |

No FluentValidation-style library. Hand-rolled per scope.

### 4.2 Failure model — typed `Error` + RFC 9457 ProblemDetails

`internal/shared/result/`:

- **`*Error`** — Code, Message, Type (enum: Failure / Validation / NotFound / Conflict /
  Unauthorized / Forbidden), optional `Failures map[string][]string`, optional wrapped
  cause.
- **`Result[T]`** — value-or-error wrapper. Optional; reach for it when `(T, error)` is
  awkward (multi-step validation chains).
- **`internal/api/middleware.WriteProblem(c, err)`** — translates any error (typed or
  wrapped) into the right ProblemDetails JSON response.

**Every API failure → ProblemDetails.** No bare `c.AbortWithStatus(500)`; the
ProblemDetails middleware is the only response path for failures.

### 4.3 CQRS conventions

- **Commands mutate.** `{Verb}{Noun}Command` (`CreateProjectCommand`).
- **Queries read.** `Get{Noun}Query` / `List{Nouns}Query`.
- **Handlers return `(*Response, error)`** — never `Result[T]` at this seam.
- **One file per use case.**
- **No mediator library** — `useCase.Handle(ctx, cmd)` direct call from the Gin handler.
- **Transactions are decorator-owned**, not handler-owned. The decorator wraps every
  command handler in `ExecuteInTransaction(...)`; queries skip it.

See `.claude/rules/backend/cqrs.md` for the full template.

---

## 5. Infrastructure split

- **`internal/infra/persistence/<feature>/`** — pgx + sqlc repositories per aggregate.
- **`internal/infra/<adapter>/`** — every other external service (mail, object storage,
  identity, LLM provider, …). Each gets its own subdirectory.

Each adapter is wired in `cmd/api/main.go` via a `New<Adapter>(...)` constructor.

---

## 6. Persistence — pgx + sqlc on PostgreSQL

### 6.1 Stack

- **Driver**: `jackc/pgx/v5` (`pgxpool.Pool`).
- **Query layer**: `sqlc` — SQL in `*.sql` files, run `make sqlc`, get typed Go.
- **Migrations**: `pressly/goose/v3`, `*.up.sql` + `*.down.sql`.
- **Concurrency token**: PostgreSQL `xmin` (system column) → `uint32` Version field.
- **Keys**: UUIDv7 minted in the domain constructor (never DB-generated).
- **Timestamps**: `timestamptz` columns; all `time.Time` is UTC.

### 6.2 Repository pattern

Repository **per aggregate root** (write side only). Read-side queries can bypass the
repo and project straight to DTOs.

The repository takes a `ctx` and decides whether to use the pool or a transaction it
finds in context. The Unit of Work decorator places the tx in context; the repo's
`queries(ctx)` helper picks it up.

See `.claude/rules/backend/persistence.md` and the `sqlc-patterns` skill for the full
templates.

### 6.3 Tenancy — sqlc parameter + PG RLS backstop

- Every sqlc query targeting a tenant-scoped table takes `tenant_id` as a parameter.
- The generated Go method REQUIRES it — you can't forget.
- **PostgreSQL Row-Level Security** enabled on every tenant-scoped table; the UoW sets
  `app.tenant_id` GUC at the start of every transaction. App-level scoping + RLS = belt
  and braces.

### 6.4 PostgreSQL features worth adopting

- **`jsonb`** for raw payloads (provider responses, audit event bodies); indexable via
  GIN.
- **`citext`** for case-insensitive emails / identifiers.
- **Array types** for tags / scopes without a junction table.
- **Range types** for effective-dated rules.
- **Native `uuidv7()`** in PG 18 if you want DB-side generation (we don't — UUIDv7 is
  minted in the domain).

---

## 7. Unit of Work

Thin interface in `internal/app/`:

```go
type UnitOfWork interface {
    ExecuteInTransaction(ctx context.Context, fn func(ctx context.Context) error) error
}
```

Implementation in `internal/infra/persistence/uow.go`:
- Begins a tx, places it in a new context, runs `fn(txCtx)`, commits on nil error /
  rolls back otherwise.
- Sets `app.tenant_id` per transaction for RLS.
- Respects context cancellation: a cancelled tx rolls back.

A transaction decorator wraps every command handler at wiring time
(`cmd/api/main.go`); the handler stays clean.

---

## 8. Observability

- **slog** (JSON in prod, text in dev) — request_id, trace_id, span_id, tenant attached
  via middleware; pull the logger from context, never `slog.Default()` in a handler.
- **OTel traces** — `otelgin` middleware per request; custom spans for sub-operations
  (DB tx, external call, expensive computation). Parent-based sampling at 10% in prod.
- **OTel metrics** — RED on every endpoint (auto via `otelgin`), USE on every critical
  resource (pgx pool, cache, queue), custom domain counters where the spec calls for
  them.
- **Logs ↔ traces** correlated via `trace_id` / `span_id` in the structured logger.

See `observability-standards.md` and the `otel-instrumentation` skill.

---

## 9. What we deliberately do NOT adopt

- **An ORM** (GORM / ent / xorm). pgx + sqlc only.
- **A DI framework** (wire / fx / dig). Manual wiring in `cmd/api/main.go`.
- **A mediator library** (mediator / mediatr-go). Direct handler invocation.
- **A mock generator** (gomock / mockery). Hand-written fakes.
- **`UPPER_CASE` constants**, `Url` over `URL` (Go conventions matter).
- **`panic` for expected failures.** Errors are values.
- **`any` at boundaries.** Concrete types or generics.
- **Anemic domain models.** Domain has behaviour; DTOs live at the edges.

---

## 10. Open decisions (to track)

Track outstanding architectural questions here. Each gets an ID; resolved entries move
to `.claude/rules/backend/` once ratified.

| # | Decision | Recommendation | Status |
|---|---|---|---|
| O1 | Background bus / outbox? | Defer until a use case needs eventual consistency across boundaries | Open |
| O2 | Vector store for RAG (pgvector vs. dedicated)? | Default to pgvector — we're already on PG | Open until product needs RAG |
| O3 | gRPC parallel transport? | Defer until an internal consumer needs it | Open |

---

## Key sources

- pgx docs: https://pkg.go.dev/github.com/jackc/pgx/v5
- sqlc docs: https://docs.sqlc.dev/
- goose docs: https://pressly.github.io/goose/
- Gin docs: https://gin-gonic.com/docs/
- OpenTelemetry Go: https://opentelemetry.io/docs/languages/go/
- OWASP API Top 10: https://owasp.org/API-Security/editions/2023/en/0x00-header/
