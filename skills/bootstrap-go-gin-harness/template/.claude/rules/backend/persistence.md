---
description: pgx + sqlc + goose persistence — typed queries, repository per aggregate, thin UnitOfWork, tenancy filters, UUIDv7, xmin concurrency. Auto-loads on internal/infra/persistence/** and migrations/.
paths:
  - "internal/infra/persistence/**/*.go"
  - "internal/infra/persistence/**/*.sql"
  - "migrations/**/*.sql"
---

# Persistence (pgx + sqlc + goose)

Authoritative refs: `sqlc-patterns` + `pgx-query-performance` skills,
`docs/projectStandards/backend-architecture.md`.

## Stack

- **Driver:** `jackc/pgx/v5` (`pgxpool.Pool`)
- **Query layer:** `sqlc` — write SQL, sqlc generates type-safe Go.
- **Migrations:** `pressly/goose/v3` — `*.up.sql` / `*.down.sql` pairs in `migrations/`.
- **Connection lifecycle:** `pgxpool.Pool` constructed once in `cmd/api/main.go`; passed
  into each repository's constructor.

## Repository per aggregate root

One repository struct per aggregate, in `internal/infra/persistence/<feature>/`:

```go
// internal/infra/persistence/projects/repository.go
package projects

import (
    "context"
    "errors"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"

    appprojects "{{ProjectName}}/internal/app/projects"
    domainprojects "{{ProjectName}}/internal/domain/projects"
    sqlc "{{ProjectName}}/internal/infra/persistence/_sqlcgen"
)

// Compile-time check the repo satisfies the app-layer interface.
var _ appprojects.Repository = (*Repository)(nil)

type Repository struct {
    pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repository { return &Repository{pool: pool} }

// queries returns a sqlc Queries bound to the request's connection (transaction-aware:
// if a tx is in ctx, use it; otherwise the pool).
func (r *Repository) queries(ctx context.Context) sqlc.Querier {
    if tx, ok := txFromContext(ctx); ok {
        return sqlc.New(tx)
    }
    return sqlc.New(r.pool)
}

func (r *Repository) Save(ctx context.Context, p *domainprojects.Project) error {
    q := r.queries(ctx)
    return q.UpsertProject(ctx, sqlc.UpsertProjectParams{
        ID:        uuid.MustParse(string(p.ID())),
        TenantID:  uuid.MustParse(string(p.TenantID())),
        Name:      p.Name(),
        Archived:  p.Archived(),
        CreatedAt: p.CreatedAt(),
        UpdatedAt: p.UpdatedAt(),
    })
}

func (r *Repository) Load(ctx context.Context, tenant domainprojects.TenantID, id domainprojects.ID) (*domainprojects.Project, error) {
    q := r.queries(ctx)
    row, err := q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{
        ID:       uuid.MustParse(string(id)),
        TenantID: uuid.MustParse(string(tenant)),
    })
    if errors.Is(err, pgx.ErrNoRows) {
        return nil, domainprojects.ErrNotFound
    }
    if err != nil { return nil, fmt.Errorf("loading project %s: %w", id, err) }

    return domainprojects.Restore(
        domainprojects.ID(row.ID.String()),
        domainprojects.TenantID(row.TenantID.String()),
        row.Name, row.Archived, row.CreatedAt, row.UpdatedAt, row.Xmin,
    ), nil
}
```

## sqlc queries

`internal/infra/persistence/projects/queries/project.sql`:

```sql
-- name: GetProjectByID :one
SELECT id, tenant_id, name, archived, created_at, updated_at, xmin::text::bigint AS version
FROM projects
WHERE id = $1 AND tenant_id = $2;

-- name: UpsertProject :exec
INSERT INTO projects (id, tenant_id, name, archived, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (id) DO UPDATE
SET name       = EXCLUDED.name,
    archived   = EXCLUDED.archived,
    updated_at = EXCLUDED.updated_at
WHERE projects.tenant_id = EXCLUDED.tenant_id;  -- tenant guard at the SQL level

-- name: ListProjects :many
SELECT id, tenant_id, name, archived, created_at, updated_at
FROM projects
WHERE tenant_id = $1 AND archived = $2
ORDER BY created_at DESC, id DESC
LIMIT $3 OFFSET $4;
```

Run `make sqlc` to regenerate `internal/infra/persistence/_sqlcgen/`.

## Unit of work + transactions

Thin interface in `internal/app/<feature>/` (or shared in `internal/app/`):

```go
package app // internal/app/uow.go (or similar)

type UnitOfWork interface {
    // ExecuteInTransaction runs fn inside a transaction. fn receives a context carrying
    // the transaction; passing it to any repo from the same UnitOfWork participates in
    // the same tx. Commits on nil error, rolls back otherwise.
    ExecuteInTransaction(ctx context.Context, fn func(ctx context.Context) error) error
}
```

Implementation in `internal/infra/persistence/uow.go`:

