# test/

Integration tests (build-tag `integration`) and shared test fixtures.

Unit tests live colocated with the code under test (`internal/.../*_test.go`); only
integration tests + their helpers live here.

## Layout

```
test/
├─ README.md                              (this file)
├─ integration/
│  ├─ projects_integration_test.go        one file per feature
│  ├─ documents_integration_test.go
│  └─ shared/                              shared harness (db setup, http client, auth)
│     ├─ pg.go                             testcontainers + goose.Up
│     ├─ server.go                         httptest server + injected middleware
│     └─ fixtures.go                       reusable builders
└─ fixtures/                               cross-test sample data (JSON, SQL seed, etc.)
```

## Running

```bash
make test-integration                     # runs the whole integration suite
go test -race -tags=integration ./test/integration/...
```

Requires Docker (for testcontainers PostgreSQL). CI runs the integration suite as a
separate job from unit tests.

## Hard rules

- **`//go:build integration`** on the first line of every test file.
- **testcontainers-go for PostgreSQL** — never a mocked DB. One container per test
  PACKAGE, shared via `TestMain` + `truncate` between tests.
- **Migrations applied via `goose.Up`** — exercises the real DDL.
- **`httptest.NewServer`** for HTTP — assert via real HTTP requests.
- **Tenant isolation tests are mandatory** — two tenants, assert isolation. The most
  important class of test we write.
- **Race detector**: `go test -race -tags=integration`. The Makefile bakes it in.

## See also

- `.claude/skills/write-integration-tests/SKILL.md` — full procedure + template.
- `.claude/rules/testing.md` — auto-loaded testing rules.
- `docs/projectStandards/testing-standards.md` — testing program overview.
