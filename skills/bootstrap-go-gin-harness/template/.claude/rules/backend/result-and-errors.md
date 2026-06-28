---
description: Result[T] + typed Error + RFC 9457 ProblemDetails — the failure model from handler to API edge. Auto-loads on internal/**/*.go.
paths:
  - "internal/**/*.go"
---

# Result and errors

Authoritative refs: `result-pattern` skill, `docs/projectStandards/backend-architecture.md`.

## The shape

`internal/shared/result/` declares:

```go
package result

// Result wraps a value-or-error in a way that's friendlier than (T, error) at the API edge
// and at error-rich validation paths.
type Result[T any] struct {
    value T
    err   error
}

func Ok[T any](v T) Result[T]      { return Result[T]{value: v} }
func Err[T any](err error) Result[T] { return Result[T]{err: err} }

func (r Result[T]) Value() (T, bool) { return r.value, r.err == nil }
func (r Result[T]) Err() error       { return r.err }

// Match — collapse to one of two functions.
func Match[T, R any](r Result[T], ok func(T) R, fail func(error) R) R {
    if r.err != nil { return fail(r.err) }
    return ok(r.value)
}
```

In practice, **handlers return `(*Response, error)`** — not `Result[T]`. The `Result[T]`
shape is for collecting multi-error validation chains and the few cases where
"value-or-error" reads better than a return tuple. **The error path is where the typed
hierarchy lives.**

## Typed errors

```go
// Type — drives HTTP status mapping.
type Type int

const (
    TypeFailure      Type = iota // 500 — unexpected
    TypeValidation              // 400
    TypeNotFound                // 404
    TypeConflict                // 409
    TypeUnauthorized            // 401
    TypeForbidden               // 403
)

// Error — the canonical use-case error.
type Error struct {
    Code     string              // stable identifier ("project.not_found")
    Message  string              // human-readable
    Type     Type                // status mapping
    Failures map[string][]string // field -> messages, for Validation only
    Wrapped  error               // for errors.Unwrap (cause chain)
}

func (e *Error) Error() string  { return e.Message }
func (e *Error) Unwrap() error  { return e.Wrapped }

// Constructors.
func NotFound(code, msg string) *Error    { return &Error{Code: code, Message: msg, Type: TypeNotFound} }
func Validation(failures map[string][]string) *Error {
    return &Error{Code: "validation", Message: "validation failed", Type: TypeValidation, Failures: failures}
}
func Conflict(code, msg string) *Error    { return &Error{Code: code, Message: msg, Type: TypeConflict} }
func Unauthorized(code, msg string) *Error { return &Error{Code: code, Message: msg, Type: TypeUnauthorized} }
func Forbidden(code, msg string) *Error   { return &Error{Code: code, Message: msg, Type: TypeForbidden} }
func Failure(code, msg string, cause error) *Error {
    return &Error{Code: code, Message: msg, Type: TypeFailure, Wrapped: cause}
}
```

## At the use-case boundary

```go
func (h *GetProjectHandler) Handle(ctx context.Context, q GetProjectQuery) (*ProjectResponse, error) {
    p, err := h.repo.Load(ctx, q.TenantID, q.ID)
    if errors.Is(err, projects.ErrNotFound) {
        return nil, result.NotFound("project.not_found",
            fmt.Sprintf("project %s not found", q.ID))
    }
    if err != nil {
        return nil, result.Failure("project.load_failed", "failed to load project", err)
    }
    return toResponse(p), nil
}
```

- **Expected failures** → typed `*result.Error` constructors. The API layer maps them.
- **Unexpected failures** (DB down, OOM) → wrap with `result.Failure(..., cause)` and let
  the API mapper render 500.
- **Domain invariant violations** (constructor or method returned `ErrInvalidName`) →
  `result.Validation({"name": ["invalid"]})` OR wrap as a generic 400 if there's no field
  context. Don't leak raw domain sentinel codes to the client.

## At the API edge — RFC 9457 ProblemDetails

`internal/api/middleware/problem_details.go` (or `internal/shared/result/http.go`) maps the
typed error to a ProblemDetails JSON response:

