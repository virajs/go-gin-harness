---
description: CQRS conventions — commands mutate, queries read, one use case per file, handler returns Result[T]. Auto-loads on internal/app/**.
paths:
  - "internal/app/**/*.go"
---

# CQRS (Go)

Authoritative refs: `add-command` + `add-query` skills, `result-pattern` skill,
`docs/projectStandards/backend-architecture.md`.

## Shape

Each use case is **one file** in `internal/app/<feature>/`. The file contains:

- The request struct (`{Verb}{Noun}Command` or `Get{Noun}Query`)
- The response struct (`{Noun}Response`) — if non-trivial
- The handler struct (holds dependencies) + constructor
- The handler method (`Handle(ctx, cmd) (*Response, error)` or returning `Result[T]`)
- The validator (if non-trivial)

Example: `internal/app/projects/create_project.go`

```go
package projects

import (
    "context"
    "errors"
    "time"

    "{{ProjectName}}/internal/domain/projects"
    "{{ProjectName}}/internal/shared/result"
)

// Command — mutates state. Use the verb in the name.
type CreateProjectCommand struct {
    TenantID projects.TenantID
    Name     string
}

// Response — what the caller gets back.
type CreateProjectResponse struct {
    ID        projects.ID
    Name      string
    CreatedAt time.Time
}

// Handler — holds dependencies. Returned by NewCreateProjectHandler.
type CreateProjectHandler struct {
    repo  Repository
    clock Clock
}

func NewCreateProjectHandler(repo Repository, clock Clock) *CreateProjectHandler {
    if repo == nil  { panic("nil repo")  }  // genuinely unreachable; init bug
    if clock == nil { panic("nil clock") }
    return &CreateProjectHandler{repo: repo, clock: clock}
}

// Handle — the use case. Always (ctx, cmd) first; always returns (Response, error)
// — error is the use-case-level Result; the API layer maps it to ProblemDetails.
func (h *CreateProjectHandler) Handle(ctx context.Context, cmd CreateProjectCommand) (*CreateProjectResponse, error) {
    // 1. business validation (if any) — see validator section
    if err := validateCreateProject(cmd); err != nil {
        return nil, err
    }

    // 2. domain object construction (invariants enforced inside)
    p, err := projects.New(cmd.TenantID, cmd.Name, h.clock.Now())
    if err != nil {
        return nil, result.AsError(err) // map domain errors to typed Result errors
    }

    // 3. persist
    if err := h.repo.Save(ctx, p); err != nil {
        return nil, err // already wrapped at repo boundary
    }

    return &CreateProjectResponse{
        ID:        p.ID(),
        Name:      p.Name(),
        CreatedAt: p.CreatedAt(),
    }, nil
}
```

## Naming

| Kind | Pattern | Example |
|---|---|---|
| Command (mutates) | `{Verb}{Noun}Command` | `CreateProjectCommand`, `ArchiveProjectCommand`, `RenameProjectCommand` |
| Query (reads only) | `Get{Noun}Query` / `List{Nouns}Query` / `Search{Nouns}Query` | `GetProjectQuery`, `ListProjectsQuery` |
| Handler | `{Type}Handler` | `CreateProjectHandler`, `GetProjectHandler` |
| Method | `Handle` (always) | `(h *CreateProjectHandler) Handle(ctx, cmd) (...)` |
| Response | `{Noun}Response` / `{Verb}{Noun}Response` | `ProjectResponse`, `CreateProjectResponse` |

## Conventions

- **Commands mutate; queries read.** A query handler that writes is a bug. (Convention; not
  machine-enforced.)
- **One use case per file.** The handler, its types, and its validator live together.
- **Handler returns `(*Response, error)`** — error is the use-case-level signal; the API
  layer maps to ProblemDetails. For multi-error / validation outputs, use the `Result[T]`
  + `Error` types in `internal/shared/result/`.
- **No transactions inside the handler.** A transaction decorator (or middleware-style
  interceptor) wraps every command handler; the handler itself just calls repo methods.
  See `persistence.md` for the pattern.