```go
type PgxUoW struct {
    pool *pgxpool.Pool
}

func (u *PgxUoW) ExecuteInTransaction(ctx context.Context, fn func(ctx context.Context) error) error {
    tx, err := u.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
    if err != nil { return err }

    txCtx := contextWithTx(ctx, tx)
    if err := fn(txCtx); err != nil {
        _ = tx.Rollback(ctx)
        return err
    }
    return tx.Commit(ctx)
}
```

The use-case dispatcher (or a per-handler decorator) wraps every **command** in `ExecuteInTransaction`:

```go
type TxCreateProjectHandler struct {
    inner *projects.CreateProjectHandler
    uow   app.UnitOfWork
}

func (h *TxCreateProjectHandler) Handle(ctx context.Context, cmd projects.CreateProjectCommand) (*projects.CreateProjectResponse, error) {
    var resp *projects.CreateProjectResponse
    err := h.uow.ExecuteInTransaction(ctx, func(ctx context.Context) error {
        var err error
        resp, err = h.inner.Handle(ctx, cmd)
        return err
    })
    return resp, err
}
```

Queries **skip the transaction** — they're read-only; the pool's per-statement implicit
transactions are sufficient.

## Tenancy at the query layer

- Every query that touches a tenant-scoped table takes `tenant_id` as a parameter — sqlc
  guarantees you can't forget (the generated method requires it).
- Aggregate methods on the domain assert `tenant_id` matches before writing.
- **PostgreSQL RLS as backstop**: `CREATE POLICY tenant_isolation ON projects USING
  (tenant_id = current_setting('app.tenant_id')::uuid);`. The repository sets the GUC at
  the start of every transaction: `SET LOCAL app.tenant_id = $1`. A bug in app-level
  scoping fails closed at the DB.

## Migrations (goose)

```
-- migrations/001_init_projects.up.sql

-- +goose Up
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for gen_random_uuid if needed
CREATE TABLE projects (
    id         uuid        PRIMARY KEY,
    tenant_id  uuid        NOT NULL,
    name       text        NOT NULL,
    archived   boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

CREATE INDEX idx_projects_tenant_created ON projects (tenant_id, created_at DESC);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON projects
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- +goose Down
DROP TABLE projects;
```

**Hard rules**:
- Every migration has a real, working `-- +goose Down`.
- Never edit an applied migration. Write a new one.
- Apply against the testcontainers PostgreSQL in the integration test — a broken migration
  fails CI.
- Avoid concurrent index creation in transactional migrations — `CREATE INDEX CONCURRENTLY`
  cannot run inside a transaction. Wrap in a `-- +goose NO TRANSACTION` block if needed.

## Hot rules

- **Always `defer rows.Close()`** + check `rows.Err()` after the iteration loop —
  `rowserrcheck` and `sqlclosecheck` linters enforce.
- **`time.Time` is UTC.** pgx's `timestamptz` returns UTC; if you ever pass `time.Now()`
  directly, ensure it's UTC (`time.Now().UTC()`).
- **UUIDv7 in the domain constructor** — never `gen_random_uuid()` in the DB or `uuid.New()`
  in the repository.
- **No raw `fmt.Sprintf` into SQL**. Parameters via `$1`/`$2`. Dynamic order-by columns go
  through a hard-coded allow-list.
- **Optimistic concurrency**: read `xmin`, assert on update, fail with `ErrConcurrencyConflict`
  on mismatch (sqlc `UPDATE … WHERE id = $1 AND xmin::text::bigint = $2` returns 0 rows →
  conflict).
- **Connection pool tuning**: `MaxConns` based on the DB's `max_connections` and how many
  app instances you run; `MaxConnLifetime` ~ 30 minutes; `HealthCheckPeriod` ~ 1 minute.
- **`pgx.ErrNoRows`** is wrapped with the domain sentinel (`ErrNotFound`) at the repo
  boundary — never let `pgx.ErrNoRows` leak past `internal/infra/`.

## Naming convention

- **Tables and columns** in `snake_case` (PostgreSQL folds unquoted identifiers to lower).
- **Plural table names** (`projects`, not `project`).
- **Foreign key columns** named `<referenced_table>_id` (`tenant_id`, `project_id`).
- **`created_at` / `updated_at`** on every persisted row; `archived_at` (nullable timestamp)
  preferred over `archived` (bool) when you also want the "when".

## What we don't do

- **No GORM, no `database/sql` directly.** pgx + sqlc only (with approved exceptions for
  one-off raw queries).
- **No repository for queries.** Read-side / list / search queries can go directly through
  sqlc and project to DTOs — no repo round-trip through domain construction.
- **No reflection / auto-mapping** from struct fields to columns. sqlc generates explicit
  code; we read it.
- **No connection per request.** The pool handles checkout/checkin; never `pool.Acquire`
  in app code without `defer conn.Release()`.
- **No raw SQL in `internal/app/`.** Repository interfaces only; the SQL stays in
  `internal/infra/persistence/`.
- **No `SELECT *` in production queries.** Explicit column lists — adding a column shouldn't
  silently break callers.