```go
// Map writes the appropriate ProblemDetails response for any error.
func Map(c *gin.Context, err error) {
    var rerr *result.Error
    if errors.As(err, &rerr) {
        switch rerr.Type {
        case result.TypeValidation:
            writeJSON(c, http.StatusBadRequest, problem.Validation(c, rerr))
            return
        case result.TypeNotFound:
            writeJSON(c, http.StatusNotFound, problem.From(c, rerr, http.StatusNotFound))
            return
        case result.TypeConflict:
            writeJSON(c, http.StatusConflict, problem.From(c, rerr, http.StatusConflict))
            return
        case result.TypeUnauthorized:
            writeJSON(c, http.StatusUnauthorized, problem.From(c, rerr, http.StatusUnauthorized))
            return
        case result.TypeForbidden:
            writeJSON(c, http.StatusForbidden, problem.From(c, rerr, http.StatusForbidden))
            return
        }
    }
    // Unknown / unexpected.
    slog.ErrorContext(c.Request.Context(), "unhandled error", "err", err)
    writeJSON(c, http.StatusInternalServerError, problem.Internal(c, err))
}
```

ProblemDetails JSON shape (RFC 9457):

```json
{
  "type":     "urn:problem:project-not-found",
  "title":    "Project not found",
  "status":   404,
  "detail":   "project 01HN... not found",
  "instance": "/v1/projects/01HN...",
  "code":     "project.not_found",
  "trace_id": "..."
}
```

Validation responses include `failures`:

```json
{
  "type":   "urn:problem:validation",
  "title":  "Validation failed",
  "status": 400,
  "failures": { "name": ["already in use"] }
}
```

## Hard rules

- **Never `errors.New("…")` for a client-visible failure.** Use a typed sentinel or a
  `*result.Error` constructor.
- **Wrap, don't replace.** `fmt.Errorf("loading project: %w", err)` preserves the chain so
  `errors.Is` / `errors.As` work all the way up.
- **`errors.Is(err, ErrFoo)` to match sentinels; `errors.As(err, &target)` to extract typed
  errors.** Never compare with `==` (breaks under wrapping).
- **No `errors.New` inside hot paths** — they allocate. Use package-level sentinels.
- **The mapper handles the chain.** A wrapped `*result.Error` deep in a `fmt.Errorf` chain
  still gets mapped — `errors.As` finds it.
- **Never include secrets / PII in `Error.Message`.** The message is rendered to the client;
  the wrapped cause stays server-side (logged in `slog.Error`, not surfaced to the API).
- **Every API failure renders as ProblemDetails.** No bare `c.AbortWithStatus(500)` —
  always go through the mapper.
- **`internal/shared` MUST NOT import `internal/api` or third-party HTTP libs.** The
  ProblemDetails mapper itself lives in `internal/api`; `internal/shared/result` only
  exposes the typed error.

## Composition helpers (when they pull weight)

```go
// Then — chain a fallible step; short-circuit on error.
func Then[T, R any](r Result[T], f func(T) Result[R]) Result[R] {
    if r.err != nil { return Err[R](r.err) }
    return f(r.value)
}

// Map — transform the value; preserve error.
func Map[T, R any](r Result[T], f func(T) R) Result[R] {
    if r.err != nil { return Err[R](r.err) }
    return Ok(f(r.value))
}
```

Use these when the alternative is deeply nested `if err != nil { return … }`. **Don't
introduce them speculatively** — they earn their keep at 3+ fallible-step chains.

## What we don't do

- **No bare `errors.New` for typed failure paths.** Always wrap with `result.X(...)`.
- **No `panic(err)` for expected failure paths.** The `gin.Recovery` middleware will catch
  it and render 500, but the caller's intent ("this can fail") is lost.
- **No `interface{}` payloads on `*Error`.** Strongly typed `Failures map[string][]string`
  is enough for validation; anything more elaborate is a code smell.
- **No "monadic Result" everywhere.** Go is not Rust. `(T, error)` is idiomatic; `Result[T]`
  is a tool for specific cases.
