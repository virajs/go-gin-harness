---
name: sqlc-patterns
description: Add or change pgx + sqlc persistence — write SQL queries with sqlc annotations, regenerate typed Go, wire a repository, handle migrations with goose. Use when adding a table, query, repository, or migration under internal/infra/persistence/.
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# sqlc + pgx patterns

Source of truth: `.claude/rules/backend/persistence.md`, `sqlc.yaml`, the canonical sqlc
docs at https://docs.sqlc.dev/.

## Workflow

1. Write the SQL query in `internal/infra/persistence/<feature>/queries/*.sql`.
2. Run `make sqlc` — generates typed Go in `internal/infra/persistence/_sqlcgen/`.
3. Write the repository wrapper in `internal/infra/persistence/<feature>/repository.go` that
   adapts the generated typed methods to the domain interface declared in `internal/app/<feature>/`.
4. Write a migration in `migrations/NNNN_<name>.sql` for any schema change.
5. Test with testcontainers (`make test-integration`).

## Writing a sqlc query

```sql
-- internal/infra/persistence/projects/queries/project.sql

-- name: GetProjectByID :one
SELECT id, tenant_id, name, archived, created_at, updated_at, xmin::text::bigint AS version
FROM projects
WHERE id = $1 AND tenant_id = $2;

-- name: ListProjects :many
SELECT id, tenant_id, name, archived, created_at, updated_at
FROM projects
WHERE tenant_id = $1
  AND ($2::boolean IS NULL OR archived = $2)
ORDER BY created_at DESC, id DESC
LIMIT $3 OFFSET $4;

-- name: CountProjects :one
SELECT COUNT(*) FROM projects WHERE tenant_id = $1;

-- name: UpsertProject :exec
INSERT INTO projects (id, tenant_id, name, archived, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (id) DO UPDATE
SET name       = EXCLUDED.name,
    archived   = EXCLUDED.archived,
    updated_at = EXCLUDED.updated_at
WHERE projects.tenant_id = EXCLUDED.tenant_id;

-- name: UpdateProjectOptimistic :execrows
-- Returns rowcount; 0 means concurrency conflict.
UPDATE projects
SET name       = $3,
    updated_at = $4
WHERE id = $1 AND tenant_id = $2
  AND xmin::text::bigint = $5;

-- name: DeleteProject :exec
DELETE FROM projects WHERE id = $1 AND tenant_id = $2;
```

**sqlc annotation cheat sheet:**

| Annotation | Returns |
|---|---|
| `:one` | Single struct; `pgx.ErrNoRows` on miss |
| `:many` | Slice of structs |
| `:exec` | `error` only |
| `:execrows` | `(int64, error)` — affected row count |
| `:execresult` | `(pgconn.CommandTag, error)` |
| `:copyfrom` | `int64` for bulk insert |
| `:batchexec` | Batch a slice of params; for bulk operations |

**Naming**: PascalCase for the Go method (`GetProjectByID`), camelCase params via
`sqlc.arg(name)`:

```sql
-- name: GetProjectByID :one
SELECT * FROM projects
WHERE id = sqlc.arg('id') AND tenant_id = sqlc.arg('tenant_id');
```

…generates `GetProjectByID(ctx, params GetProjectByIDParams)` where
`GetProjectByIDParams.ID` and `.TenantID` are typed.

## Repository wrapper

