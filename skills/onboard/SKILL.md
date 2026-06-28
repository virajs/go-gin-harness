---
name: onboard
description: Produce a "get up to speed on this whole project" orientation — vision, architecture, where things live, conventions, how to do common tasks, current state — grounded in the real code/config. Optionally writes docs/ONBOARDING.md. Use when asked to onboard, give a project overview, or "how does this project work / where do I start". Read-only except the optional doc write.
argument-hint: [--write to also produce/refresh docs/ONBOARDING.md]
allowed-tools: Read, Glob, Grep, Bash, Write
---

# Onboarding

Produce a skimmable, grounded orientation for a new contributor (human or agent). The
output answers: *where am I, why does this exist, how does it work, where do things live,
how do I do X, what's the current state?*

## Method

1. **Reconnaissance via Glob/Grep — NOT Read-everything.** Detect:
   - Module path + Go version (`go.mod`)
   - Framework (Gin via `internal/api/router.go`)
   - Entry points (`cmd/<name>/main.go`)
   - Top 2 levels of the tree (`internal/`, `pkg/`, `cmd/`, `migrations/`, `evals/`, etc.)
   - Tooling — Makefile targets, `.golangci.yml`, sqlc, goose
   - Test layout — `_test.go` colocation + `test/integration/`
   - `.claude/` governance — rules, skills, agents, workflows
2. **Lead with vision.** Open with the product context (from
   `.claude/hooks/context/product-context.md` + `docs/product-overview.md`):
   the why / who / moat. Tech is secondary.
3. **Architecture map.**
   - Stack: Gin · pgx + sqlc · slog · OpenTelemetry · goose · testify + testcontainers-go
   - Layout: Domain ← App ← Infra ← API; `cmd/api` is the composition root
   - One traced request lifecycle (request → middleware chain → handler → use case →
     domain + repo → SQL → back).
4. **Conventions from the code itself.** Read a sample file from each layer; observe how
   names, error handling, context propagation actually look. Verify against the rules; if
   the code says one thing and the rule says another, **trust the code** and flag the
   drift.
5. **Rank, don't dump.** Highlight:
   - Most-referenced files (the constructors, the Result+Error types, the router, the
     UoW).
   - Authoritative rules (`.claude/rules/`) + skills (`.claude/skills/`).
   - Don't enumerate every file.
6. **Common tasks (verified commands).**
   - Build: `make build`
   - Run: `make run` (or `make dev` for hot reload via air)
   - Test: `make test` (unit, race detector); `make test-integration` (testcontainers)
   - Lint: `make lint`
   - Coverage: `make cover` (gate-enforced)
   - Vuln scan: `make vuln`
   - Migrations: `make migrate-up`, `make migrate-new NAME=...`
   - sqlc: `make sqlc`
   - Evals: `make evals` (if product uses LLMs)
   - Plan + build: `/exec-plan <topic>` → owner approves → `/run-impl-loop <plan>`
7. **"Where to look" map.** For each common goal, list location + relevant rules / skills
   / agents:

   | Want to add… | Go here | Rule | Skill | Agent (auto-spawned by impl-build) |
   |---|---|---|---|---|
   | An endpoint | `internal/api/features/<feature>/` | `.claude/rules/backend/api-design.md` | `add-endpoint` | implementer |
   | A use case | `internal/app/<feature>/` | `.claude/rules/backend/cqrs.md` | `add-command` / `add-query` | implementer |
   | A domain entity | `internal/domain/<feature>/` | `.claude/rules/backend/domain-model.md` | `add-domain-entity` | implementer |
   | A persistence query | `internal/infra/persistence/<feature>/queries/` | `.claude/rules/backend/persistence.md` | `sqlc-patterns` | implementer |
   | A test | next to the code | `.claude/rules/testing.md` | `write-unit-tests` / `write-integration-tests` | testing-expert |
   | An eval | `evals/<suite>/` | `docs/projectStandards/eval-standards.md` | `run-evals` | eval-runner |

8. **Flag unknowns / drift explicitly.** "The README claims X but the code at file:line
   does Y — drift, surface to owner."
9. **Optional artifact:** if `--write` was passed, write or refresh `docs/ONBOARDING.md`.
   If the file exists, read it first and preserve / enhance — don't blow away. Call out
   what changed.

## Output structure

```markdown
# {{ProductName}} — Onboarding

## What this is (vision)
<one paragraph from product-overview.md / product-context.md>

## Stack
- Gin (HTTP), pgx + sqlc (DB), slog (logs), OTel (traces/metrics), goose (migrations)
- Stdlib testing + testify + testcontainers-go
- Go 1.24, golangci-lint strict, race detector mandatory

## Architecture (5-line summary)
Domain ← App ← Infra ← API. Domain has zero project refs. Use cases declare their
repository interfaces; infra implements. API is a thin Gin layer with feature folders.
`cmd/api/main.go` wires everything.

## Request lifecycle (one trace)
1. `POST /v1/projects` arrives at the router (`internal/api/router.go:42`).
2. Middleware: RequestID → SlogLogger → otelgin → Timeout → Auth → Tenancy → ProblemDetails.
3. Handler `createHandler` (`internal/api/features/projects/create_project.go:18`) binds
   the JSON body, pulls tenant from context, dispatches `app.CreateProjectHandler.Handle`.
4. Use case (`internal/app/projects/create_project.go:34`) validates business rules,
   constructs `domain.Project` (UUIDv7 minted), saves via repo.
5. Repo (`internal/infra/persistence/projects/repository.go:21`) calls the sqlc-generated
   `UpsertProject` with the request's transaction context.
6. Response shaped, returned, ProblemDetails on any error.

## Where things live
... (the table from step 7)

## Common tasks
... (the commands from step 6)

## Conventions worth knowing
- `tenant_id` everywhere (multi-tenant by default; see `.claude/rules/backend/tenancy.md`).
- `context.Context` first parameter; never `context.Background()` in a request path.
- Errors are values; use typed `*result.Error` for client-visible failures; wrap with
  `fmt.Errorf("…: %w", err)`.
- No `panic` for expected failures; no `any` at boundaries.

## How we work
- Plan first (`/exec-plan <topic>`); owner approves; `/run-impl-loop` builds.
- Race detector + linter + coverage gate enforce on every run.
- The harness in `.claude/` carries the project standards — read those before guessing.

## Current state (snapshot)
- {brief — what's scaffolded vs. governance-only, who's working on what}
- Open questions: ...

## Where to ask
- {channel / owner reference}
```

## Hard rules

- **Read first, write second.** Don't paraphrase from memory; cite `file:line`.
- **Verify every command** — the Makefile target must exist; the test target must run
  cleanly.
- **No fabrication.** If something is unverified, label it.
- **Respect existing `docs/ONBOARDING.md`** if it exists — read, enhance, preserve voice;
  call out structural changes.
- **Don't dump the whole tree.** Rank by relevance.

## What this skill DOES NOT do

- Critique the architecture (out of scope for an orientation).
- Write OpenAPI specs (separate concern).
- Modify code (read-only except the optional `--write` to `docs/ONBOARDING.md`).
