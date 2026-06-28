# {{ProductName}} — Implementation plan format

> The house format for every non-trivial implementation plan. A plan is a **build-from-this
> contract**, not a sketch. When the implementer reads it later, every consequential
> decision is already pinned; the implementation is mechanical.

## Where plans live

- **Single file** for ≤ 5–12 file changes:
  `docs/exec-plans/<topic>.md`
- **Master + phases** for larger work:
  - `docs/exec-plans/<topic>/master.md` — index + locked decisions + roadmap + status
  - `docs/exec-plans/<topic>/phases/01-<phase>.md`, `02-<phase>.md`, ...

## Plans vs. ADRs — where each decision goes

The harness records decisions in two places:

| Decision type | Where | Example |
|---|---|---|
| **Pinned at planning time, scoped to this plan** | The plan's **Locked Decisions** table | `D1: use cursor pagination, not offset` |
| **Cross-cutting / mid-flight / non-plan** | An **ADR** in `docs/decisions/` (via `/record-adr`) | `ADR-0008: deferred rate-limit on search endpoint until Q4` |

Triggers for an ADR (not a plan entry):
- A deviation accepted during `/run-impl-loop` that affects future work
- An architect-review finding deferred or accepted-as-risk
- A pattern-level standard change (rule rewrite, supersession)
- A "we considered X and rejected it" worth preserving so it isn't re-litigated

When an ADR and a plan are related, **cross-link**: the plan's Locked Decisions table
references the ADR (`D5 | Persistence uses sqlc | ADR-0007`); the ADR's `Related:` header
points back to the plan. See `docs/decisions/README.md` and the `record-adr` skill.

## House style — non-negotiable

- **Exhaustive, evidence-first, decision-led, terse.** Every claim grounded in code
  (cite `file:line`).
- **Goal and scope boundary in the same breath.** Bold "ONLY" / "NEVER".
- **Pin every consequential choice in Locked decisions** (D1, D2, …).
- **Detail to individual symbols and line edits.** "Add `CreateProjectHandler.Handle` to
  `internal/app/projects/create_project.go`" beats "create a handler".
- **Every code sample carries an absolute target path** + "modelled on `<existing>.go:line`"
  lineage where one exists.
- **Line anchors are leads, not contracts.** Anchor on symbol names; line numbers drift.
- **Cite external API facts inline with URLs** (Go release notes, Gin docs, pgx docs).
- **Status banners with exact counts** (`6,558 passed / 0 failed / 3 skipped`) — never
  "tests pass".
- **OPEN QUESTIONS** at the bottom for anything that needs owner input. The implementer
  STOPS if they hit one of these.

---

## Master plan template (large work)

```markdown
# <Topic>

## Goal — one sentence
ONLY do X. NEVER do Y.

## Locked decisions

| ID | Decision | Alternative considered | Why this one |
|----|----------|------------------------|--------------|
| D1 | … | … | … |
| D2 | … | … | … |

## Roadmap (phases)

- **Phase 1**: Domain + persistence layer (`phases/01-domain-persistence.md`)
- **Phase 2**: App + API layer (`phases/02-app-api.md`)
- **Phase 3**: Integration tests + docs (`phases/03-tests-docs.md`)

## OPEN QUESTIONS

| ID | Question | Recommendation | Blocking? |
|----|----------|----------------|-----------|

## Status

| Date | Phase | Build | Tests | Coverage | Notes |
|------|-------|-------|-------|----------|-------|
| 2026-06-20 | drafted | n/a | n/a | n/a | initial draft |
```

---

## Phase plan template (single file ≤ 5–12 files)

```markdown
# <Phase> — <one-line scope>

## Goal — one sentence
ONLY do X. NEVER do Y. (Scope boundary in the same breath as the goal.)

## Locked decisions

| ID | Decision | Why |
|----|----------|-----|
| D1 | Use sqlc-generated typed queries | Compile-time safety; matches existing pattern |
| D2 | Project IDs are UUIDv7 minted in domain | Distributed-friendly; sortable; matches existing pattern |
| D3 | List query uses cursor pagination | O(log N) at scale; offset breaks > 10k rows |

## Ordered checklist

1. Add migration `001_init_projects.up.sql` + `.down.sql` (`migrations/`).
2. Add sqlc query file `internal/infra/persistence/projects/queries/project.sql`.
3. Run `make sqlc` — verify generated code.
4. Add domain entity `internal/domain/projects/project.go`.
5. Add app-layer interface `internal/app/projects/repository.go`.
6. Add use cases: `create_project.go`, `get_project.go`, `list_projects.go` in
   `internal/app/projects/`.
7. Add repository impl `internal/infra/persistence/projects/repository.go`.
8. Add API handlers in `internal/api/features/projects/`; wire `Register` in
   `internal/api/router.go`.
9. Wire dependencies in `cmd/api/main.go`.
10. Write unit tests for domain + use cases.
11. Write integration tests in `test/integration/projects_integration_test.go`.
12. **Validate gate** — `validator` agent passes; `make ci` green.

## File-by-file changes

### `migrations/001_init_projects.up.sql` (NEW)

```sql
-- +goose Up
CREATE TABLE projects (
    id         uuid        PRIMARY KEY,
    tenant_id  uuid        NOT NULL,
    name       text        NOT NULL,
    archived   boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);
