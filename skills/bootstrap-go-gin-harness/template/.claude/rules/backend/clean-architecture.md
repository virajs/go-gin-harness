---
description: Layering and dependency direction — Domain ← App ← Infra ← API. Feature folders within layers. Interfaces only for cross-layer.
paths:
  - "internal/**/*.go"
  - "cmd/**/*.go"
  - "pkg/**/*.go"
---

# Clean architecture (Go)

## Layers and dependency direction

```
                +-------------------+
                |   internal/api    |  Gin handlers, middleware, routing  (composition root via cmd/api)
                +---------+---------+
                          | depends on
                          v
                +-------------------+
                | internal/infra    |  pgx + sqlc repos, external adapters (storage, mail, identity, LLM)
                +---------+---------+
                          | depends on
                          v
                +-------------------+
                |   internal/app    |  use cases (commands/queries + handlers) — declares interfaces it needs
                +---------+---------+
                          | depends on
                          v
                +-------------------+
                | internal/domain   |  rich entities + value objects + invariants  (zero imports from this repo)
                +-------------------+
                          ^
                          |
                +-------------------+
                | internal/shared   |  Result[T], Error, primitive types  (referenced from any layer)
                +-------------------+
```

**Hard rules:**
- `internal/domain` has **zero imports** from `internal/app`, `internal/infra`, `internal/api`.
- `internal/app` imports `internal/domain` + `internal/shared` only.
- `internal/infra` imports `internal/app` (for the interfaces it implements) + `internal/domain`
  + third-party drivers.
- `internal/api` imports `internal/app` (use case interfaces) + `internal/shared` + Gin.
  **`internal/api` MUST NOT import `internal/infra/persistence`** — only its interface in
  `internal/app`.
- `cmd/api/main.go` is the composition root; it imports everything and wires up DI.

Enforced by:
- Reading the diff; reviewers (architect-backend) flag violations.
- (Optional) `go-arch-lint` / `depguard` rules in `.golangci.yml` once the layout stabilizes.

## Feature folders inside each layer

Group by **feature**, never by technical convention. ✓ `domain/projects/project.go`,
`app/projects/create_project.go`, `infra/persistence/projects/repository.go`,
`api/features/projects/create_project.go`. ✗ `services/`, `repositories/`, `handlers/`.

Each feature carries its own:
- Domain entity(ies) + value objects
- Use-case commands / queries / handlers / validators
- Repository interface (declared in app/) + implementation (in infra/persistence/)
- API handler(s)

## Interfaces — only for cross-layer

**Cross-layer:** declare the interface in the consumer's layer; implement it in the
provider's layer.

- App declares `projects.Repository`; infra implements `projects.PgxRepository`.
- App declares `mail.Sender`; infra implements `mail.SmtpSender`.
- App declares `clock.Clock`; infra (or cmd/api wiring) implements `realClock`.

**Within a layer:** use concrete types. A helper that lives in `internal/app/projects` and
is consumed only inside `internal/app/projects` doesn't need an interface — adds ceremony
without enabling substitution.

Anti-pattern: "interface everything". A `UserDisplayNameResolver` interface with one
implementation and zero plans for a second is overhead.

## DI wiring

`cmd/api/main.go` is the composition root:

```go
// Construct from the outside in.
pool, err := pgxpool.New(ctx, dbURL)
if err != nil { log.Fatal(err) }
defer pool.Close()

projectsRepo := persistprojects.NewRepository(pool)
projectsApp  := projects.NewService(projectsRepo, clockwork.NewRealClock())

// Build the Gin router; pass services in as dependencies.
deps := api.Dependencies{Projects: projectsApp /* ..., */}
r    := api.NewRouter(deps)
```

- One `New<Feature>Service(...)` per feature in `internal/app/<feature>/`.
- One `New<Adapter>(...)` per adapter in `internal/infra/<adapter>/`.
- Constructors return `(*T, error)` when init can fail (e.g. DB connect); `*T` when trivial.
- No `init()` blocks for DI. Wire explicitly.

## What goes where (cheat sheet)

| You want to add… | Layer | Path |
|---|---|---|
| A new endpoint | API | `internal/api/features/<feature>/<usecase>.go` |
| A new use case (command/query + handler) | App | `internal/app/<feature>/<usecase>.go` |
| A new entity | Domain | `internal/domain/<feature>/<entity>.go` |
| A new repository | Interface in App (`internal/app/<feature>/repository.go`); impl in Infra (`internal/infra/persistence/<feature>/repository.go`) |
| A new external adapter (LLM, storage, mail) | Interface in App (`internal/app/<area>/<adapter>.go`); impl in Infra (`internal/infra/<adapter>/<adapter>.go`) |
| A new middleware | API | `internal/api/middleware/<name>.go` |
| A new migration | (top-level) | `migrations/NNNN_<name>.sql` |
| A typed sqlc query | (next to repo) | `internal/infra/persistence/<feature>/queries/<name>.sql` |
| A shared primitive (Result, Error, IDs) | Shared | `internal/shared/<name>.go` |

## What we don't do

- **No "service layer" between use cases and repositories.** The use-case handler IS the
  service — it orchestrates the repository + domain + maybe a clock and an external adapter.
  Adding an intermediate "service" duplicates the responsibility.
- **No anemic domain models.** A `Project` struct with public fields and zero methods is a
  data transfer object, not a domain entity. Move it to `internal/shared/dto` if that's
  what it is.
- **No `domain/` package importing third-party drivers.** Domain is pure Go and the stdlib.
  If a domain entity needs to compute time, inject the clock; if it needs an id, inject the
  id generator (or accept the id as a constructor argument).
- **No reflection-based wiring frameworks** (wire, fx, dig) until the wiring becomes a chore.
  Manual `cmd/api/main.go` scales to ~50 services.
