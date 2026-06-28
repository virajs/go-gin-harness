---
name: result-pattern
description: Implement or use Result[T] + typed Error — return typed errors from handlers, build Error values, compose with Map/Then/Match, catch domain sentinels into Result, map to RFC 9457 ProblemDetails. Use when adding an operation that can fail or wiring an endpoint's error contract.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill
---

# Use the Result[T] + Error pattern

Source of truth: `.claude/rules/backend/result-and-errors.md`,
`docs/projectStandards/backend-architecture.md`.

## Concepts

- **`*result.Error`** — the canonical typed error for client-visible failures. Carries
  `Code` (stable identifier), `Message` (human-readable), `Type` (drives HTTP status),
  optional `Failures` (field → messages, for Validation), and a wrapped cause.
- **`Result[T]`** — value-or-error wrapper. Used when collecting multi-step validation or
  when `(T, error)` becomes awkward. **Most code returns `(*T, error)`** — `Result[T]` is
  for the cases where it's clearly better.
- **API mapper** — `internal/api/middleware.WriteProblem(c, err)` translates any error
  (typed `*result.Error`, wrapped, or generic) into the right ProblemDetails response.

## Returning typed errors from a handler

```go
func (h *GetProjectHandler) Handle(ctx context.Context, q GetProjectQuery) (*ProjectResponse, error) {
    p, err := h.repo.Load(ctx, q.TenantID, q.ID)
    switch {
    case errors.Is(err, projects.ErrNotFound):
        return nil, result.NotFound("project.not_found", fmt.Sprintf("project %s not found", q.ID))
    case err != nil:
        return nil, fmt.Errorf("loading project: %w", err)
    }
    return toResponse(p), nil
}
```

- **Expected failure → typed `result.X(...)`** constructor.
- **Unexpected failure → `fmt.Errorf("...: %w", err)`** — preserves the chain so logging
  has the cause, but the mapper renders a generic 500.

## Validation

```go
func (h *CreateProjectHandler) validate(ctx context.Context, cmd CreateProjectCommand) error {
    failures := map[string][]string{}

    if exists, err := h.repo.NameExists(ctx, cmd.TenantID, cmd.Name); err != nil {
        return fmt.Errorf("checking name uniqueness: %w", err)
    } else if exists {
        failures["name"] = append(failures["name"], "already in use")
    }

    if len(cmd.Description) > 1000 {
        failures["description"] = append(failures["description"], "must be 1000 characters or fewer")
    }

    if len(failures) > 0 { return result.Validation(failures) }
    return nil
}
```

- **Collect all failures**, return one `result.Validation`. UX > "fix one, retry".
- **Field keys are JSON-shaped** (e.g. `"description"`, not `"Description"`) so the
  ProblemDetails response keys match the API contract.

## Mapping at the API edge

```go
// internal/api/middleware/problem_details.go

func WriteProblem(c *gin.Context, err error) {
    var rerr *result.Error
    if errors.As(err, &rerr) {
        switch rerr.Type {
        case result.TypeValidation:
            c.JSON(http.StatusBadRequest, problemValidation(c, rerr))
        case result.TypeNotFound:
            c.JSON(http.StatusNotFound, problem(c, rerr, http.StatusNotFound))
        case result.TypeConflict:
            c.JSON(http.StatusConflict, problem(c, rerr, http.StatusConflict))
        case result.TypeUnauthorized:
            c.JSON(http.StatusUnauthorized, problem(c, rerr, http.StatusUnauthorized))
        case result.TypeForbidden:
            c.JSON(http.StatusForbidden, problem(c, rerr, http.StatusForbidden))
        default:
            slog.ErrorContext(c.Request.Context(), "unhandled result.Error", "err", err)
            c.JSON(http.StatusInternalServerError, problem(c, rerr, http.StatusInternalServerError))
        }
        return
    }
    // Plain error — unexpected.
    slog.ErrorContext(c.Request.Context(), "unhandled error", "err", err)
    c.JSON(http.StatusInternalServerError, problemInternal(c, err))
}
```

- `errors.As` walks the chain — a typed `*result.Error` wrapped by `fmt.Errorf("…: %w", …)`
  still maps correctly.
- The handler doesn't have to unwrap. It returns whatever error it has; the mapper
  handles the chain.

## Composition (Then / Map)

When you have a 3+ step fallible chain and `if err != nil { return … }` pyramids ugly:

```go
// internal/shared/result/composition.go

func Then[T, R any](r Result[T], f func(T) Result[R]) Result[R] {
    if r.err != nil { return Err[R](r.err) }
    return f(r.value)
}

func Map[T, R any](r Result[T], f func(T) R) Result[R] {
    if r.err != nil { return Err[R](r.err) }
    return Ok(f(r.value))
}
```

Use sparingly. Reach for them when:
- You have 3+ sequential fallible steps that all return the same error path.
- The reader benefits more from "pipeline" reading than the implementation buys with the
  generic indirection.

Otherwise, plain `(T, error)` is more idiomatic Go.

## Wrapping domain sentinels

The domain returns un-wrapped sentinels (`projects.ErrInvalidName`). The use case wraps:

```go
p, err := projects.New(cmd.TenantID, cmd.Name, h.clock.Now())
if err != nil {
    // Invariant-violation → 400 with the domain code as the field message.
    return nil, result.Validation(map[string][]string{
        "name": {err.Error()}, // or a sanitized human-readable message
    })
}
```

For complex multi-invariant entities, build a small map at the use-case layer that
translates each sentinel to the right field name:

```go
var domainErrorMap = map[error]struct{ field, msg string }{
    projects.ErrInvalidName: {field: "name", msg: "invalid name"},
    // ...
}
```

Don't expose raw `projects.ErrXxx` codes to the API — they're internal sentinels.

## Hard rules

- **Never `errors.New(...)` for a client-visible failure.** Use `result.X(...)`.
- **`errors.Is` for sentinels, `errors.As` for typed errors.** Never `==`.
- **Wrap, don't replace** — `fmt.Errorf("...: %w", err)`.
- **No secrets / PII in `Error.Message`** — that's rendered to the client. Wrapped causes
  stay server-side.
- **`internal/shared` is API-free.** The mapper lives in `internal/api`. `internal/shared/
  result` exposes the typed error and the (optional) `Result[T]` shape only.
- **Logging is the handler / middleware's responsibility**, not the mapper's. The mapper
  may emit one `slog.Error` for unhandled errors.

## Common mistakes (don't)

- Returning `result.NotFound(...)` and then the API handler ALSO calling
  `c.JSON(404, ...)`. The handler returns the typed error; the mapper writes the response.
  Don't duplicate.
- Returning `error` as a value and then doing `if err != nil { return nil, err }` 8 levels
  deep. If the chain has > 3 steps, reach for `Then` / `Map` or factor a helper.
- `nil, nil` returns — the `nilnil` linter catches it. A function returns either a value
  or an error, never both nil.
- `panic(err)` for "this shouldn't happen". If it shouldn't happen, prove it can't (type
  system, invariant); if it can happen, return the error.
