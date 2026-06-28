# {{ProductName}} — Testing standards

> The single source of truth for how we test Go in this repo. The rules are in
> `.claude/rules/testing.md` (auto-loaded on `*_test.go`); this doc is the *why* and the
> shape of the testing program as a whole.

## Three layers

| Layer | What it tests | Where | Build tag | Speed | DB? |
|---|---|---|---|---|---|
| **Unit** | Pure logic — domain entities, use-case handlers, helpers. No I/O. | colocated `foo_test.go` next to `foo.go` | (none) | Fast (ms) | No (in-memory fake) |
| **Integration** | Endpoint → DB → response, real migrations, real RLS. | `test/integration/` | `//go:build integration` | Slow (~seconds; container startup) | Real, ephemeral (testcontainers) |
| **Bench** | Performance of a hot path. | `_test.go` colocated | (none) | Variable | Usually no |
| **Eval** (LLM features only) | Model output quality against a dataset. | `evals/<suite>/` | separate runner | Slow + costs tokens | Optional |

Run targets:
- `make test` — unit, race detector, shuffled, `count=1`.
- `make test-integration` — integration, race detector, `tags=integration`.
- `make bench` — benchmarks, `count=5`, with memory stats.
- `make cover` — unit + coverage gate.
- `make evals` — eval suites.
- `make ci` — everything except evals.

## Unit tests

- **Colocated** with code: `foo_test.go` next to `foo.go`.
- **Package**: `foo` (white-box) when you need internal access; `foo_test` (black-box) by
  default. Black-box catches more breaking changes.
- **Table-driven** for any test with > 2 cases. `t.Run(name, ...)` per case;
  `t.Parallel()` where safe.
- **`require` for fatal, `assert` for non-fatal** (testify). Multiple `assert.X` per test
  is fine and often more informative than one `assert.Equal` on a big struct.
- **No mocks for code you control** — write a fake (in-memory implementation of the
  interface) in the test file or a `testdata/` helper. Mocks (gomock / mockery) only for
  third-party interfaces and only via per-module approval.
- **Inject the clock** — never `time.Now()` in testable code.
- **Seed any randomness** — deterministic per test.
- **No `time.Sleep`** — use channels / condition variables / `eventually` helpers.

## Integration tests

- **`//go:build integration`** on the first line.
- **testcontainers-go for PostgreSQL** — one container per test PACKAGE (not per test;
  ~5s startup each → would take forever). Share via `TestMain` + `truncate` between
  tests.
- **`goose.Up` applied to the container** at startup. A broken migration fails the
  integration suite — the right place to find out.
- **`httptest.NewServer`** to spin up the Gin handler against a real HTTP transport.
- **Real HTTP client** (`http.Post`, etc.) — asserts the wire contract, catches drift
  between handler and documented response.
- **Tenant isolation tests are mandatory.** For every tenant-scoped feature: two
  tenants, assert isolation. The single most important test you write.
- **`t.Cleanup(truncate)`** to wipe between tests; never share state across tests in a
  package.

## Benchmarks

- **`func BenchmarkX(b *testing.B)`** in any `_test.go` file.
- **`b.ResetTimer()`** after setup.
- **`-benchmem`** mandatory — allocations matter as much as latency.
- **`-count=5` minimum** for noise tolerance.
- **`benchstat` for comparison** — before/after baselines, statistical significance.
- See `.claude/skills/benchmarking/SKILL.md` for the full procedure.

## Race detector — non-negotiable

- **`-race` on every `go test`**. The Makefile bakes it in.
- A race in CI is a bug; fix it, don't suppress (`-race` has no suppression mechanism).
- Cost: 2–5× slower, more memory. Worth every cycle.

## Coverage gate

`make cover` enforces per-package thresholds via `scripts/check-coverage.sh`:

- **`internal/domain/**` and `internal/app/**`** → 80% (business logic).
- **Everywhere else** → 60% (boilerplate / adapters).

Override per-run: `make cover COVER_MIN_DOMAIN=85`. A drop below threshold fails CI.
Exclusions need a `// coverage:ignore` comment in the file with a justification.

**Coverage is necessary, not sufficient.** A 90% line-covered package with no edge-case
asserts is well-tested for compilation, not for correctness. Combine coverage with the
exact-test-list discipline from the plan format.

## Test data discipline

- **Realistic ids** — UUIDv7 strings, not `"abc"`. Bugs hide in unrealistic ids.
- **Synthetic data only** — no customer data in fixtures.
- **Builders over literal struct construction** for multi-field types — readable +
  refactor-resilient.
- **Time** — fixed UTC times in tests (`time.Date(2026, 6, 20, 12, 0, 0, 0, time.UTC)`),
  injected via `fakeClock`.

## Test failure discipline

- **Exact counts** in the report: `passed: 42 / failed: 0 / skipped: 1 / total: 43`.
  Never "tests pass".
- **A failing test surfaces a real bug** — fix it. Never weaken / skip / delete a test
  to go green. The "fix" is to address the bug the test caught.
- **Flaky tests are bugs.** A test that passes 9/10 has a race, an ordering dependency,
  or a real timing issue. Find and fix; don't `t.Skip` it.
- **`-shuffle=on`** detects ordering bugs; keep it on.

## What to test, what NOT to test

| ✓ Test | ✗ Don't test |
|---|---|
| Domain invariants (every case) | Trivial getters / setters |
| Business validators (every rule) | Standard library behaviour |
| Use-case handlers (every result.Error type returned) | Generated code (sqlc rows) directly |
| Tenant isolation (every tenant-scoped endpoint) | Internal helpers with no semantic |
| Race conditions (every concurrent code path) | Code paths that are exclusively tested via integration tests |
| Error wrapping (assert errors.Is / errors.As) | Wrappers that just re-emit (covered by callers) |

## Mocks vs. fakes

| | Mock | Fake |
|---|---|---|
| What | Verifies *calls* (gomock / mockery) | In-memory *implementation* (hand-written) |
| When | Third-party interface you can't control | Code you control |
| Pros | Records call args / call order | Closer to real behaviour; flexible asserts |
| Cons | Brittle (re-records on every internal change); coupling to implementation | Slightly more code |

**Default: fake.** Reach for a mock only when there's no other way (and approve the
library per-module).

## Testing concurrent code

- Use `errgroup.Group.Wait()` to wait deterministically.
- Channels + `select` for synchronization, never `time.Sleep`.
- `testing/synctest` (Go 1.24+) for deterministic concurrent tests — adopt when the
  API stabilizes.
- Race detector finds the bugs you'd never see in single-threaded tests; ALWAYS run with
  `-race`.

## When the test you need can't be written

Surface as a plan deviation: "the plan asks for TestX_Y but X is not testable as written
(e.g. it depends on an unmocked clock; the random seed leaks; the fake DB doesn't
implement Y). Recommendation: <fix the testability gap>." Don't silently skip.

## See also

- `.claude/rules/testing.md` — auto-loaded distillation.
- `.claude/skills/write-unit-tests/SKILL.md` — procedure + templates.
- `.claude/skills/write-integration-tests/SKILL.md` — testcontainers patterns.
- `.claude/skills/race-detector/SKILL.md` — race report interpretation.
- `.claude/skills/benchmarking/SKILL.md` — bench procedure.
