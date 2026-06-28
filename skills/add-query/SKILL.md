---
name: add-query
description: Author a CQRS query — read-only, projects to a response DTO, bypasses the transaction decorator. Use when adding a read-only use case in internal/app/<feature>/.
argument-hint: <Feature>/Get<Noun> or List<Nouns> (e.g. Projects/GetProject)
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# Add a CQRS query

A **query** reads state and never mutates. Source of truth: `.claude/rules/backend/cqrs.md`.

## When a query is the right tool

- Read a single entity by id (`GetProject`)
- List with pagination (`ListProjects`)
- Search / filter (`SearchProjects`)
- Aggregate / report (`GetProjectStats`)

A query NEVER:
- Mutates the database (no `INSERT`/`UPDATE`/`DELETE`)
- Calls the transaction decorator (read-only doesn't need a tx)
- Reconstructs full domain entities for projection-only purposes — project straight to a
  DTO

## Steps

1. **Decide on the projection.** Does the caller need the full domain entity (then load it
   via the repo) or a flat read model (then project in SQL)? Default to the projection
   for any list/search; reserve the full-entity load for `Get<Noun>` when the caller will
   mutate it.

2. **Create the file** at `internal/app/<feature>/<verb>_<noun>.go`:

   ```go
   package <feature>

   import (
       "context"
       "errors"
       "fmt"

       domain<feature> "{{ProjectName}}/internal/domain/<feature>"
       "{{ProjectName}}/internal/shared/result"
   )

   // --- Query ---
   type Get<Noun>Query struct {
       TenantID domain<feature>.TenantID
       ID       domain<feature>.ID
   }

   // --- Response (projection) ---
   type <Noun>Response struct {
       ID        domain<feature>.ID
       Name      string
       // ... only the fields the caller needs
   }

   // --- Handler ---
   type Get<Noun>Handler struct {
       reader Reader  // declared in repository.go
   }

   func NewGet<Noun>Handler(reader Reader) *Get<Noun>Handler {
       if reader == nil { panic("nil reader") }
       return &Get<Noun>Handler{reader: reader}
   }

   func (h *Get<Noun>Handler) Handle(ctx context.Context, q Get<Noun>Query) (*<Noun>Response, error) {
       if q.TenantID == "" { return nil, result.Unauthorized("tenant.missing", "tenant context required") }

       row, err := h.reader.Find<Noun>(ctx, q.TenantID, q.ID)
       if errors.Is(err, domain<feature>.ErrNotFound) {
           return nil, result.NotFound("<noun>.not_found", fmt.Sprintf("<noun> %s not found", q.ID))
       }
       if err != nil { return nil, fmt.Errorf("finding <noun> %s: %w", q.ID, err) }

       return &<Noun>Response{
           ID:   row.ID,
           Name: row.Name,
           // ...
       }, nil
   }
   ```

3. **Decide: shared `Repository` or separate `Reader`?**
   - **Shared** — if `Repository` already exists for the feature and the query just needs
     a read method, add it to `Repository`. Many projects keep one interface for both.
   - **Separate** — when reads have a distinct projection shape (a different return type
     than the entity), declare a `Reader` interface in `internal/app/<feature>/reader.go`.
     Allows the read side to bypass repository assumptions (e.g. it can return a flat
     `sqlc`-generated row directly).

4. **Pagination shape** (for `List*` queries):

   ```go
   type ListProjectsQuery struct {
       TenantID  TenantID
       Limit     int32   // default 50, max 100 (clamped here)
       Cursor    string  // opaque; usually base64(created_at + id)
       Archived  *bool   // nil = both
   }

   type ListProjectsResponse struct {
       Items      []<Noun>Response
       NextCursor string  // empty when no more pages
   }
   ```

   - **Cursor pagination** by default. Offset pagination is O(N) in Postgres and breaks at
     scale; cursors stay constant-time.
   - **Clamp limits** in the handler (`if q.Limit <= 0 || q.Limit > 100 { q.Limit = 50 }`).
   - **Stable sort key** — `created_at DESC, id DESC` is the canonical "newest first";
     `id` tiebreaks because timestamps collide.

5. **Wire the API endpoint** — `add-endpoint` skill for the Gin handler that dispatches
   this query. Queries map to:
   - `GET /v1/<feature>/:id` for single fetch (200 / 404)
   - `GET /v1/<feature>?cursor=...&limit=...` for list

6. **No transaction decorator.** Queries don't go through the UoW; they run on the pool
   directly. RLS still enforces tenant scoping at the DB.

7. **Tests** — invoke `write-unit-tests`:
   - Happy path: reader returns row → response correct.
   - Tenant missing → `result.Unauthorized`.
   - Reader returns `ErrNotFound` → `result.NotFound`.
   - Reader returns generic error → wrapped error (API maps to 500).
   - List: pagination cursor round-trips correctly.

## Hot rules

- **No mutation.** A query that writes is a bug. Even logging an "access event" goes
  through a separate audit pipeline, not the query handler.
- **Project early.** sqlc generates a typed struct for the query's columns; map it to the
  response struct in the repository's `Find<Noun>` method — don't reconstruct a full
  domain entity if the response only needs 3 fields.
- **Tenant scoping in the SQL** — the sqlc query takes `tenant_id` as a parameter; you
  can't forget it.
- **Caching is a separate concern.** Add a cache (Redis, in-memory LRU) only when latency
  / DB load demand it; document the invalidation strategy (which command invalidates which
  query).

## OpenAPI cross-reference

A query's response struct is what the OpenAPI spec exposes to the client. List queries
in particular have a `Response` shape (items + pagination cursor) that shows up directly
in the spec:

- The response struct's JSON tags + `description:"..."` tags drive the OpenAPI schema
  (under the code-first generator). Spec-first projects must keep the response
  compatible with `#/components/schemas/<Noun>ListResponse` / `<Noun>Response`.
- The pagination cursor is opaque to the client; document it in the spec as
  `nextCursor: string` with `description:"Opaque pagination cursor; pass as ?cursor= in
  the next request, or empty when there are no more pages."`.
- The `/add-endpoint` invocation that mounts this query regenerates / validates the
  spec.

See `.claude/rules/backend/openapi.md` and the `openapi-spec` skill.

## When to bypass the domain entity

If the query just needs `(id, name, created_at)` for a list:

```go
// internal/infra/persistence/<feature>/reader.go
type Reader struct { pool *pgxpool.Pool }

type ProjectListRow struct {
    ID        ID
    Name      string
    CreatedAt time.Time
}

func (r *Reader) ListProjects(ctx context.Context, tenant TenantID, limit int32, cursor string) ([]ProjectListRow, string, error) {
    // sqlc query returning the flat columns; build []ProjectListRow + next cursor
}
```

The handler maps `[]ProjectListRow` → `[]<Noun>Response` directly. No domain construction
needed.

## Common mistakes (don't)

- Wrapping a query in the transaction decorator. Performance loss + locking risk.
- Using a query handler to "warm a cache" or trigger a side effect. Pure reads only.
- Loading the full entity to render a single field. Use a projection.
- Hard-coded `LIMIT 1000` — always paginate or paginate with sane defaults.
- Forgetting `tenant_id` in the WHERE clause. RLS would catch it, but the linter / sqlc
  schema enforces it before the request hits the DB.