CREATE INDEX idx_projects_tenant_created
    ON projects (tenant_id, created_at DESC, id DESC);
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON projects
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- +goose Down
DROP TABLE projects;
```

### `internal/domain/projects/project.go` (NEW)

Modelled on `internal/domain/members/member.go:1-90` (already in the repo).

```go
package projects
// ... full code sample, real imports, plausible types — the implementer copies this
```

### ... (one section per file change)

## Exact test list

### Unit tests (`go test -race -count=1 ./internal/...`)

- `TestNewProject_Happy_ReturnsProjectWithUUIDv7Id` — `internal/domain/projects/project_test.go`
- `TestNewProject_EmptyTenant_ReturnsErrTenantRequired`
- `TestNewProject_EmptyName_ReturnsErrInvalidName`
- `TestNewProject_NameTooLong_ReturnsErrInvalidName`
- `TestProject_Rename_OnArchived_ReturnsErrProjectArchived`
- `TestProject_Archive_TwiceIsNoOp`
- `TestCreateProjectHandler_Happy_SavesToRepoAndReturnsResponse` — `internal/app/projects/create_project_test.go`
- `TestCreateProjectHandler_RepoFails_WrapsError`
- `TestCreateProjectHandler_DomainInvariant_ReturnsValidation`
- `TestCreateProjectHandler_NameAlreadyInUse_ReturnsConflict`
- `TestGetProjectHandler_NotFound_ReturnsNotFound` — `internal/app/projects/get_project_test.go`
- `TestListProjectsHandler_Pagination_CursorRoundTrips` — `internal/app/projects/list_projects_test.go`

### Integration tests (`go test -race -tags=integration ./test/integration/...`)

- `TestProjects_Create_Integration_PersistsToDB`
- `TestProjects_Get_Integration_HappyPath`
- `TestProjects_List_Integration_PaginatesByCreatedAt`
- **`TestProjects_TenantIsolation_Integration_TenantACannotReadTenantB`** *(mandatory for any tenant-scoped feature)*
- `TestProjects_Archived_Integration_CannotBeRenamed`
- `TestProjects_Concurrent_FirstWinsReturns409` — optimistic concurrency

## OPEN QUESTIONS

| ID | Question | Recommendation | Blocking? |
|----|----------|----------------|-----------|
| Q1 | Should we support `LIKE` search on name? | Defer until product needs it | No |

## Status

| Date | Build | Tests (unit) | Tests (integ) | Coverage | govulncheck | Notes |
|------|-------|--------------|----------------|----------|-------------|-------|
| 2026-06-20 | drafted | n/a | n/a | n/a | n/a | initial draft |
| 2026-06-21 | clean | 12 passed / 0 failed | 6 passed / 0 failed | domain 92% · app 87% | clean | implementation complete |
```

---

## Hard rules

- **Never invent file paths.** Verify with Glob/Read; mark new files `(NEW)`.
- **Never invent symbol signatures.** Read the actual `*.go`.
- **Never lock a decision the owner hasn't agreed to.** Put it in OPEN QUESTIONS with a
  recommendation.
- **Cite external API facts inline.** When the plan relies on Gin / pgx / sqlc / Go
  release behaviour, link the doc.
- **Code samples must compile** (when assembled — real imports, real package names,
  plausible types). The implementer copies these.
- **Exact test names** (`TestX_Y_Z`) — the testing-expert implements them verbatim.
- **Status banner with exact counts** — `passed: 42 / failed: 0 / skipped: 1` — never
  "tests pass".

---

## What goes in OPEN QUESTIONS

Anything where the answer materially changes the design AND the owner hasn't decided:
- "Should X be sync or async?"
- "What's the cursor encoding — base64 of (created_at, id), or opaque token?"
- "Pagination cap — 100, 200, 500?"
- "Should the feature flag be on by default in dev?"

A locked decision needs a **why** that survives scrutiny; if you can't articulate it,
it's not locked yet — put it in OPEN QUESTIONS.

---

## The `/exec-plan` workflow

Invoke the `exec-plan-build` workflow to produce a plan in this format:

```javascript
Workflow({
  name: "exec-plan-build",
  args: { topic: "<topic>", request: "<full user request>", scope: [...], outputPath: "..." }
})
```

The workflow:
1. **Recon** — parallel readers per area surface existing code (Glob/Grep with file:line
   citations).
2. **Draft** — the `exec-planner` agent writes the plan against the recon.
3. **Review** — the `architect-backend` agent adversarially reviews against this format.
4. **Finalize** — fix issues; write the plan to `docs/exec-plans/<topic>.md`.

---

## After the plan is approved

`/run-impl-loop docs/exec-plans/<topic>.md` builds it:
- `impl-build` workflow: implement → validate → fix-loop → test.
- `architect-review` workflow: parallel reviewers + adversarial verification.
- Main agent triages findings + summarizes.

The status banner gets filled in as the plan executes. The plan becomes the history of
the change.
