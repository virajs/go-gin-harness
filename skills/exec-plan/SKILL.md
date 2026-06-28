---
name: exec-plan
description: Generate an implementation plan in the house format — locked decisions, ordered checklist, code samples with absolute paths, exact named-test list, OPEN QUESTIONS. Use when the user asks "plan this", "draft an exec plan", or before any non-trivial change. The plan is a build-from-this contract, not a sketch.
argument-hint: <topic> (e.g. "add projects feature")
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill, Agent, Workflow
---

# Generate an exec plan

A plan is a **build-from-this contract** in the house format
(`docs/projectStandards/implementation-plan-format.md`). When the implementer reads it
later, every consequential decision is already pinned; the implementation is mechanical.

## Two ways to invoke

1. **Lightweight (single-agent)**: you (main agent) draft the plan yourself. Good for
   small, well-understood changes.
2. **Heavyweight (workflow)**: delegate to `exec-plan-build` which fans out recon agents,
   drafts via the `exec-planner` agent, and adversarially reviews. Good for non-trivial
   plans where missing recon = missing locked decisions.

For most plans → use the workflow:

```javascript
Workflow({
  name: "exec-plan-build",
  args: {
    topic: "Add projects feature",
    request: "<full user request, verbatim>",
    scope: ["domain", "app", "api", "persistence", "tests"],
    outputPath: "docs/exec-plans/add-projects.md"
  }
})
```

## The house format

Read `docs/projectStandards/implementation-plan-format.md` for the canonical spec. The
template:

```markdown
# <Topic>

## Goal — one sentence
ONLY do X. NEVER do Y. (Scope boundary in the same breath as the goal.)

## Locked decisions
| ID | Decision | Alternative considered | Why this one |
|----|----------|------------------------|--------------|
| D1 | Use sqlc-generated typed queries | hand-rolled pgx | Compile-time type safety; we already use sqlc |
| D2 | Project ids are UUIDv7 minted in domain | DB-generated bigserial | Distributed-friendly, sortable, matches existing pattern |
| D3 | List query uses cursor pagination | offset | O(log N) at scale; offset breaks > 10k rows |

## Roadmap (phases — only for large work)
- Phase 1: Domain + persistence layer
- Phase 2: App + API layer
- Phase 3: Integration tests + docs

## Ordered checklist
1. Add migration `001_init_projects.sql` (`migrations/`).
2. Add sqlc query file `internal/infra/persistence/projects/queries/project.sql`.
3. Run `make sqlc` — verify generated code.
4. Add domain entity `internal/domain/projects/project.go`.
5. Add app-layer use cases: `create_project.go`, `get_project.go`, `list_projects.go`.
6. Add repository interface (`internal/app/projects/repository.go`) + impl
   (`internal/infra/persistence/projects/repository.go`).
7. Add API handlers `internal/api/features/projects/`; wire `Register` in `router.go`.
8. Wire `cmd/api/main.go` dependencies.
9. Write unit tests for domain + use cases.
10. Write integration tests in `test/integration/projects_integration_test.go`.
11. **Validate gate** — validator agent passes; `make ci` green.

## File-by-file changes

### `migrations/001_init_projects.up.sql` (NEW)
```sql
-- +goose Up
CREATE TABLE projects (...);
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON projects USING (...);
-- +goose Down
DROP TABLE projects;
```

### `internal/domain/projects/project.go` (NEW)
Modelled on `internal/domain/members/member.go:1-90` (already in the repo).
```go
package projects
// ... full sample
```

### `internal/app/projects/create_project.go` (NEW)
Modelled on `internal/app/members/create_member.go:1-75`.
```go
package projects
// ... full sample
```

### ... (one section per file)

## Exact test list

### Unit tests (`go test -race -count=1`)
- `TestNewProject_Happy_ReturnsProjectWithUUIDv7Id` — `domain/projects/project_test.go`
- `TestNewProject_EmptyTenant_ReturnsErrTenantRequired`
- `TestNewProject_EmptyName_ReturnsErrInvalidName`
- `TestNewProject_NameTooLong_ReturnsErrInvalidName`
- `TestProject_Rename_OnArchived_ReturnsErrProjectArchived`
- `TestCreateProjectHandler_Happy_SavesToRepoAndReturnsResponse` — `app/projects/create_project_test.go`
- `TestCreateProjectHandler_RepoFails_WrapsError`
- `TestCreateProjectHandler_DomainInvariant_ReturnsValidation`
- ... (one bullet per test, named precisely)

### Integration tests (`go test -tags=integration`)
- `TestProjects_Create_Integration_PersistsToDB` — `test/integration/projects_integration_test.go`
- `TestProjects_Get_Integration_HappyPath`
- `TestProjects_List_Integration_PaginatesByCreatedAt`
- `TestProjects_TenantIsolation_Integration_TenantACannotReadTenantB`  *(mandatory for any tenant-scoped feature)*
- `TestProjects_Archived_Integration_CannotBeRenamed`

## OPEN QUESTIONS

| ID | Question | Recommendation | Blocking? |
|----|----------|----------------|-----------|
| Q1 | Are projects searchable by name? | Add basic `LIKE` search now; full-text later when needed | No (defer) |

## Status banner

| Date | Phase | Build | Tests (unit) | Tests (integ) | Coverage | govulncheck |
|------|-------|-------|--------------|----------------|----------|-------------|
| 2026-06-20 | drafted | n/a | n/a | n/a | n/a | n/a |
| ... (filled as the plan executes) |
```

## Hard rules

- **Never invent file paths.** Verify each path exists (Glob/Read) or mark `(NEW)`.
- **Never invent symbol signatures.** Read the actual `*.go` to confirm.
- **Never lock a decision the owner hasn't agreed to.** Put it in OPEN QUESTIONS with a
  recommendation; the owner answers; you move it to Locked decisions.
- **Cite external API facts inline with URLs** (Go release notes, Gin docs, sqlc docs,
  pgx docs).
- **Status banners with exact counts** — `passed: 42 / failed: 0 / skipped: 1` — never
  "tests pass".
- **Code samples must be realistic** — real imports, real package names, plausible types.
  An implementer will copy-paste; sloppy samples make sloppy code.
- **The test list is verbatim contract** — the testing-expert implements exactly these
  names, asserting exactly what the plan guards.

## Where the plan lives

- **Single file** for ≤ 5–12 file changes: `docs/exec-plans/<topic>.md`
- **Master + phases** for larger work:
  - `docs/exec-plans/<topic>/master.md` — index, locked decisions, roadmap, status
  - `docs/exec-plans/<topic>/phases/01-<phase>.md` — ordered checklist, file changes,
    test list per phase

## After drafting

- Surface the plan path to the owner.
- Summary in one paragraph: goal, # locked decisions, # open questions, # phases, # files
  affected.
- Wait for approval before invoking `/run-impl-loop`.

## Common mistakes (don't)

- "Just code it" — non-trivial work without a plan = unverifiable, unreviewable, hard to
  fix later.
- Putting code samples in pseudocode. Real Go that compiles when assembled.
- Skipping the test list. The testing-expert needs it verbatim.
- Locking a decision the owner clearly hasn't made yet. OPEN QUESTIONS exist for that.
- Writing a plan and immediately implementing without owner approval. Plans are decisions;
  the owner makes them.
