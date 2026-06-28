---
description: Go coding conventions — formatting, idioms, error handling, concurrency, the standard library. Auto-loads when editing any .go file.
paths:
  - "**/*.go"
---

# Go conventions

Authoritative refs: `docs/projectStandards/coding-standards.md` and `.golangci.yml`.

## Formatting (machine-enforced)

- **gofumpt** (stricter gofmt) — run before every commit; the PostToolUse hook runs it after
  every Edit/Write.
- **goimports** — group: stdlib, third-party, local (`{{ProjectName}}`). `gci` enforces.
- **Tabs for indentation** (Go standard); 4-space equivalent in editors.
- One package per directory; package name matches the directory's last segment (lowercase,
  no underscores).
- File names: `snake_case.go`. Test files end in `_test.go`. Build tags on the first line:
  `//go:build integration`.

## Naming

| Symbol | Convention | Example |
|---|---|---|
| Exported type / function / method | PascalCase | `CreateProject`, `ProjectRepository` |
| Unexported type / function | camelCase | `parseURL`, `currentUser` |
| Interface | usually `er` suffix for single-method (`Reader`); descriptive PascalCase otherwise (`ProjectRepository`) | `Closer`, `ProjectQueryer` |
| Constant | PascalCase (exported) / camelCase (unexported) — **never `UPPER_CASE`** | `DefaultTimeout`, `maxRetries` |
| Acronym | preserve case as a unit: `URL`, `ID`, `HTTP`, `API` (not `Url`, `Id`) | `parseURL`, `userID` |
| Test function | `TestX_Y_Z` (subject_scenario_expectation) | `TestCreateProject_TenantMismatch_ReturnsForbidden` |
| Benchmark | `BenchmarkX_Y` | `BenchmarkCreateProject_LargeBody` |
| Receiver | short, consistent within a file (1–3 chars) | `p *Project` for `*Project` |

## Errors

- **Errors are values.** Return `error`; never `panic` for expected failures.
- **Wrap with context** via `fmt.Errorf("…: %w", err)` so callers can `errors.Is` / `errors.As`.
  Plain string concatenation discards the chain — `errorlint` catches it.
- **Typed sentinels** for failures the caller distinguishes:
  ```go
  var ErrProjectNotFound = errors.New("project not found")
  // …
  return fmt.Errorf("loading project %s: %w", id, ErrProjectNotFound)
  // caller:
  if errors.Is(err, ErrProjectNotFound) { … }
  ```
- **Typed `Error`** (in `internal/shared`) at the use-case ↔ API boundary so the API mapper
  can render RFC 9457 ProblemDetails. See `.claude/rules/backend/result-and-errors.md`.
- **No `nil, nil`.** A function that can return `(*T, error)` returns either a non-nil `T`
  or a non-nil `error`, never both nil. `nilnil` linter catches it.
- **`errors.Join`** for collecting multiple errors (validation) — preserves the chain.
- **`panic` only for unreachable / programmer-error conditions** (e.g. invariant violations
  in pure-domain factories *only when there is no recoverable path*). The runtime recovers
  via middleware; never rely on that for control flow.

## Context

- **`context.Context` is the first parameter** of every I/O function.
- **Never store** a context in a struct. Pass it through call chains. (`govet contextcheck`.)
- **Never `context.Background()` inside a request path.** Propagate the request's context
  all the way to pgx / external calls. `noctx` linter catches `http.Get` / `http.NewRequest`
  without a context.
- **Cancellation propagates downstream** — if the caller cancels, every blocking call must
  respect the cancellation (pgx pool acquire, http client, channel `select` with
  `ctx.Done()`).

## Concurrency

See `.claude/rules/concurrency.md` for the full set. Highlights:
- Every goroutine has an owner. `errgroup.Group` is the default fan-out primitive.
- `sync.WaitGroup` is allowed but be explicit about who calls `Done()` on every path.
- Mutexes: prefer `sync.RWMutex` for read-heavy maps; keep critical sections short; lock
  ordering documented when multiple are held.
- Channels: prefer unbuffered or capacity-1 — a buffer of 1000 is a code smell (queue
  hiding backpressure).
- Race detector on every `go test` (`-race` in the Makefile).

## Idioms

- **Constructors return `(*T, error)`** when validation can fail; `*T` directly when the
  type is trivial. The zero value is generally not used unless documented (e.g. `bytes.Buffer`).
- **Slices: preallocate where the length is known.** `make([]T, 0, knownLen)` then `append`.
  `prealloc` linter flags missed opportunities.
- **Maps: `m[k]` returns the zero value for a missing key** — explicit `_, ok := m[k]` when
  presence matters.
- **Iteration:** the `range` index/value pair makes a *copy*; mutate via index or pointer.
  Go 1.22+ scopes the loop variable per iteration — older versions don't (relevant when
  spawning goroutines in a loop).
- **`if err != nil` blocks** are part of Go's grammar; embrace them. Don't squash with
  `_ =` to silence the compiler.
- **Defer for cleanup, not control flow.** `defer rows.Close()` immediately after the
  `Query`; `defer tx.Rollback()` immediately after `Begin`. Linters: `sqlclosecheck`,
  `bodyclose`.
- **`io.ReadAll(body)` after closing the body** is a bug — read first, close later (and
  always close in a defer).
- **`time.Time` is UTC** in this repo. Use `time.Now().UTC()` if you ever need the wall
  clock; pgx + `timestamptz` columns do the right thing if the column is configured.

## What we DON'T use (without explicit, per-module approval)

- A logger other than `log/slog`. No `logrus`, no `zerolog`, no `zap` (slog is the stdlib
  successor as of Go 1.21).
- A web framework other than Gin.
- An ORM. `pgx` driver + `sqlc`-generated typed queries.
- A DI framework (wire / fx / dig) — manual constructor injection in `cmd/api/main.go`.
- A mock generator (`gomock`, `mockery`) — hand-write small interfaces and fakes.
- A validation library other than `go-playground/validator` (already implicit via Gin's
  binding).
- A new test library beyond `testing` + `testify` + `testcontainers-go` + stdlib `httptest`.

If you think you need one, STOP and propose it with a stdlib alternative.

## What gofumpt + golangci-lint can't enforce (review-enforced)

- The constructor + invariant pattern for entities (domain-model.md).
- The validation-scopes rule (which scope owns which check).
- Context propagation correctness (the linter catches obvious cases; the structural pattern
  isn't always machine-checkable).
- The "no `any` at boundaries" rule — `any` is sometimes legitimate (slog field values,
  JSON passthrough); review judges intent.
