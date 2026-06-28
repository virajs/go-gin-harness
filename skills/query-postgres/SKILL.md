---
name: query-postgres
description: Run read-only SQL against the {{ProductName}} PostgreSQL database to investigate or verify data during diagnosis. Use when asked to query the database directly or check actual data behind an issue.
allowed-tools: Read, Glob, Grep, Bash
---

# Query PostgreSQL (read-only)

This skill is preloaded by the `rca-investigator` agent. It walks the safe pattern for
ad-hoc SQL diagnosis.

## Hard rules

- **READ ONLY.** `SELECT`, `EXPLAIN`, `\d`. NEVER `INSERT` / `UPDATE` / `DELETE` /
  `DROP` / `TRUNCATE` / `ALTER` / `CREATE`. The `protect-commands.sh` hook gates
  destructive SQL; respect the gate.
- **Use a transaction with `ROLLBACK`** for anything that *could* mutate, even by
  accident. `BEGIN; <select>; ROLLBACK;` makes the intent explicit.
- **Read-only role**, ideally. The harness assumes you have a credential set with
  SELECT-only privileges; use it for diagnosis.
- **Tenant scope, always.** Add `WHERE tenant_id = '<uuid>'` to every query touching a
  tenant-scoped table — never `SELECT * FROM projects` unqualified, even for "just
  looking".
- **Show evidence, not hypotheses.** Paste the actual query + the actual result rows
  (redacted if necessary). Never paraphrase.

## How to invoke

The harness defaults to invoking `psql` (or `pgcli`) against a connection URL the user
configures. Pattern:

```bash
PGPASSWORD=... psql "$DB_URL" -At -c "SELECT id, tenant_id, archived
FROM projects
WHERE tenant_id = '01HN...' AND created_at >= '2026-01-01'
ORDER BY created_at DESC
LIMIT 20;"
```

- `-At` — un-aligned, no tuples-only header. Cleaner for piping to grep / awk.
- Quote the SQL — don't let shell substitution touch it.
- Capture the output verbatim in the report.

For deeper exploration: `psql "$DB_URL"` interactive, but in this skill you'll usually
run one-shot queries.

## Common diagnostic queries

### Row counts by tenant
```sql
SELECT tenant_id, COUNT(*) AS rows
FROM projects
GROUP BY tenant_id
ORDER BY rows DESC
LIMIT 20;
```

### Find a "recent failure"
```sql
SELECT *
FROM audit_events
WHERE tenant_id = '01HN...'
  AND event_type IN ('error', 'failure')
  AND ts > now() - INTERVAL '1 hour'
ORDER BY ts DESC
LIMIT 50;
```

### Schema inspection
```sql
\d projects                 -- table structure, indexes, constraints, FKs
\di+                        -- all indexes with size
\dt+ <schema>.*             -- all tables with size
SELECT version();           -- PG version
```

### EXPLAIN ANALYZE
```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
  SELECT id FROM projects
  WHERE tenant_id = $1 AND archived = false
  ORDER BY created_at DESC
  LIMIT 50;
```

Look for `Seq Scan` (probably missing an index), row-estimate vs. actual divergence, sort
costs.

### Index health
```sql
SELECT
    relname  AS table_name,
    idx.indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS rows_read,
    pg_size_pretty(pg_relation_size(idx.indexrelid)) AS size
FROM pg_stat_user_indexes idx
JOIN pg_stat_user_tables  t ON t.relid = idx.relid
ORDER BY scans DESC;
```

### Tenancy / RLS smoke test
```sql
-- Confirm RLS is enabled on a tenant-scoped table.
SELECT schemaname, tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public' AND tablename = 'projects';

-- List policies.
SELECT * FROM pg_policies WHERE tablename = 'projects';
```

## Reporting evidence

For every claim in the report:

```
> SELECT id, tenant_id, archived FROM projects WHERE id = '01HN...';
 id        | tenant_id        | archived
-----------+-------------------+----------
 01HN...   | 01HM...           | false
(1 row)
```

Verbatim. Include the query and the output, not a summary.

## What this skill DOES NOT do

- Mutate data (use a separate, gated migration / fix workflow).
- Run an `EXPLAIN ANALYZE` on a production DB that locks tables (`ANALYZE` itself is
  generally safe but check the table's lock posture for unusual workloads).
- Dump the full table — page-by-page if you need to enumerate.
- Bypass tenant scoping. Even for support / debugging, the SystemContext pattern (see
  `tenancy.md`) is the only legitimate path.

## Common mistakes (don't)

- `SELECT *` from a large table for "just looking". Add a `LIMIT`.
- Forgetting `tenant_id` in the WHERE clause. You'll see every tenant's data when you
  meant only one — and if you grep through the output you may accidentally leak it into
  the report.
- Mistyping `UPDATE` for `SELECT`. Always type the verb first; the hook asks before
  running.
- Pasting credentials in the query. Use `PGPASSWORD` env var or `.pgpass`.