- **`ctx context.Context` is the first parameter** of `Handle` and every method it calls.
- **Validation = three scopes** (see `validation-scopes` skill):
  - **Shape** — Gin's `binding` tags on the API DTO
  - **Business** — `validateXxx` helper in this file (or a `XxxValidator` struct if it has
    dependencies)
  - **Invariant** — inside the domain constructor / methods, returns typed sentinel errors
- **Errors:**
  - Validation failures: typed `result.ValidationError{Failures: ...}` (maps to 400)
  - Not-found: typed `result.NotFoundError{...}` (maps to 404)
  - Unauthorized: `result.UnauthorizedError{...}` (maps to 401)
  - Forbidden: `result.ForbiddenError{...}` (maps to 403)
  - Conflict: `result.ConflictError{...}` (maps to 409)
  - Domain invariant violation: wrap the domain sentinel with `result.AsError(err)` and
    the mapper renders it as 400 with the sentinel's code.
- **No throwing/panic for expected failures.** A "project not found" returns an error;
  never panics.
- **No business logic in the API layer.** If you find yourself doing it in `internal/api/
  features/...`, move it to `internal/app/<feature>/`.
- **No raw `pgx` calls in `internal/app/`.** That's the repository's job.

## The `Repository` interface (per feature)

Lives in the same package as the handlers — the handlers declare what they need:

```go
// internal/app/projects/repository.go
package projects

import (
    "context"
    "{{ProjectName}}/internal/domain/projects"
)

type Repository interface {
    Save(ctx context.Context, p *projects.Project) error
    Load(ctx context.Context, tenant projects.TenantID, id projects.ID) (*projects.Project, error)
    List(ctx context.Context, tenant projects.TenantID, page Page) ([]*projects.Project, error)
}

type Page struct {
    Limit  int32
    Cursor string  // opaque token; usually a base64-encoded composite of (created_at, id)
}
```

The implementation lives in `internal/infra/persistence/projects/repository.go` — see
`persistence.md`.

## Validators

For trivial shape rules → Gin tags. For business rules (needs the repository or external
state) → a `validateXxx(ctx, cmd) error` function in the use-case file:

```go
func (h *CreateProjectHandler) Handle(ctx context.Context, cmd CreateProjectCommand) (...) {
    if err := h.validateCreate(ctx, cmd); err != nil { return nil, err }
    // ...
}

func (h *CreateProjectHandler) validateCreate(ctx context.Context, cmd CreateProjectCommand) error {
    exists, err := h.repo.NameExists(ctx, cmd.TenantID, cmd.Name)
    if err != nil { return err }
    if exists { return result.ValidationError{Failures: map[string][]string{"name": {"already in use"}}} }
    return nil
}
```

When a validator has multiple steps, prefer collecting errors with `errors.Join` (or
`Result[T]`'s collector helpers) and returning all failures at once — better UX than
"fix one, retry, fix the next".

## Transactions

A transaction decorator wraps every command handler — see `persistence.md` for the pattern.
Handlers DO NOT begin / commit / rollback. They just call repo methods; the decorator owns
the transaction lifecycle and rolls back on error.

## Background work — NOT a command

If the operation is asynchronous (queue worker, scheduled job, retry-after-failure), it is
NOT a CQRS command. Put it under `internal/app/<feature>/jobs/` or a dedicated worker
package, with its own naming (`...Job` / `...Worker`). Confusing background work with use
cases is the #1 CQRS smell.

## What we don't do

- **No mediator library.** The handler is called directly from the Gin handler with the
  command struct. A mediator (MediatR-style) requires reflection or codegen — not worth it
  for the level of orchestration we need.
- **No generic `Handle(interface{})` dispatcher.** Each handler is typed; the API layer
  picks the right one.
- **No "service" between the handler and the repository.** The handler IS the service.
- **No anemic command structs with logic methods.** Commands are data; handlers have the
  logic.
