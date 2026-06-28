---
name: validation-scopes
description: Place validation in the correct one of three scopes — API contract (Gin binding tags), Application business (use-case validator), Domain invariants (constructor / method). Use when adding any validation / guard and deciding where it belongs.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill
---

# Validation scopes

Three scopes; each rule lives in **exactly one** of them. The scope is determined by what
the rule needs to know:

| Scope | Where | Needs | Returns | Example |
|---|---|---|---|---|
| **Shape (contract)** | API layer — `internal/api/features/<feature>/<usecase>.go`, via Gin `binding` tags | The request alone + JWT claims | 400 ProblemDetails (Gin's binding error → `WriteBindError`) | `Name` is required, max 128 chars; `Role` must be in `oneof=admin user` |
| **Business** | App layer — `internal/app/<feature>/<usecase>.go`, in `validate(ctx, cmd)` | The DB, an external service, OR cross-field rules that can't be expressed as a tag | 400 ProblemDetails via `result.Validation({...})` | "Name not already in use", "buyer is at least 18 for an alcohol purchase" |
| **Invariant** | Domain layer — inside `New<Entity>(...)` / `<Entity>.<Method>(...)` | Only the entity's own state | Typed sentinel error (`ErrXxx`); the use case wraps to `result.Validation(...)` | "Project name is 1–128 chars", "Archived project can't be renamed" |

## How to choose

Ask, in order:

1. **Can the request alone (+ JWT) decide the rule?** If yes → **shape**. Gin tag.
2. **Does the rule need to read the DB or call an external service?** If yes → **business**.
3. **Is the rule about the entity's own state (a fact that must always be true)?** → **invariant**.

If two seem to apply, prefer **invariant** (defence in depth: even if the business
validator misses, the domain refuses).

## Shape (Gin tags)

```go
type CreateProjectRequest struct {
    Name        string `json:"name" binding:"required,min=1,max=128"`
    Description string `json:"description,omitempty" binding:"max=1000"`
    Visibility  string `json:"visibility,omitempty" binding:"oneof=public private internal"`
}
```

- `required`, `min`, `max`, `oneof`, `email`, `url`, `uuid`, `len`, `lte`, `gte`, etc.
- Tag-validation runs in `c.ShouldBindJSON(&req)`; on error, `middleware.WriteBindError`
  translates the validator output into a `result.Validation` ProblemDetails.
- **No DB calls in shape validation.** No interpolated values from another request. Pure
  shape.
- **`required` on a non-pointer field**: zero value (`""`, `0`, `false`) fails validation —
  that's intentional. Use a pointer if you need to distinguish "absent" from "zero".

## Business (use-case validator)

```go
func (h *CreateProjectHandler) validate(ctx context.Context, cmd CreateProjectCommand) error {
    failures := map[string][]string{}

    exists, err := h.repo.NameExists(ctx, cmd.TenantID, cmd.Name)
    if err != nil { return fmt.Errorf("checking name uniqueness: %w", err) }
    if exists { failures["name"] = append(failures["name"], "already in use") }

    if len(failures) > 0 { return result.Validation(failures) }
    return nil
}
```

- Runs after binding, before the use case mutates anything.
- Collects all errors and returns one `result.Validation` (better UX than "fix one, retry").
- May read from the repo. May call external services (with context propagation + timeout).

## Invariant (domain)

```go
// internal/domain/projects/project.go

func New(tenant TenantID, name string, now time.Time) (*Project, error) {
    if tenant == "" { return nil, ErrTenantRequired }
    if err := validateName(name); err != nil { return nil, err }
    return &Project{...}, nil
}

func validateName(name string) error {
    if name == "" { return ErrInvalidName }
    if len(name) > 128 { return ErrInvalidName }
    return nil
}

var (
    ErrTenantRequired = errors.New("tenant required")
    ErrInvalidName    = errors.New("invalid project name")
    ErrProjectArchived = errors.New("project archived")
)
```

- The domain refuses to enter an invalid state. Returns a typed sentinel; the use case
  catches it and translates to `result.Validation`.
- **Defence in depth.** Even if shape + business validators are skipped or buggy, the
  domain layer is the last line. Tests for invariants are some of the highest-value tests
  in the codebase.

## Duplication is OK at the seams

A rule can legitimately exist in **shape** *and* **invariant** — they're enforcing the same
fact at different layers. The shape rule gives a fast 400 with a friendly message; the
invariant rule is the safety net. (`max=128` in the tag + `len(name) > 128` in the domain
is fine.)

A rule in **business** *and* **invariant** is also fine for the same reason.

A rule in **all three** is overkill — pick two.

## How to wire validate(ctx, cmd) in a handler

```go
func (h *CreateProjectHandler) Handle(ctx context.Context, cmd CreateProjectCommand) (*CreateProjectResponse, error) {
    if err := h.validate(ctx, cmd); err != nil { return nil, err }

    p, err := projects.New(cmd.TenantID, cmd.Name, h.clock.Now())
    if err != nil {
        // domain sentinel → translate to validation failure
        return nil, result.Validation(map[string][]string{"name": {err.Error()}})
    }
    if err := h.repo.Save(ctx, p); err != nil { return nil, fmt.Errorf("...: %w", err) }
    return &CreateProjectResponse{ID: p.ID()}, nil
}
```

## Common mistakes (don't)

- Putting business validation in the Gin handler (e.g. `if exists, _ := repo.X(...); exists { ... }`).
  Move to the use-case `validate(ctx, cmd)`.
- Skipping domain invariants because "the business validator covered it". The invariant is
  defence in depth — keep it.
- Duplicating shape rules in the business validator. If `binding:"max=128"` is there, don't
  re-check `len(name) > 128` in the use case (the binding already rejected it).
- A "validator object" in the API layer that re-runs the same business check the use case
  is about to do. Single source of truth: the use case.
- Returning multiple `result.Validation` calls from one handler. Collect into one map; return
  one error.

## Tests

- **Shape**: integration test that POSTs a bad payload and expects 400 with the right
  failure key.
- **Business**: unit test on the use-case handler with a fake repo that returns "name
  exists"; assert `result.Validation` with `"name"` key.
- **Invariant**: unit test on the domain constructor / method; assert the right sentinel
  error returns.