```go
// internal/infra/persistence/projects/repository.go
package projects

import (
    "context"
    "errors"
    "fmt"

    "github.com/google/uuid"
    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"

    appprojects "{{ProjectName}}/internal/app/projects"
    domain "{{ProjectName}}/internal/domain/projects"
    sqlc "{{ProjectName}}/internal/infra/persistence/_sqlcgen"
)

var _ appprojects.Repository = (*Repository)(nil) // compile-time interface check

type Repository struct {
    pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repository { return &Repository{pool: pool} }

// queries — returns a sqlc Querier bound to the tx in ctx (if any) or the pool.
func (r *Repository) queries(ctx context.Context) sqlc.Querier {
    if tx, ok := txFromContext(ctx); ok {
        return sqlc.New(tx)
    }
    return sqlc.New(r.pool)
}

func (r *Repository) Load(ctx context.Context, tenant domain.TenantID, id domain.ID) (*domain.Project, error) {
    row, err := r.queries(ctx).GetProjectByID(ctx, sqlc.GetProjectByIDParams{
        ID:       uuid.MustParse(string(id)),
        TenantID: uuid.MustParse(string(tenant)),
    })
    if errors.Is(err, pgx.ErrNoRows) {
        return nil, domain.ErrNotFound
    }
    if err != nil { return nil, fmt.Errorf("loading project %s: %w", id, err) }

    return domain.Restore(
        domain.ID(row.ID.String()),
        domain.TenantID(row.TenantID.String()),
        row.Name, row.Archived,
        row.CreatedAt, row.UpdatedAt,
        uint32(row.Version),
    ), nil
}

func (r *Repository) Save(ctx context.Context, p *domain.Project) error {
    err := r.queries(ctx).UpsertProject(ctx, sqlc.UpsertProjectParams{
        ID:        uuid.MustParse(string(p.ID())),
        TenantID:  uuid.MustParse(string(p.TenantID())),
        Name:      p.Name(),
        Archived:  p.Archived(),
        CreatedAt: p.CreatedAt(),
        UpdatedAt: p.UpdatedAt(),
    })
    if err != nil { return fmt.Errorf("upserting project %s: %w", p.ID(), err) }
    return nil
}

func (r *Repository) UpdateOptimistic(ctx context.Context, p *domain.Project) error {
    rows, err := r.queries(ctx).UpdateProjectOptimistic(ctx, sqlc.UpdateProjectOptimisticParams{
        ID:       uuid.MustParse(string(p.ID())),
        TenantID: uuid.MustParse(string(p.TenantID())),
        Name:     p.Name(),
        UpdatedAt: p.UpdatedAt(),
        Xmin:     int64(p.Version()),
    })
    if err != nil { return fmt.Errorf("optimistic update: %w", err) }
    if rows == 0 { return domain.ErrConcurrencyConflict }
    return nil
}
```

## Migration patterns (goose)

```sql
-- migrations/001_init_projects.up.sql

-- +goose Up
CREATE TABLE projects (
    id         uuid        PRIMARY KEY,
    tenant_id  uuid        NOT NULL,
    name       text        NOT NULL,
    archived   boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

CREATE INDEX idx_projects_tenant_created
    ON projects (tenant_id, created_at DESC, id DESC);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON projects
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- +goose Down
DROP TABLE projects;
```

**Concurrent index creation** can't run in a transaction; use a no-tx block:

```sql
-- +goose Up
-- +goose NO TRANSACTION
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projects_name
    ON projects (tenant_id, lower(name));

-- +goose Down
-- +goose NO TRANSACTION
DROP INDEX CONCURRENTLY IF EXISTS idx_projects_name;
```

## Hot rules

- **Every query takes `tenant_id`** when the table is tenant-scoped. sqlc generates a
  `Params` struct that REQUIRES it — there's no way to forget.
- **`pgx.ErrNoRows` doesn't leak past the repository.** Wrap to `domain.ErrNotFound`.
- **`defer rows.Close()`** — sqlc's generated code handles it; if you hand-write raw pgx,
  always defer-close.
- **`SELECT *` is forbidden** in production queries — explicit column lists.
- **`fmt.Sprintf` into SQL is forbidden.** Parameters via `$1` / `sqlc.arg(...)`.
- **`time.Time` is UTC.** pgx + `timestamptz` columns return UTC; if you ever pass a
  client-provided time, normalize to UTC first.
- **UUIDv7 is minted in the domain constructor**, never in SQL. The migration doesn't
  default `id` to `gen_random_uuid()`.
- **Migrations are append-only.** Never edit a migration after it's been applied.

## Transactions

- A handler doesn't `Begin` / `Commit`. The UnitOfWork decorator (see `cqrs.md`,
  `persistence.md`) wraps the handler.
- The repository's `queries(ctx)` method checks the context for a tx and uses it
  automatically.
- Multiple repos inside the same `ExecuteInTransaction(ctx, fn)` participate in the same
  tx — that's the whole point of putting the tx in the context.

## Common mistakes (don't)

- Forgetting `tenant_id` in a WHERE clause. RLS catches it, but ideally the linter / sqlc
  schema does.
- Returning `pgx.ErrNoRows` from the repo. Always translate to `domain.ErrNotFound`.
- Using `sqlc` for a one-off complex query. If the query needs CTEs, window functions, or
  dynamic conditions sqlc can't express, drop to raw pgx with a justification comment.
- Editing a migration that's already applied. Write a new one.
- Putting business logic in the SQL (`CASE WHEN ... THEN status='X' ELSE 'Y' END` for
  business state). Business logic lives in `internal/app/`, not in the query.
