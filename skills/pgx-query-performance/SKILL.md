---
name: pgx-query-performance
description: Optimize pgx + PostgreSQL queries — fix N+1, use prepared statements, batching, COPY, EXPLAIN ANALYZE, and the pgx pool tuning. Use when a query is slow, emits too much SQL, or causes high DB load. Complements sqlc-patterns scaffolding skill.
allowed-tools: Read, Glob, Grep, Edit, Bash, Skill
---

# pgx query performance

When a request is slow, **measure first**. The skill walks the diagnostic loop and the
remedies, in order of cost/effort.

## Diagnostic loop

1. **Reproduce.** Hit the endpoint in dev / staging; capture timing. Use `pprof` for CPU,
   but most DB issues show up in the request span — check the trace first.
2. **EXPLAIN ANALYZE the query.**
   ```sql
   EXPLAIN (ANALYZE, BUFFERS) <query with realistic params>;
   ```
   Look for:
   - **Seq Scan on a large table** — missing index? wrong predicate?
   - **Rows estimated vs actual diverge by >10×** — stale statistics (`ANALYZE` the table)
     or correlated columns the planner can't reason about.
   - **Sort with `external merge`** — `work_mem` too low; or sort can be avoided with the
     right index ordering.
   - **Loop join when hash would be better** — usually a row-count miss; sometimes a
     `LIMIT` that the planner over-estimates the cost of.
3. **Check the call site.** Is the query called once per request or N times in a loop?
   The N+1 problem is the #1 cause of slow endpoints.
4. **Check the pool.** `pgxpool_acquire_count_total` + `pgxpool_acquire_duration` — slow
   acquires mean the pool is saturated.

## Common remedies

### 1. N+1 → join or batch

```go
// BAD — N+1
for _, projID := range ids {
    p, _ := repo.Load(ctx, tenant, projID)
    // ...
}

// GOOD — single query
projects, _ := repo.LoadMany(ctx, tenant, ids)
```

sqlc query for `LoadMany`:

```sql
-- name: LoadProjectsByIDs :many
SELECT * FROM projects
WHERE tenant_id = $1 AND id = ANY($2::uuid[]);
```

`pgx` natively supports `ANY($1::uuid[])` with a `[]uuid.UUID` parameter — sqlc generates
the right Go signature.

### 2. Pagination — cursor, not offset

```sql
-- BAD — OFFSET is O(N) — slow once N is large.
SELECT * FROM projects WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 50 OFFSET 10000;

-- GOOD — keyset / cursor — O(log N).
SELECT * FROM projects
WHERE tenant_id = $1 AND (created_at, id) < ($2, $3)
ORDER BY created_at DESC, id DESC
LIMIT 50;
```

The "cursor" is the last row's `(created_at, id)`; encode + base64 it for the API.

### 3. Read-side projection — don't reconstruct the entity

For lists, project straight to the response DTO in SQL (or in the sqlc-generated row),
and don't go through `domain.Restore`. Saves the constructor overhead and avoids loading
fields the response doesn't need.

### 4. Prepared statements — pgx caches them automatically

pgx's `pgxpool.Pool` prepares statements per connection on first execution and caches
them. This is essentially free in steady state; no work needed unless you're measuring a
high rate of new statements (sqlc generates a fixed set, so this is a non-issue in
practice).

### 5. Bulk inserts — `COPY` or `INSERT … VALUES (...), (...)`

```go
// pgx COPY — fastest for > 100 rows
_, err := conn.CopyFrom(ctx, pgx.Identifier{"projects"}, []string{"id","tenant_id","name", /*...*/},
    pgx.CopyFromRows(rows))
```

sqlc has `:copyfrom` for this. For < 100 rows, a multi-VALUES `INSERT` is simpler:

```sql
-- name: InsertProjectsBatch :exec
INSERT INTO projects (id, tenant_id, name, created_at)
SELECT unnest($1::uuid[]), $2::uuid, unnest($3::text[]), $4::timestamptz;
```

