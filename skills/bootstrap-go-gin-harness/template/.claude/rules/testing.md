---
description: Testing standards — unit vs. integration, table-driven, race detector, coverage gate, testcontainers, parallelism. Auto-loads on _test.go files and the integration test tree.
paths:
  - "**/*_test.go"
  - "test/**/*.go"
---

# Testing

Authoritative refs: `docs/projectStandards/testing-standards.md`, `write-unit-tests` and
`write-integration-tests` skills.

## Test taxonomy

| Layer | What it tests | Where | Build tag | DB? |
|---|---|---|---|---|
| **Unit** | Pure logic — domain entities, use-case handlers, helpers. No I/O. | colocated `foo_test.go` next to `foo.go` | (none) | No (or in-memory fake) |
| **Integration** | Endpoint → DB → response. Real PostgreSQL via testcontainers. | `test/integration/` | `//go:build integration` | Real, ephemeral |
| **Bench** | Performance of a hot path. | `foo_bench_test.go` or in `_test.go` | (none) | Usually no |
| **Eval** | LLM behaviour against a dataset. | `evals/<suite>/` | (separate driver) | Optional |

Run targets:
- `make test` → unit (`go test -race -shuffle=on -count=1 ./...`)
- `make test-integration` → integration (`go test -race -tags=integration ./test/integration/...`)
- `make bench` → benchmarks (`go test -run=^$ -bench=.`)
- `make cover` → unit + coverage gate
- `make evals` → eval suites (separate binary)

## Unit test conventions

- **Colocated**, package `foo` (white-box) when you need internal access; `foo_test`
  (black-box) when the public API suffices. Black-box catches more breaking changes.
- **One assertion per intent.** Use `assert` for non-fatal checks, `require` when the
  rest of the test depends on the value being correct.
- **Table-driven for any test with > 2 cases:**
  ```go
  func TestParseTenant(t *testing.T) {
      t.Parallel()
      cases := []struct {
          name    string
          input   string
          want    Tenant
          wantErr error
      }{
          {"valid uuid", "01HN...", Tenant{ID: ...}, nil},
          {"empty", "", Tenant{}, ErrInvalidTenant},
          {"malformed", "x", Tenant{}, ErrInvalidTenant},
      }
      for _, tc := range cases {
          tc := tc
          t.Run(tc.name, func(t *testing.T) {
              t.Parallel()
              got, err := ParseTenant(tc.input)
              if tc.wantErr != nil {
                  require.ErrorIs(t, err, tc.wantErr)
                  return
              }
              require.NoError(t, err)
              assert.Equal(t, tc.want, got)
          })
      }
  }
  ```
- **`t.Parallel()`** in every subtest that's safe to parallelize. `paralleltest` /
  `tparallel` linters enforce. **Capture loop vars** if you target Go < 1.22.
- **`t.Helper()`** at the top of any helper that calls `t.Errorf` / `t.Fatalf` so failures
  point at the caller. `thelper` linter enforces.
- **Fixtures**: prefer builders (`projectBuilder().WithTenant(t).Build()`) over JSON files
  unless the structure is genuinely shape-tested. Fixtures live near the test.
- **Time**: inject `clock` via interface where time matters; never `time.Now()` directly in
  testable code. `clockwork` or a hand-rolled fake.
- **Random**: seed deterministically per test (`rand.New(rand.NewSource(42))`); never global
  `rand`.
- **No `time.Sleep`** in tests — synchronize with channels or `eventually` helpers.

## Integration test conventions

- **`//go:build integration`** on the first line; CI runs them separately so unit tests
  stay fast.
- **`testcontainers-go` for the database** — never a mocked DB at this layer. Each test
  package starts a Postgres container, applies migrations, and tears down via `t.Cleanup`:
  ```go
  //go:build integration

  func TestMain(m *testing.M) {
      ctx := context.Background()
      pg, err := postgres.Run(ctx, "postgres:16-alpine",
          postgres.WithDatabase("test"),
          postgres.WithUsername("test"),
          postgres.WithPassword("test"))
      if err != nil { log.Fatal(err) }
      defer pg.Terminate(ctx)
      // apply migrations against pg.ConnectionString(ctx)
      os.Exit(m.Run())
  }
  ```
- **Schema fresh per package** is the default. For expensive setup, share the container
  across tests in the package but `TRUNCATE` (or roll back a transaction) between tests.
- **`httptest.NewServer`** to spin up the Gin handler; never bind to a fixed port.
- **Real HTTP calls** to assert wire behaviour (`http.Client` against the test server) —
  this is where contract regressions get caught.
- **Tenant isolation tests**: every integration test that asserts a tenant boundary creates
  TWO tenants and confirms tenant A cannot see tenant B's data. This is the most important
  test we write.

## The race detector — non-negotiable

- `go test -race` on every test run. The Makefile bakes it in.
- A race detected in CI is a bug — fix it, do not suppress (`-race` has no suppression
  mechanism beyond removing the test, which is forbidden).
- Some tests legitimately need synchronization helpers (e.g. waiting for a goroutine to
  start before assertion). Use channels / `sync.Once` — never `time.Sleep`.

## Coverage gate

`scripts/check-coverage.sh` enforces per-package thresholds (80% for `internal/domain/**`
and `internal/app/**`; 60% elsewhere). Override per-run via `make cover COVER_MIN_DOMAIN=85`.

**A drop below the threshold fails CI.** Restore coverage by writing tests for the uncovered
lines, OR justify the exclusion in a comment in the file itself:

```go
// coverage:ignore — pure passthrough; tested via integration
func wireRouter(r *gin.Engine) { … }
```

## Mocks vs. fakes

- **Fakes** (in-memory implementations of an interface) are preferred for code you control.
  The fake lives in the same package as the interface (`fakeRepository struct { … }`).
- **Mocks** (gomock / mockery) require per-module approval and are only justified for third-
  party interfaces that we can't reasonably fake.
- **Never `nil`-mock** — a `nil` interface that calls `m.EXPECT()` panics on the first
  unexpected call. Better: write a small fake.

## What NOT to test

- The standard library. `time.Now()` returns a time; `json.Marshal` round-trips. Don't.
- Generated code (sqlc). The integration test covers the path; unit-testing the generated
  code is testing sqlc itself.
- Trivial getters/setters. If the code has neither logic nor side effects, the test buys
  nothing.

## Test failures and reporting

- **Report EXACT counts**: `passed: 42 / failed: 0 / skipped: 1 / total: 43`. Never "tests
  pass".
- **When a test fails**: read the failure first; don't re-run hoping for green. Flaky tests
  are bugs.
- **`-shuffle=on`** detects ordering dependencies — keep it on.

## Test data discipline

- **Tenant ids are realistic** (UUIDv7) in tests too — bugs hide when test ids are `"abc"`.
- **No real customer data** in test fixtures. Synthetic or sanitized only.
- **Builders over literals** for multi-field types — readability and refactor resilience.
