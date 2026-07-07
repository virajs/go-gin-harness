---
description: Gin-specific conventions — middleware ordering, route registration, request binding, response writing, SSE streaming, graceful shutdown. Auto-loads when editing files under internal/api/.
paths:
  - "internal/api/**/*.go"
  - "cmd/api/**/*.go"
---

# Gin conventions

Authoritative refs: `.claude/rules/backend/api-design.md`, `docs/projectStandards/backend-architecture.md`,
[gin-gonic.com/docs](https://gin-gonic.com/docs/).

## Middleware order (load-bearing)

Order in `cmd/api/main.go` (or the router builder):

```go
r := gin.New()
r.Use(
    gin.Recovery(),               // 1. recover panics last; runs first in the chain
    middleware.RequestID(),       // 2. attach request id (and put it in slog logger)
    middleware.SlogLogger(),      // 3. structured request log (in + out) keyed on request id
    otelgin.Middleware(svcName),  // 4. OTel span per request
    middleware.Timeout(15 * time.Second), // 5. per-request deadline (context.WithTimeout)
    middleware.Auth(),            // 6. JWT / session → claims into context
    middleware.Tenancy(),         // 7. derive tenant_id from claims; attach to context
    middleware.ProblemDetails(),  // 8. translate panics / un-typed errors into ProblemDetails
)
```

**Why this order:**
- Recovery first → it catches panics from every later middleware.
- RequestID before logger → the log carries the id.
- Logger before otel → log + trace correlated by request id (slog carries trace id too).
- Timeout before auth → unauth'd requests still get bounded.
- Auth before tenancy → tenancy reads claims.
- ProblemDetails last in `Use` → it sees every error from every prior layer.

## Route registration

- **Feature folders**: `internal/api/features/<feature>/<usecase>.go`. One file per use case:
  ```go
  package projects
  // CreateProjectRequest / CreateProjectResponse — bound types
  // RegisterCreate(r *gin.RouterGroup, h *Handlers) — wiring
  // createHandler — the actual function
  ```
- **Auto-registration**: each feature exposes a `Register(r *gin.RouterGroup, deps Dependencies)`
  function. `internal/api/router.go` enumerates the features (a hand-maintained list — Go has
  no reflection-based discovery; we trade a tiny coupling cost for compile-time correctness).
- **Route groups**: each feature gets its own group with shared prefix + middleware:
  ```go
  v1 := r.Group("/v1")
  projectsGroup := v1.Group("/projects", middleware.AuditLog("projects"))
  projects.Register(projectsGroup, deps)
  ```
- **No business logic in `router.go`** — wiring only.

## Request binding

- **Bind to DTOs, never to domain entities.** Overposting (a request setting `tenant_id`
  or `is_admin`) is the canonical example of why.
- Use `c.ShouldBindJSON(&req)` (returns an error) — never `c.BindJSON` (which writes a 400
  to the response and continues; surprises waiting to happen).
- Tag validation lives in `go-playground/validator` tags on the DTO:
  ```go
  type CreateProjectRequest struct {
      Name string `json:"name" binding:"required,min=1,max=128"`
  }
  ```
  This is **shape validation only** (the contract scope). Business rules go in the use-case
  validator; invariants go in the domain.
- On bind failure, render a `urn:problem:validation` ProblemDetails (not Gin's default 400):
  ```go
  if err := c.ShouldBindJSON(&req); err != nil {
      problem.WriteValidation(c, err)
      return
  }
  ```

## Response writing

- **Success**: `c.JSON(http.StatusCreated, resp)` or `c.JSON(http.StatusOK, resp)`. Use the
  typed response struct (`CreateProjectResponse`), never an `gin.H` literal — that's how
  fields silently drift from the documented contract.
- **Failure**: write through the ProblemDetails mapper. Never `c.AbortWithStatus(500)` —
  that bypasses the contract.
- **`c.Error(err)` + return** is the pattern for surfacing errors to the ProblemDetails
  middleware: the handler stays small; the middleware does the mapping in one place.

## SSE / streaming

- Set `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`.
- Flush after each event: `c.Writer.Flush()` (Gin's writer implements `http.Flusher`).
- Honor cancellation: select on `c.Request.Context().Done()` and break the loop.
- Emit errors as SSE error frames (not HTTP status changes — the status is already 200):
  ```
  event: error
  data: {"code":"upstream_failed","message":"..."}
  ```
- For LLM token streaming, the upstream call also takes the request context; cancelling the
  client closes the upstream.

## Graceful shutdown

`cmd/api/main.go` must implement this pattern (the harness's bootstrap will scaffold it):

```go
// Config from environment (12-factor). PORT + DATABASE_URL come from the per-worktree .env
// in local dev (scripts/worktree.sh) and from the platform in prod. Never hardcode them.
port := os.Getenv("PORT")
if port == "" {
    port = "8080" // default when not in a worktree / no .env
}
srv := &http.Server{Addr: ":" + port, Handler: r, ReadHeaderTimeout: 10 * time.Second}
go func() {
    if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
        slog.Error("server failed", "err", err)
    }
}()

ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()
<-ctx.Done()

shutdownCtx, cancel := context.WithTimeout(context.Background(), 30 * time.Second)
defer cancel()
if err := srv.Shutdown(shutdownCtx); err != nil { /* log */ }
// then close DB pool, OTel exporters, etc.
```

- `ReadHeaderTimeout` is mandatory (slowloris defense; `gosec` will warn if missing).
- Drain order: stop accepting → in-flight finish (up to shutdown deadline) → close DB pool
  → flush OTel → exit.

## Config from environment (the worktree contract)

`cmd/api` reads its runtime config from the environment — never hardcode ports or DSNs:

- **`PORT`** — the HTTP listen port; default `8080` when unset.
- **`DATABASE_URL`** — the Postgres DSN; no default in prod (fail-closed if unset).

This is what makes **isolated dev environments** work: `scripts/worktree.sh` generates a
per-worktree `.env` with a unique `PORT` and a `DATABASE_URL` pointing at that worktree's
own Postgres, and the `Makefile` exports it to `make run`/`make dev`. Two worktrees run the
same code on different ports against different databases, no code change. Integration tests
are unaffected — they inject their own testcontainers DSN and use `httptest` (random ports).

## Things to avoid in Gin

- **`c.Request.Body` after binding** — Gin reads it once. Use a body-recorder middleware if
  you must capture it (for audit logging), and capture *before* the handler runs.
- **Middleware that swallows errors silently** — every middleware either passes the error
  via `c.Error(err)` and `return`, or recovers explicitly.
- **`c.MustGet(key)`** — panics on missing key, which the recovery middleware turns into a
  500. Use `c.Get(key)` and handle the missing case.
- **Storing per-request state in package globals or singletons** — pass it via context keys.
  Use a small, typed key:
  ```go
  type ctxKey int
  const tenantKey ctxKey = iota
  func TenantFrom(ctx context.Context) (TenantID, bool) { … }
  ```
- **`gin.SetMode(gin.ReleaseMode)` left to default at runtime** — set explicitly based on
  `APP_ENV`, never via init().

## What to verify after a Gin change

```bash
go build ./...
go vet ./...
golangci-lint run ./internal/api/...
go test -race -count=1 ./internal/api/...
# Integration tests if the change affects routes:
go test -race -tags=integration ./test/integration/...
```
