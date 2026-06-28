---
name: write-integration-tests
description: Write Go integration tests with testcontainers-go — real PostgreSQL, real HTTP, real migrations. Build-tagged 'integration'. Use when validating an endpoint→DB path or anything that touches infrastructure.
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash
---

# Write integration tests

Source of truth: `.claude/rules/testing.md`, `docs/projectStandards/testing-standards.md`.

## What "integration" means here

- Exercises a real PostgreSQL container (via `testcontainers-go`).
- Spins up the Gin handler and hits it with real HTTP (via `httptest.NewServer`).
- Build tag `//go:build integration` so the integration suite runs separately from
  fast-path unit tests (`make test-integration`).
- **Required for every endpoint** that touches the DB; integration tests catch bugs unit
  tests never will (real migrations, real RLS, real type coercion).

## Layout

```
test/
├─ integration/
│  ├─ projects_integration_test.go   one file per feature; testcontainers + Gin
│  └─ shared/                        shared harness helpers (db setup, http client)
└─ fixtures/                          shared builders, sample data
```

## Template — full integration test

```go
//go:build integration

package integration

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "net/http/httptest"
    "os"
    "testing"
    "time"

    "github.com/google/uuid"
    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/pressly/goose/v3"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
    tcwait "github.com/testcontainers/testcontainers-go/wait"

    api "{{ProjectName}}/internal/api"
    appprojects "{{ProjectName}}/internal/app/projects"
    persistprojects "{{ProjectName}}/internal/infra/persistence/projects"
)

// TestMain — start once per package, share the container across tests.
var dbPool *pgxpool.Pool

func TestMain(m *testing.M) {
    ctx := context.Background()
    pg, err := postgres.Run(ctx, "postgres:16-alpine",
        postgres.WithDatabase("test"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
        postgres.BasicWaitStrategies(),
        postgres.WithSQLDriver("pgx"),
    )
    if err != nil { panic(fmt.Sprintf("start postgres: %v", err)) }
    defer pg.Terminate(ctx) //nolint:errcheck // best effort

    connStr, err := pg.ConnectionString(ctx, "sslmode=disable")
    if err != nil { panic(err) }

    // Apply migrations.
    sqlDB, err := sql.Open("pgx", connStr)
    if err != nil { panic(err) }
    goose.SetBaseFS(nil)
    if err := goose.SetDialect("postgres"); err != nil { panic(err) }
    if err := goose.Up(sqlDB, "../../migrations"); err != nil { panic(err) }
    _ = sqlDB.Close()

    dbPool, err = pgxpool.New(ctx, connStr)
    if err != nil { panic(err) }
    defer dbPool.Close()

    os.Exit(m.Run())
}

// truncate — call from each test's t.Cleanup to wipe between tests.
func truncate(t *testing.T) {
    t.Helper()
    _, err := dbPool.Exec(context.Background(), "TRUNCATE projects RESTART IDENTITY CASCADE")
    require.NoError(t, err)
}

// newServer — build a Gin engine bound to a specific tenant context, for one test.
func newServer(t *testing.T, tenant string) *httptest.Server {
    t.Helper()
    repo  := persistprojects.New(dbPool)
    clock := realClock{}
    handler := appprojects.NewCreateProjectHandler(repo, clock)
    r := api.NewRouter(api.Dependencies{
        CreateProject: handler,
        // ...
    })
    // Inject a fake auth/tenancy middleware for tests — sets the tenant we choose.
    srv := httptest.NewServer(injectTenantMiddleware(tenant, r))
    t.Cleanup(srv.Close)
    return srv
}

// --- the test ---

func TestProjects_Create_Integration_PersistsToDB(t *testing.T) {
    t.Cleanup(func() { truncate(t) })

    tenant := uuid.NewString()
    srv := newServer(t, tenant)

    // POST /v1/projects
    body := `{"name": "Integration Test"}`
    resp, err := http.Post(srv.URL+"/v1/projects", "application/json", bytes.NewReader([]byte(body)))
    require.NoError(t, err)
    defer resp.Body.Close()
    require.Equal(t, http.StatusCreated, resp.StatusCode)

    var created struct {
        ID        string    `json:"id"`
        Name      string    `json:"name"`
        CreatedAt time.Time `json:"created_at"`
    }
    require.NoError(t, json.NewDecoder(resp.Body).Decode(&created))
    assert.NotEmpty(t, created.ID)

    // Verify the row exists with the right tenant.
    var rowTenant string
    err = dbPool.QueryRow(context.Background(),
        `SELECT tenant_id::text FROM projects WHERE id::text = $1`, created.ID).Scan(&rowTenant)
    require.NoError(t, err)
    assert.Equal(t, tenant, rowTenant)
}

// --- the MOST IMPORTANT test for any tenant-scoped feature ---

func TestProjects_TenantIsolation_Integration_TenantACannotReadTenantB(t *testing.T) {
    t.Cleanup(func() { truncate(t) })

    tenantA := uuid.NewString()
    tenantB := uuid.NewString()

    // Tenant B creates a project.
    srvB := newServer(t, tenantB)
    respB, _ := http.Post(srvB.URL+"/v1/projects", "application/json",
        bytes.NewReader([]byte(`{"name":"B's project"}`)))
    require.Equal(t, http.StatusCreated, respB.StatusCode)
    var createdB struct{ ID string `json:"id"` }
    json.NewDecoder(respB.Body).Decode(&createdB)
    respB.Body.Close()

    // Tenant A tries to read it.
    srvA := newServer(t, tenantA)
    respA, _ := http.Get(srvA.URL + "/v1/projects/" + createdB.ID)
    // 404 (not "forbidden" — leaking existence is itself a leak).
    require.Equal(t, http.StatusNotFound, respA.StatusCode)
}
```

