---
name: add-command
description: Author a CQRS command — Command struct + Handler + business validator + transaction. Returns (*Response, error) with typed Result errors. Use when adding a mutating use case in internal/app/<feature>/.
argument-hint: <Feature>/<Verb><Noun> (e.g. Projects/CreateProject)
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# Add a CQRS command

A **command** mutates state. Source of truth: `.claude/rules/backend/cqrs.md`,
`.claude/rules/backend/result-and-errors.md`, `.claude/rules/backend/tenancy.md`.

## Steps

1. **Confirm the domain exists.** The command will construct or mutate a domain entity —
   the entity must already be modeled (use `add-domain-entity` first if needed).

2. **Create the file** at `internal/app/<feature>/<verb_noun>.go`. One file holds the
   command struct + response struct + handler + validator:

   ```go
   package <feature>

   import (
       "context"
       "errors"
       "fmt"
       "time"

       domain<feature> "{{ProjectName}}/internal/domain/<feature>"
       "{{ProjectName}}/internal/shared/result"
   )

   // --- Command ---
   type <Verb><Noun>Command struct {
       TenantID domain<feature>.TenantID
       // ... payload fields
   }

   // --- Response ---
   type <Verb><Noun>Response struct {
       ID        domain<feature>.ID
       // ... fields the client needs back
   }

   // --- Handler ---
   type <Verb><Noun>Handler struct {
       repo  Repository       // declared in repository.go (same package)
       clock Clock            // declared in deps.go (same package), implemented in infra/
   }

   func New<Verb><Noun>Handler(repo Repository, clock Clock) *<Verb><Noun>Handler {
       if repo == nil  { panic("nil repo")  }
       if clock == nil { panic("nil clock") }
       return &<Verb><Noun>Handler{repo: repo, clock: clock}
   }

   func (h *<Verb><Noun>Handler) Handle(ctx context.Context, cmd <Verb><Noun>Command) (*<Verb><Noun>Response, error) {
       // 1. Business validation — does the world allow this?
       if err := h.validate(ctx, cmd); err != nil { return nil, err }

       // 2. Build the domain object (invariants checked inside).
       entity, err := domain<feature>.New<Entity>(
           cmd.TenantID,
           // ... args
           h.clock.Now(),
       )
       if err != nil {
           // Domain invariant violation → 400 Validation.
           return nil, result.Validation(map[string][]string{"<field>": {err.Error()}})
       }

       // 3. Persist.
       if err := h.repo.Save(ctx, entity); err != nil {
           if errors.Is(err, domain<feature>.ErrConcurrencyConflict) {
               return nil, result.Conflict("<entity>.concurrency_conflict", "the resource was modified concurrently; reload and retry")
           }
           return nil, fmt.Errorf("saving <entity>: %w", err)
       }

       // 4. Map to response.
       return &<Verb><Noun>Response{
           ID: entity.ID(),
           // ...
       }, nil
   }

   // --- validator (business scope) ---
   func (h *<Verb><Noun>Handler) validate(ctx context.Context, cmd <Verb><Noun>Command) error {
       if cmd.TenantID == "" { return result.Unauthorized("tenant.missing", "tenant context required") }
       // ... any business rule that needs the repo / external state
       return nil
   }
   ```

3. **Add the repository method** (if new) to `internal/app/<feature>/repository.go`:

   ```go
   type Repository interface {
       Save(ctx context.Context, e *domain<feature>.<Entity>) error
       // ... existing methods
   }
   ```

   Then implement it in `internal/infra/persistence/<feature>/repository.go` — see the
   `sqlc-patterns` skill.

4. **Wrap with the transaction decorator.** In `cmd/api/main.go` (or a dedicated
   `internal/app/<feature>/wire.go`):

   ```go
   handlers := <feature>.Handlers{
       <Verb><Noun>: app.WithTransaction(uow, <feature>.New<Verb><Noun>Handler(repo, clock)),
       // ...
   }
   ```

   Commands always go through the transaction decorator (queries skip it).

5. **Wire the API endpoint** — invoke the `add-endpoint` skill for the Gin handler that
   dispatches this command.

6. **Tests** — invoke the `write-unit-tests` skill:
   - Happy path: valid cmd → repo called once → response correct.
   - Tenant missing → `result.Unauthorized`.
   - Domain invariant violation → `result.Validation` with the right field.
   - Repo concurrency conflict → `result.Conflict`.
   - Repo generic failure → wrapped error (the API maps to 500).

## Conventions (restated from the rule)

- **Naming:** `{Verb}{Noun}Command` / `{Verb}{Noun}Handler` / `{Verb}{Noun}Response`. Verb
  in imperative — `Create`, `Archive`, `Rename`, not `Created` or `Creating`.
- **`Handle(ctx, cmd) (*Response, error)`** is the method shape. Always.
- **One file per use case.** Don't share a handler across two commands; don't put two
  commands in one file.
- **The handler does NOT begin/commit a transaction.** The decorator does.
- **The handler does NOT read from the DB at the API layer's contract level** — only via
  the repository interface declared in this package.
- **Errors:**
  - Expected, client-visible → `result.X(...)` constructor (Validation, NotFound, Conflict,
    Unauthorized, Forbidden).
  - Unexpected → wrap with `fmt.Errorf("...: %w", err)` and let the mapper render 500.
  - Domain sentinel → catch with `errors.Is`, map to the appropriate `result.X`.

## OpenAPI cross-reference

A command alone doesn't touch the OpenAPI spec — that's the API layer's job (the
matching endpoint via `add-endpoint`). BUT: the command's **response struct shape is
what the spec describes**. So:

- Pick the response struct's field names + types deliberately; they become the OpenAPI
  schema. JSON tags + `description:"..."` tags drive the spec under the code-first
  generator. Spec-first projects must keep the response shape compatible with the
  declared `#/components/schemas/<Verb><Noun>Response`.
- After authoring the command, the matching `/add-endpoint` invocation regenerates /
  validates the spec. **Don't skip that step** — a command without a corresponding
  endpoint + spec update is half-done work.

See `.claude/rules/backend/openapi.md` and the `openapi-spec` skill.

## When the command spans multiple aggregates

- All aggregates write through the same `UnitOfWork` (the transaction decorator ensures one
  transaction for the whole handler).
- Cross-aggregate consistency is best-effort; prefer event-driven eventual consistency
  when the aggregate boundaries are genuinely different (and the product can tolerate it).
- A command that touches > 3 aggregates is a smell — split or rethink the boundary.

## Common mistakes (don't)

- Putting the tenant in the command body and trusting it. The API handler must pull it
  from context and set it on the command.
- `errors.New("project not found")` in the handler — use the typed `result.NotFound(...)`.
- Calling `pgx.Pool.Begin()` inside the handler. Transactions are the decorator's job.
- Logging from the handler. Logging is the middleware / decorator's job (audit log on
  command commit). Inside the handler, only log if it's diagnostic and adds value.
- Returning `*domain.Entity` as the response. Map to a `<Verb><Noun>Response`.