### 6. Indexes that match query order

The query `WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 50` is best served by
`CREATE INDEX ON projects (tenant_id, created_at DESC)` — the index serves both the
predicate AND the order, so Postgres can stop after 50 rows.

Composite indexes: leftmost-prefix rule. `(a, b, c)` serves `WHERE a=?`,
`WHERE a=? AND b=?`, `WHERE a=? AND b=? AND c=?` — but NOT `WHERE b=?` alone.

### 7. `LIMIT 1` for existence checks

```sql
-- BAD
SELECT COUNT(*) FROM projects WHERE tenant_id = $1 AND name = $2;

-- GOOD — short-circuits at the first match
SELECT 1 FROM projects WHERE tenant_id = $1 AND name = $2 LIMIT 1;
```

### 8. `EXISTS` vs `IN` for subqueries

For "does this id exist in another table", `EXISTS` is usually faster than `IN`:

```sql
WHERE EXISTS (SELECT 1 FROM members WHERE members.tenant_id = projects.tenant_id AND members.user_id = $2)
```

### 9. `jsonb` operators + GIN indexes

If you query inside JSONB:

```sql
-- @> is "contains" — supported by GIN
WHERE metadata @> '{"status": "active"}'::jsonb
-- Index:
CREATE INDEX idx_proj_meta ON projects USING gin (metadata);
```

Only index what you actually query. GIN indexes are large.

## Pool tuning

`cmd/api/main.go`:

```go
cfg, _ := pgxpool.ParseConfig(dbURL)
cfg.MaxConns        = 50              // sized to your DB max_connections / app instances
cfg.MinConns        = 4               // keep some warm
cfg.MaxConnIdleTime = 5  * time.Minute
cfg.MaxConnLifetime = 30 * time.Minute
cfg.HealthCheckPeriod = 1 * time.Minute
```

Monitor with `pool.Stat()`:
- `AcquireCount` / `AcquireDuration` — high duration = saturation.
- `IdleConns` / `MaxConns` — if `AcquiredConns` ≈ `MaxConns` for sustained periods, raise
  `MaxConns` (within the DB's `max_connections` budget) or scale instances down.

## Tracing every query

Wire `otelpgx` (or hand-roll a tracer) so every pgx call becomes a span:

```go
cfg.ConnConfig.Tracer = otelpgx.NewTracer()
```

The trace shows acquire time + query time + tenant scoping — invaluable for diagnosis.

## Antipatterns

- **`db.Query("SELECT * FROM ... WHERE x = '" + userInput + "'")`** — SQL injection. Always
  parameterize.
- **Loading whole tables into memory** to filter in Go. Push the filter to SQL.
- **`for _, row := range bigList { repo.Save(ctx, row) }`** — N round trips. Use a batch.
- **`time.Now()` inside the query loop** — clock skew + indeterminate timing. Capture
  once at the start.
- **Holding a `pgx.Conn` for the lifetime of a request** without releasing — pool exhaustion.
  `pool.Acquire(ctx)` requires `defer conn.Release()`.
- **Ignoring `rows.Err()`** after `for rows.Next()` — silent data loss on transport errors.
  `rowserrcheck` catches it.

## When sqlc isn't enough

A query with dynamic conditions sqlc can't express (e.g. user-built filters) → drop to raw
pgx with a hand-rolled query builder that uses an allow-list of columns. Document the
exception in the file:

```go
// pgx raw — sqlc can't express the dynamic WHERE clause. Allow-list ensures no injection.
```

## Tests

- Benchmark hot queries with `make bench` (BenchmarkFooRepository_LoadProject).
- `EXPLAIN ANALYZE` regression — for critical queries, paste the EXPLAIN output into a doc
  and re-check it on schema changes.
- Integration tests with realistic-size data — a 100-row table doesn't catch the issues
  a 100k-row table does. Use `make migrate-up` + a seed script to populate.
