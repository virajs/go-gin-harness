# {{ProductName}} — Go coding standards

> The single source of truth for how we write Go in this repo. Most of this is
> machine-enforced via `golangci-lint`; the parts that aren't are called out explicitly
> as **convention (not enforced)** and are upheld by review.

**Baseline:** Go 1.24, strict from day one. Greenfield, so there's no legacy debt and
this is the cheapest time to adopt it.

## Where the rules live

| File | Enforces |
|---|---|
| `go.mod` | Module path, Go version, pinned dependency versions. |
| `.golangci.yml` | Linter suite (~25 linters) + per-rule severities + path-scoped excludes. **Warnings = errors.** |
| `.editorconfig` | Cross-stack formatting: charset, indent (tab for Go), final newline. |
| `Makefile` | Canonical entry points: `make ci` is the green-bar definition. |
| `sqlc.yaml` | SQL → typed Go generation. |
| `.air.toml` | Hot-reload config (dev only). |
| This document | The *why*, plus the conventions that no linter enforces. |

## Severity model

`golangci-lint run` fails the build on any finding. Linter severities in `.golangci.yml`
default to `error`. Two ways to suppress:

1. **Per-call-site suppression** with a justification (preferred):
   ```go
   //nolint:gocyclo // generated state machine; complexity is inherent
   func dispatch(s State) State { … }
   ```
   The `nolintlint` linter enforces: specific linter (not bare `//nolint`), `//`-comment,
   no leading space.
2. **Path-scoped exclude** in `.golangci.yml`'s `issues.exclude-rules` (rare; for
   genuinely generated code like `*.sql.go`).

**Tuning philosophy: maximalist, reactive.** Nothing pre-disabled. When a rule produces
a genuine false positive, suppress with justification.

## Formatting

- **gofumpt** — stricter gofmt. Run after every change (the PostToolUse hook does this
  automatically; `make fmt` is the manual command).
- **goimports** — group: stdlib, third-party, local (`{{ProjectName}}`). `gci` enforces.
- **Tab indentation** for Go (matches gofmt). 4-space equivalent in editors.
- **One package per directory**; package name = the directory's last segment (lowercase,
  no underscores).
- **File names** `snake_case.go`; test files `_test.go`; build tag on the first line.

## Architecture & type conventions

These encode our domain-modeling stance. Some are not machine-enforceable.

### Rich, mutable domain entities — not anemic structs

Entities and aggregates (e.g. `Project`, `Document`) are **exported structs with
unexported fields**:

- **Identity-based equality** (compare by id, not field-by-field).
- **Encapsulated state**: mutation only through methods that enforce invariants.
- **Invariants enforced inside methods** during state transitions — including the
  **tenancy invariant**: a persisted entity always carries `tenant_id` and never crosses
  tenant boundaries.

Anemic structs (public fields, no methods) are wrong for entities: they invite invariant
violations and offer no place for behaviour. **Convention (not enforced):** do not model
entities as plain DTOs.

### Where DTOs *are* allowed

- **Request / response structs** at the API boundary — public fields with JSON tags,
  bound by Gin.
- **Wire DTOs** for parsing provider responses — same pattern: "store raw, treat fields
  as optional."
- **sqlc-generated row types** — generated, not hand-written; treat as vendor.

DTOs appear at the edges (HTTP, DB, external services); entities are the inner core.

### Constructors, not zero values

Every entity has a `NewX(...) (*X, error)` constructor that mints the id (UUIDv7) and
validates invariants. The zero value of a domain type is **not** a valid instance —
treat it like a `nil` pointer.

### Dependency injection

Constructor injection only; no service locator. Services get explicit constructors that
take their dependencies as parameters. `cmd/api/main.go` is the composition root.

## Language & style (enforced by golangci-lint)

### Errors are values

- Return `error`; never `panic` for expected failures.
- **Wrap** with `fmt.Errorf("...: %w", err)` so callers can `errors.Is` / `errors.As`.
  Plain concatenation discards the chain — `errorlint` catches it.
