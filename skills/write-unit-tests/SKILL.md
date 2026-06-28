---
name: write-unit-tests
description: Write and run Go unit tests per a plan's exact test list — colocated _test.go, table-driven, race detector, exact pass/fail/skip counts, never weakening a test. Use when adding or changing unit tests under internal/ or pkg/.
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash
---

# Write unit tests

Source of truth: `.claude/rules/testing.md`, `docs/projectStandards/testing-standards.md`.

## What "unit" means here

- Tests one package's API in isolation.
- No network, no real DB, no real LLM. **In-memory fakes** for code you control;
  hand-written mocks (no `gomock`) only for third-party interfaces.
- Race detector ON.
- Lives in the same directory as the code under test (`foo_test.go` next to `foo.go`).

## Procedure

1. **Read the plan's exact test list** (or the spec from the user). Each named test
   asserts exactly what the plan guards.
2. **Place the file**: `internal/<area>/<package>/<name>_test.go`.
3. **Pick the package**:
   - **White-box** (`package foo`): when you need to call unexported functions / use
     internal types. Used for domain entities and any package where invariants are
     enforced internally.
   - **Black-box** (`package foo_test`): when the public API suffices. Catches more
     breaking changes. Default for use-case handlers.
4. **Write the test.** Use the template below.
5. **Run**: `go test -race -count=1 -shuffle=on ./...` (or scoped). Report exact counts.

## Template — basic test

```go
package projects

import (
    "testing"
    "time"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestNewProject_Happy(t *testing.T) {
    t.Parallel()

    now := time.Date(2026, 6, 20, 12, 0, 0, 0, time.UTC)
    p, err := New("tenant-x", "my-project", now)

    require.NoError(t, err)
    require.NotNil(t, p)
    assert.NotEmpty(t, p.ID())
    assert.Equal(t, TenantID("tenant-x"), p.TenantID())
    assert.Equal(t, "my-project", p.Name())
    assert.False(t, p.Archived())
    assert.Equal(t, now, p.CreatedAt())
}

func TestNewProject_EmptyTenant_ReturnsErrTenantRequired(t *testing.T) {
    t.Parallel()

    _, err := New("", "x", time.Now())

    require.ErrorIs(t, err, ErrTenantRequired)
}
```

## Template — table-driven (for > 2 cases)

```go
func TestNewProject_NameValidation(t *testing.T) {
    t.Parallel()

    cases := []struct {
        name     string
        input    string
        wantErr  error
    }{
        {"empty name",  "",                      ErrInvalidName},
        {"too long",    strings.Repeat("x", 200), ErrInvalidName},
        {"minimal",     "a",                     nil},
        {"with space",  "my project",            nil},
    }
    for _, tc := range cases {
        tc := tc // (Go 1.22+ no longer needs this; defensive for older versions)
        t.Run(tc.name, func(t *testing.T) {
            t.Parallel()
            _, err := New("tenant-x", tc.input, time.Now())
            if tc.wantErr != nil {
                require.ErrorIs(t, err, tc.wantErr)
                return
            }
            require.NoError(t, err)
        })
    }
}
```

## Template — handler test with fake repo

