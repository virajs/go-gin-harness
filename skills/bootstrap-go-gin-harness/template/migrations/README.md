# migrations/

PostgreSQL migrations managed by [goose](https://pressly.github.io/goose/).

## Layout

```
migrations/
├─ README.md                              (this file)
├─ 001_init_<feature>.up.sql
├─ 001_init_<feature>.down.sql
├─ 002_<change>.up.sql
├─ 002_<change>.down.sql
└─ ...
```

## Commands (via the Makefile)

```bash
make migrate-up                              # apply all pending
make migrate-down                            # roll back one (asks confirmation)
make migrate-status                          # show applied / pending
NAME=add_documents make migrate-new          # scaffold a new pair
```

Underlying:
```bash
goose -dir migrations postgres "$DB_URL" up
```

## Hard rules

- **Append-only.** Never edit an applied migration. Write a new one to fix.
- **Real down migrations.** `goose down` works in dev (protect-commands hook asks for
  confirmation). The down direction is not optional.
- **Run in integration tests.** `TestMain` in `test/integration/` runs `goose.Up`
  against testcontainers Postgres before tests; a broken migration fails the suite.
- **No-tx blocks for `CREATE INDEX CONCURRENTLY`**:
  ```sql
  -- +goose Up
  -- +goose NO TRANSACTION
  CREATE INDEX CONCURRENTLY ...;
  ```
- **Snake_case** for tables and columns (PostgreSQL folds unquoted identifiers to lower).
- **`timestamptz`** for time columns; never `timestamp`. All `time.Time` values are UTC.
- **`uuid` primary keys**; never `bigserial` for new entities (UUIDv7 minted in domain).
- **Enable RLS** on every tenant-scoped table:
  ```sql
  ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON <table>
      USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
      WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
  ```

## See also

- `.claude/rules/backend/persistence.md` — auto-loaded persistence rules.
- `.claude/skills/sqlc-patterns/SKILL.md` — sqlc + repository wiring.
- `docs/projectStandards/backend-architecture.md` — overall persistence design.
