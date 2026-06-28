---
description: Tenancy as a first-class invariant — tenant_id everywhere, scoped queries, fail-closed context, RLS backstop. Auto-loads on all backend code.
paths:
  - "internal/**/*.go"
  - "migrations/**/*.sql"
---

# Tenancy

This rule applies if the product is multi-tenant. (Single-tenant? Delete this rule + the
tenancy middleware + the rule's `paths:` glob; the rest of the harness still works.)

## The invariant

- **Every persisted row carries a non-zero `tenant_id`.**
- **Every read and write is scoped to a single tenant.**
- **No code path reads or writes across tenants without an explicit, audited bypass.**
- **Fail-closed**: a request context without a tenant means **no rows / explicit error**,
  never "all tenants".

## Where it lives

| Layer | Responsibility |
|---|---|
| API | Derive tenant from server-validated session (JWT claims), put it in `context.Context`. NEVER trust client-supplied `X-Tenant-Id` or request body fields. |
| API middleware | `tenancy.Middleware()` rejects requests without a tenant; this is per-route opt-in (some endpoints are tenant-free, e.g. `/healthz`). |
| App / use case | Read tenant from context; pass to repository; assert tenant matches when loading an aggregate. |
| Domain | Entity carries `TenantID` as immutable field. Constructor validates non-empty. |
| Persistence | sqlc queries take `tenant_id` as a parameter (you can't forget — the generated method requires it). |
| Database | PostgreSQL RLS policy on every tenant-scoped table as a backstop. |

## API middleware

```go
package middleware

import (
    "context"
    "github.com/gin-gonic/gin"
)

type ctxKey int
const tenantKey ctxKey = iota

type TenantID string

func TenantFromContext(ctx context.Context) (TenantID, bool) {
    t, ok := ctx.Value(tenantKey).(TenantID)
    return t, ok && t != ""
}

func WithTenant(ctx context.Context, t TenantID) context.Context {
    return context.WithValue(ctx, tenantKey, t)
}

// Tenancy — middleware that derives tenant from auth claims and rejects requests without one.
// Skip for routes that legitimately have no tenant (healthz, readyz, login).
func Tenancy() gin.HandlerFunc {
    return func(c *gin.Context) {
        claims, ok := AuthFromContext(c.Request.Context())
        if !ok || claims.TenantID == "" {
            WriteProblem(c, result.Unauthorized("tenant.missing", "tenant context required"))
            c.Abort()
            return
        }
        ctx := WithTenant(c.Request.Context(), TenantID(claims.TenantID))
        c.Request = c.Request.WithContext(ctx)
        c.Next()
    }
}
```

## At the use case

```go
func (h *CreateProjectHandler) Handle(ctx context.Context, cmd CreateProjectCommand) (*CreateProjectResponse, error) {
    // tenant comes from the request context, NOT from cmd. The handler's contract is to
    // build cmd with the tenant from context.
    if cmd.TenantID == "" {
        return nil, result.Unauthorized("tenant.missing", "tenant context required")
    }
    // ... pass tenant to repo
}
```

In the Gin handler:

```go
tenant, ok := middleware.TenantFromContext(c.Request.Context())
if !ok {
    middleware.WriteProblem(c, result.Unauthorized("tenant.missing", "tenant context required"))
    return
}
resp, err := uc.Handle(c.Request.Context(), CreateProjectCommand{
    TenantID: tenant,        // from context, not from request body
    Name:     req.Name,
})
```

## At the repository / sqlc

Every query takes `tenant_id`:

```sql
-- name: GetProjectByID :one
SELECT * FROM projects WHERE id = $1 AND tenant_id = $2;

-- name: ListProjects :many
SELECT * FROM projects WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3;
```

The repository wraps the sqlc call:

```go
func (r *Repository) Load(ctx context.Context, tenant TenantID, id ID) (*Project, error) {
    row, err := r.queries(ctx).GetProjectByID(ctx, sqlc.GetProjectByIDParams{
        ID:       uuid.MustParse(string(id)),
        TenantID: uuid.MustParse(string(tenant)),
    })
    // ...
}
```

The use case passes `tenant` from the cmd. The chain is: HTTP → middleware → cmd.TenantID
→ handler → repo → SQL. Every link enforces it.

## PostgreSQL RLS — the backstop

If app-level scoping has a bug, RLS prevents the leak. Every tenant-scoped table:

```sql
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON projects
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

The Unit of Work sets the GUC at the start of every transaction:

```go
func (u *PgxUoW) ExecuteInTransaction(ctx context.Context, fn func(ctx context.Context) error) error {
    tenant, ok := middleware.TenantFromContext(ctx)
    if !ok {
        return result.Unauthorized("tenant.missing", "tenant context required")
    }
    tx, err := u.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
    if err != nil { return err }
    if _, err := tx.Exec(ctx, "SET LOCAL app.tenant_id = $1", string(tenant)); err != nil {
        _ = tx.Rollback(ctx)
        return err
    }
    // ...
}
```

Read-only queries that bypass the UoW still need RLS — set `app.tenant_id` per pool
connection acquire via a `pgx.AfterConnect` hook, or use `SET LOCAL` inside a one-shot
transaction.

## Tests — the most important ones we write

For every tenant-scoped feature:

```go
func TestProjects_TenantIsolation(t *testing.T) {
    // GIVEN — two tenants, each with their own project
    ctx := context.Background()
    a := newTenant(t); b := newTenant(t)
    projA, _ := uc.Create(WithTenant(ctx, a), CreateProjectCommand{TenantID: a, Name: "ProjectA"})
    projB, _ := uc.Create(WithTenant(ctx, b), CreateProjectCommand{TenantID: b, Name: "ProjectB"})

    // WHEN — tenant A tries to load tenant B's project
    _, err := uc.Get(WithTenant(ctx, a), GetProjectQuery{TenantID: a, ID: projB.ID})

    // THEN — not found (not "forbidden" — leaking existence is itself a leak)
    require.ErrorIs(t, err, result.ErrNotFound)
}
```

Every multi-tenant integration test creates **two tenants** and asserts the isolation
boundary. This catches the largest class of catastrophic bugs.

## Privileged bypass (rare, audited)

When the product needs to query across tenants — analytics, support tooling, GDPR
exports — the bypass is **explicit and audited**:

```go
// SystemContext — privileged. Audited. Logged at Info level whenever used.
type SystemContext struct {
    Reason string  // e.g. "support_export_for_ticket_12345"
}

func WithSystemContext(ctx context.Context, sc SystemContext) context.Context {
    slog.InfoContext(ctx, "system context activated", "reason", sc.Reason)
    return context.WithValue(ctx, systemKey, sc)
}

// Repositories check for SystemContext and skip tenant scoping when present.
// (Or pass a separate, system-only query method.)
```

- **Every use** logs the reason at `Info` level + audit-store record.
- **Every place that checks for SystemContext** is grep-able (`grep -rn 'systemKey'`); the
  security audit lists them all.
- **Never expose a SystemContext path from a public API route.** Internal tooling only.

## What we don't do

- **Trust client-supplied tenant ids.** A query string or header value is forgeable.
  Derive from the session.
- **Bind request bodies onto entities.** A request that sets `tenant_id` is the canonical
  overposting attack. Always bind to a DTO and copy with the tenant from context.
- **Default to "all tenants" on missing context.** Fail-closed: error or empty result.
- **`IgnoreQueryFilters`-style escape hatches that compile in production code.** The
  SystemContext is the only path; it's typed, audited, and rare.

## When you're adding a new tenant-scoped table

1. Add `tenant_id uuid NOT NULL` to the migration. Index `(tenant_id, ...)`.
2. Enable RLS + add the policy.
3. Every sqlc query takes `tenant_id` as a parameter.
4. Domain entity has `TenantID` immutable field.
5. Repository methods take `tenant` as a parameter.
6. Use case reads `tenant` from context and passes to the repository.
7. **Integration test asserts the isolation boundary.**