- **Sentinels** for failures the caller distinguishes: package-level `var ErrFoo = errors.New("foo")`.
- **Typed `Error`** (`internal/shared/result/`) at the use-case ↔ API boundary so the
  mapper can render ProblemDetails.
- **No `nil, nil`** — `nilnil` linter catches it.
- **`panic` only for unreachable conditions** (init bugs, programmer errors). The runtime
  recovers via middleware; never rely on that for control flow.

### Context

- **`context.Context` first parameter** of every I/O function.
- **Never `context.Background()` in a request path.** Propagate the request's context.
  `noctx` catches obvious cases; `contextcheck` catches propagation gaps.
- **Never store context in a struct.** `govet` warns.
- **Always `defer cancel()`** after `context.WithTimeout` / `WithCancel`.

### Concurrency

- **Every goroutine has an owner** (errgroup, WaitGroup, channel close, or context).
- Bare `go func() { … }()` in a request handler = leak under load.
- See `.claude/rules/concurrency.md` for the full set.
- **Race detector mandatory** on every `go test`.

### `any` discipline

- **No `any` at boundaries.** Concrete types, or generic parameters.
- `any` only for genuinely heterogeneous payloads (`slog` field values, JSON passthrough).
- `interface{}{}` is the same as `any`; never use the old form in new code.

### Generics

- Use generics where they remove duplication AND the type set is well-defined.
  `result.Then[T, R]` is a fit.
- Don't generify everything. Many "generic" Go problems are better solved with interfaces
  or concrete types.

## Naming

| Symbol | Convention | Example |
|---|---|---|
| Exported type / function | PascalCase | `CreateProject`, `ProjectRepository` |
| Unexported type / function | camelCase | `parseURL`, `currentUser` |
| Single-method interface | `er` suffix | `Reader`, `Closer`, `Tracer` |
| Multi-method interface | descriptive PascalCase | `ProjectRepository` |
| Constant | PascalCase (exported), camelCase (unexported) — **never `UPPER_CASE`** | `DefaultTimeout` |
| Acronym | preserve case as a unit: `URL`, `ID`, `HTTP`, `API` | `parseURL`, `userID` |
| Test | `TestX_Y_Z` (subject_scenario_expectation) | `TestCreateProject_TenantMismatch_ReturnsForbidden` |
| Benchmark | `BenchmarkX_Y` | `BenchmarkCreateProject_LargeBody` |
| Receiver | short (1–3 chars), consistent per type | `p *Project` |

## What we DON'T use (without explicit, per-module approval)

- **A logger other than `log/slog`** (no logrus, zerolog, zap).
- **A web framework other than Gin** for HTTP. (gRPC / Connect — separate transport, see
  `cmd/grpc/`.)
- **An ORM.** pgx + sqlc only.
- **A DI framework** (wire / fx / dig) — manual constructor wiring scales to ~50 services.
- **A mock generator** (gomock / mockery) — hand-written fakes.
- **A validation library other than `go-playground/validator`** (Gin's default).
- **A new test library** beyond `testing` + `testify` + `testcontainers-go` + `httptest`.

If you think you need one, **STOP** and propose it with a stdlib alternative.

## Async discipline (convention — review-enforced)

- Never `_ = err` to silence the linter — handle the error.
- No `async void`-equivalent (Go has no async; goroutines are explicit).
- Thread `context.Context` through every async call chain.

## Changing a standard

This file IS the standard — edit it; don't work around it. A reactive linter suppression
needs the justification comment described above. A change to a genuine convention
(anything marked **convention**) is updated in this document in the same change so the
two never drift.

## See also

- `.claude/rules/go-conventions.md` (auto-loaded when editing `.go` — the enforceable
  distillation of this doc)
- `.claude/rules/backend/*.md` (per-domain conventions)
- `backend-architecture.md` (layering + persistence + CQRS rationale)
- `testing-standards.md`