```go
package projects_test

import (
    "context"
    "errors"
    "testing"
    "time"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"

    "{{ProjectName}}/internal/app/projects"
    domprojects "{{ProjectName}}/internal/domain/projects"
    "{{ProjectName}}/internal/shared/result"
)

// fakeRepo — in-memory stand-in. Hand-written; no mock framework.
type fakeRepo struct {
    saved   []*domprojects.Project
    saveErr error
}

func (f *fakeRepo) Save(_ context.Context, p *domprojects.Project) error {
    if f.saveErr != nil { return f.saveErr }
    f.saved = append(f.saved, p)
    return nil
}
func (f *fakeRepo) Load(_ context.Context, _ domprojects.TenantID, _ domprojects.ID) (*domprojects.Project, error) {
    return nil, domprojects.ErrNotFound
}

type fakeClock struct{ now time.Time }
func (c fakeClock) Now() time.Time { return c.now }

func TestCreateProject_Happy(t *testing.T) {
    t.Parallel()

    repo  := &fakeRepo{}
    clock := fakeClock{now: time.Date(2026, 6, 20, 12, 0, 0, 0, time.UTC)}
    h     := projects.NewCreateProjectHandler(repo, clock)

    resp, err := h.Handle(context.Background(), projects.CreateProjectCommand{
        TenantID: "tenant-x", Name: "my-proj",
    })

    require.NoError(t, err)
    require.NotNil(t, resp)
    assert.NotEmpty(t, resp.ID)
    require.Len(t, repo.saved, 1)
    assert.Equal(t, "my-proj", repo.saved[0].Name())
}

func TestCreateProject_RepoFails_WrapsError(t *testing.T) {
    t.Parallel()

    repo := &fakeRepo{saveErr: errors.New("db down")}
    h := projects.NewCreateProjectHandler(repo, fakeClock{now: time.Now().UTC()})

    _, err := h.Handle(context.Background(), projects.CreateProjectCommand{
        TenantID: "tenant-x", Name: "x",
    })

    require.Error(t, err)
    // The error is wrapped, not raw — the API mapper relies on the chain.
    assert.Contains(t, err.Error(), "db down")
}

func TestCreateProject_InvalidName_ReturnsValidationError(t *testing.T) {
    t.Parallel()

    h := projects.NewCreateProjectHandler(&fakeRepo{}, fakeClock{now: time.Now().UTC()})

    _, err := h.Handle(context.Background(), projects.CreateProjectCommand{
        TenantID: "tenant-x", Name: "",
    })

    var rerr *result.Error
    require.ErrorAs(t, err, &rerr)
    assert.Equal(t, result.TypeValidation, rerr.Type)
    assert.Contains(t, rerr.Failures, "name")
}
```

## Hard rules

- **`t.Parallel()`** in every subtest that's safe. `paralleltest` linter enforces.
- **`t.Helper()`** at the top of any helper. `thelper` linter enforces.
- **`require.X` when the rest of the test depends on success**; `assert.X` for non-fatal
  checks (multiple assertions per test, each independently informative).
- **Don't weaken a test to get green.** If a test reveals a real bug, report it; never
  comment-out / skip / lower the assertion. The bug is the finding.
- **No `time.Sleep`** — use channels, `eventually` helpers, or fakes.
- **Determinism** — seed any randomness; inject the clock.
- **Don't test third-party libraries.** No `TestJSONMarshal_DoesItRoundTrip`.
- **Don't test trivial getters** (no `TestProject_ID_ReturnsID`). The test buys nothing.
- **Don't reach into private state across packages**. Black-box where possible.

## Running

```bash
# All unit tests, race detector, shuffle for ordering bugs, count=1 to disable cache:
go test -race -count=1 -shuffle=on ./...

# Scoped:
go test -race -count=1 ./internal/domain/projects/...

# Verbose:
go test -race -v ./internal/domain/projects/...

# With coverage (for one package):
go test -race -cover -coverprofile=cover.out ./internal/domain/projects/...
go tool cover -func=cover.out

# Coverage gate (whole repo):
make cover
```

## Reporting

ALWAYS report exact counts:

```
passed: 42 / failed: 0 / skipped: 1 / total: 43
race: clean
new test files: internal/app/projects/create_project_test.go
coverage on internal/app/projects: 87.5% (gate: 80%, +1.2% from baseline)
```

Never "tests pass" — exact counts.

## When a test surfaces a real defect

- **Report it.** Do NOT silently weaken the assertion to make green.
- Add a note: "Test TestX_Y_Z expected behavior X but the implementation does Y. This is
  a plan deviation: <severity>."
- Hand back the question to the plan author / main agent.

## Common mistakes (don't)

- One giant test with 20 assertions. Split into table-driven cases.
- Using `time.Now()` directly in the test. Inject the clock.
- Asserting `err != nil` when you mean `errors.Is(err, ErrSpecific)`. Be precise.
- `assert.True(t, x == y)` instead of `assert.Equal(t, x, y)`. The second gives a useful
  diff.
- Tests in a different package without re-exporting test helpers. The convention is
  `<pkg>_test` package + a `testdata/` folder for fixtures.