## Hard rules

- **`//go:build integration`** as the first line. No build tag → it runs in unit tests
  and slows everything down.
- **One container per test PACKAGE**, not per test. Use `TestMain` + truncate/rollback
  between tests.
- **Migrations applied via `goose.Up`** against the container — exercises the real DDL
  every time. A broken migration fails the suite here, which is the right place.
- **No mocks at this layer.** Real PG, real HTTP, real migrations, real query plans.
- **Tenant isolation tests are mandatory.** Two tenants, assert isolation. The most
  important test you write.
- **Race detector**: `go test -race -tags=integration`. The Makefile bakes it in.
- **Don't share state between tests** in the package without a teardown — `t.Cleanup` to
  truncate.
- **Assert response shape against the OpenAPI spec.** Every integration test for an
  endpoint should verify the response payload conforms to its OpenAPI operation. Two
  practical patterns:
  - **Runtime validator (recommended)**: at `TestMain`, load `docs/api/openapi.yaml`
    with `kin-openapi`'s `loader.LoadFromFile`; build a `routers.Router`; in each test,
    call `router.FindRoute(req)` + `openapi3filter.ValidateResponse` against the
    captured response. Catches drift on every test run.
  - **Targeted schema check**: parse the response JSON; assert required fields present,
    types match, unexpected fields absent. Less coverage, more code per test.
  Under spec-first (oapi-codegen) projects, the compile-time interface gives some of
  this for free; under code-first or manual, the runtime validator is the safety net.
  See the `openapi-spec` skill for the loader setup.

## Running

```bash
# Run integration suite (requires Docker for testcontainers):
make test-integration
# Equivalent:
go test -race -tags=integration -count=1 ./test/integration/...

# Skip integration when you don't have Docker handy (CI may set this):
SKIP_INTEGRATION=1 make test
```

## When NOT to integration-test

- Pure domain logic. Unit-test it; integration adds nothing.
- Code paths fully covered by unit tests against the in-memory fake.
- Performance — integration tests are slow; benchmark separately.

## Common mistakes (don't)

- One container per test (~5s overhead per test → suite takes 30+ minutes).
- Reusing rows across tests without truncating — flaky tests.
- Hard-coding ports — `httptest` picks free ports, never `:8080`.
- Forgetting `defer resp.Body.Close()` — leaks connections under load.
- Asserting JSON via string `==` — compare decoded structs.
- Asserting database state via the same query the handler uses — go around the handler;
  query directly to verify.

## Reporting

```
passed: 18 / failed: 0 / skipped: 0 / total: 18 (integration)
container: postgres:16-alpine, startup 2.3s
migrations applied: 7
race: clean
total wall time: 14.2s
```

If integration tests are slow, that's a signal — but the right slowness target is "tens
of seconds for a small suite, low minutes for a large one". > 5 minutes is a code smell.
