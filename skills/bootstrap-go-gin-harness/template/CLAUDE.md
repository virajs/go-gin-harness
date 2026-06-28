# {{ProductName}}

> **Bootstrapped from the `go-gin-harness` Claude Code plugin.** The agents (architect-backend,
> implementer, validator, …), workflows (impl-build, architect-review, exec-plan-build, …),
> and 29 on-demand skills come from the plugin and work across every repo that installs it.
> This repo holds the **per-repo governance**: the rules in `.claude/rules/` (auto-loaded by
> path glob), the hooks in `.claude/hooks/` (enforcement gates), the build files (`Makefile`,
> `.golangci.yml`, `sqlc.yaml`), and the docs. Together: the plugin + this repo's `.claude/`
> = the full operating model.

> **Status: harness / governance only — no product code yet.** This repo's `cmd/`,
> `internal/`, and `pkg/` trees are **not yet scaffolded**. The plugin's skills + agents will
> build them when you run `/exec-plan` followed by `/run-impl-loop`. The governance files are
> ready; vision in `docs/product-overview.md` (template — fill it in).

## Ways of working

How we collaborate. These govern every action — follow them by default, every session.

**Decisions are the owner's.**
- **Never assume or decide on the owner's behalf.** When a decision is needed or anything is
  ambiguous, STOP and ask — present concrete options with a recommendation, don't pick silently.
- Don't proceed past a fork in scope or approach without explicit confirmation.
- When the owner pushes back, treat it as signal — re-examine, don't get defensive.
- **Lead with the product vision, not the tech.** When planning, the "why / who / moat" comes
  first; the stack is the substrate, not the headline.

**Git & irreversible actions — ask first, every time.**
- **Never `git commit`, `push`, `amend`, switch branches, or open a PR unless explicitly asked**
  — per action. Approval for one (e.g. "commit") never implies another (e.g. "push").
- Never force-push or rewrite shared history.
- Never delete or overwrite a file you didn't create without flagging it first.

**Stay in scope.**
- Do only what was asked. No "while I'm here" edits, no unrequested refactors.
- Don't over-engineer: no speculative abstractions or defensive code for cases that can't happen.
- Match existing patterns.
- **No third-party Go module without explicit, per-module approval.** Prefer the standard
  library (`net/http`, `log/slog`, `errors`, `context`, `sync`, `database/sql`, `encoding/json`,
  `testing`) or a minimal hand-rolled solution. When something seems to need a module, STOP and
  propose it (with a stdlib alternative) rather than adding it. Approval for one module never
  implies another.

**Be honest and verify.**
- Evidence over assertion: show the command/test output; never claim success without verifying.
- No "probably" / "should work" — verify it, or label it explicitly as unverified.
- Use first-party/authoritative sources, quote them, and flag uncertainty.
- Report failures plainly: failed tests, skipped steps, dead ends.
- **Source-of-truth authority hierarchy — when sources conflict, the higher rung wins, ALWAYS:**
  1. **Code** — the running source is ground truth. Read it line-by-line; cite `file:line`. Never assert behaviour you haven't read.
  2. **Database / SQL data** — actual rows + schema over what code or docs *say* they are.
  3. **Telemetry** — observed runtime behaviour over described behaviour.
  4. **Documentation** (docs/, CLAUDE.md, rules, skills, memories) — a *lead to verify*, never an authority; may be stale. If docs and code disagree, the **code wins** — note the drift.
  5. **AI output** — lowest; re-derive from a higher rung before trusting it.
- Make no claim you can't cite to a rung 1–3 source. If you can't verify, say "unverified" / "I don't know" — never fabricate.

**Safety.**
- Never read into context, or commit, secrets / `.env` / credentials.
- Never disable or skip tests, linters, or `go vet` to make something pass — fix the root cause.
- No destructive shell (`rm -rf`, `git reset --hard`, `DROP TABLE`, …) without explicit confirmation.

**Workflow.**
- For non-trivial or multi-file changes, plan first and get the plan approved before coding.
  Write the plan to `docs/exec-plans/<topic>.md` in the house format
  (`docs/projectStandards/implementation-plan-format.md`): locked decisions, an ordered checklist
  ending in a Validate gate, full code samples, an exact named-test list, OPEN QUESTIONS, and
  status banners with exact build/test counts.
- To build an approved plan, run `/run-impl-loop <plan>` — the main agent drives analyze →
  implement → validate → test → architect-review → triage → fix → summary, delegating the
  mechanical stages to the `impl-build` and `architect-review` workflows.
- For LLM features, runs / evals live under `evals/`; use `/run-evals` to fire a dataset
  through the current build and grade the result.
- **Decisions are recorded.** Forward-looking plan-scope decisions go in the plan's Locked
  Decisions table. Cross-cutting / mid-flight / non-plan decisions — accepted deviations
  with lasting effect, deferred or accepted-as-risk findings, pattern-level standard
  changes — go in `docs/decisions/` as ADRs via `/record-adr "<title>"`. See
  `docs/decisions/README.md` and `docs/projectStandards/implementation-plan-format.md`
  ("Plans vs. ADRs") for the split.
- Keep changes small and reviewable.

## Tooling — docs & MCP (non-negotiable)

Hard rules, not suggestions. They override default tool habits.

**`gopls` / native tools — for all Go (`.go`) work.** Use the native Read/Grep/Edit/Write on
`.go` files. After every cohesive edit: run `gofumpt -w .`, `goimports -w .`, `go vet ./...`,
`golangci-lint run`. Any linter error fails the build.

**Go release notes & stdlib docs — for any post-cutoff Go feature.** Knowledge cutoff is
January 2026 — anything later (e.g. iterators since 1.23, `testing/synctest` since 1.24, new
`log/slog` handlers, refined `errors.Join` behaviour, fresh `slices`/`maps` helpers) verify
against [pkg.go.dev](https://pkg.go.dev) or the Go release notes before relying on memory.

**Gin docs — for non-obvious Gin behaviour.** Quote
[gin-gonic.com/docs](https://gin-gonic.com/docs/) over memory for middleware ordering,
streaming, binding, and graceful shutdown specifics.

**Claude / Anthropic API work — use the `claude-api` skill.** For model ids, pricing,
streaming, tool use, MCP, or anything Anthropic-SDK, consult the skill rather than memory.

## Where things live

```
{{ProjectName}}/
├─ cmd/                              entry points (one main per binary)
│  └─ api/main.go                    HTTP server bootstrap (wires DI, gin, otel, db, shutdown)
├─ internal/                         all application code — not importable by other modules
│  ├─ domain/<feature>/              rich entities (constructors, behaviour methods, invariants)
│  ├─ app/<feature>/                 use cases (commands/queries + handlers), feature-sliced
│  ├─ infra/
│  │  ├─ persistence/<feature>/      pgx + sqlc generated queries, repositories, UoW
│  │  └─ <adapter>/                  external adapters (object storage, identity, mail, …)
│  ├─ api/
│  │  ├─ features/<feature>/         Gin handlers (one file per use case: handler + req + resp)
│  │  ├─ middleware/                 auth · tenancy · recovery · request-id · otel · logging
│  │  └─ router.go                   route registration (auto-scan IHandler implementations)
│  └─ shared/                        Result[T], Error, ErrorType — referenced by all
├─ pkg/                              public modules (usually empty — only for explicit exports)
├─ migrations/                       SQL migrations (goose) — *.up.sql / *.down.sql pairs
├─ test/
│  ├─ integration/                   testcontainers-driven endpoint→db tests
│  └─ fixtures/                      shared test data builders + harnesses
├─ evals/                            LLM evals (datasets + runners + graders) — if product uses LLMs
├─ docs/
│  ├─ product-overview.md            vision / domain model / roadmap / tech stack (template)
│  ├─ projectStandards/              coding-standards · backend-architecture · testing · observability · security · eval-standards · implementation-plan-format
│  ├─ exec-plans/                    approved implementation plans (build-from-this contracts)
│  └─ evals/                         eval methodology and historical results
├─ go.mod  go.sum                    module + pinned dependency versions
├─ Makefile                          build · test · lint · cover · bench · vuln · evals targets
├─ .editorconfig                     shared formatting (charset, indent, final newline)
├─ .golangci.yml                     strict linter suite (warnings = errors)
├─ .air.toml                         hot-reload for local dev (optional)
├─ sqlc.yaml                         sqlc config (schema + queries → typed Go)
└─ .claude/                          settings.json · hooks/ · rules/ · skills/ · agents/ · workflows/
```

- Go coding standard (auto-loads when editing `.go`): `docs/projectStandards/coding-standards.md`
- Build & monorepo-layout rationale: `docs/projectStandards/build-configuration.md`
- **Backend architecture decisions** (layering · feature folders · CQRS · pgx/sqlc persistence ·
  `Result[T]` · validation scopes): `docs/projectStandards/backend-architecture.md`. Enforceable
  distillations auto-load from `.claude/rules/backend/`.
- Testing standard (unit + integration + table-driven + testcontainers + race detector + coverage
  gate): `docs/projectStandards/testing-standards.md`
- Observability (OTel: traces + metrics + logs + correlation): `docs/projectStandards/observability-standards.md`
- Security baseline (OWASP API Top 10 mapped to Go/Gin/pgx): `docs/projectStandards/security-standards.md`
- LLM eval methodology: `docs/projectStandards/eval-standards.md`
- Plan format (build-from-this contracts): `docs/projectStandards/implementation-plan-format.md`
- Product vision: `docs/product-overview.md`

## Design non-negotiables (backend)

Full detail in `coding-standards.md` and `backend-architecture.md`; these apply at design time:

- **Rich, mutable domain entities** — exported struct types with **unexported fields**,
  constructor functions (`NewProject(...) (*Project, error)`), behaviour methods that enforce
  invariants. **Never expose mutable state via public fields.** Value objects are plain
  comparable structs (often `type X string` newtypes for ids/handles).
- **Constructors, not zero values.** Every entity has a `NewX(...)` constructor minting a
  UUIDv7 id and validating invariants — the zero value is not a valid instance.
- **Context discipline.** Every I/O function takes `context.Context` as the **first parameter**;
  every request handler propagates the request's context all the way to the DB driver. Never
  store a `context.Context` in a struct (vet warns). Never call `context.Background()` inside
  a request path.
- **Errors are values, not panics.** Return `error`; wrap with `fmt.Errorf("…: %w", err)`;
  type-check with `errors.Is` / `errors.As`. Use `Result[T]` + typed `Error` (in `internal/shared`)
  on the use-case ↔ API boundary so the API mapper can render RFC 9457 ProblemDetails. `panic`
  is for genuinely unreachable conditions only.
- **Goroutines have owners.** Every goroutine has a clear lifetime (bounded by a context, a
  channel close, or `errgroup.Wait`). Never spawn an unowned background goroutine in a request
  handler — leaks compound silently.
- **No `any` at boundaries.** Concrete types or generic parameters. `any` only for genuinely
  heterogeneous payloads (`slog` field values, JSON passthrough).
- **Tenancy is a first-class invariant.** `tenant_id` on every persisted row; every query
  scoped (sqlc query parameter); fail-closed when the request context lacks a tenant. (Harness
  default — drop for a single-tenant product.)
- **`panic`-free request handlers.** Recover-middleware exists as a safety net, not as a
  control flow. Every handler returns `(payload, error)` or sets `c.Error(...)` and returns.
- **OpenAPI 3.0 is mandatory.** Every endpoint MUST appear in `docs/api/openapi.yaml`,
  served at `GET /openapi.json` + `GET /openapi.yaml`. The spec validates in CI
  (`make openapi-validate`); a broken/missing spec fails the build. Generator approach
  (spec-first / code-first / manual) is per-project via `docs/decisions/0003-openapi-generation.md`.
  See `.claude/rules/backend/openapi.md`.

## Build

- **Strict Go build:** `go build ./...` zero warnings; `go vet ./...` clean; `golangci-lint
  run` clean (warnings = errors). The configured linters: `govet`, `errcheck`, `staticcheck`,
  `revive`, `gosec`, `gocritic`, `bodyclose`, `nilerr`, `errorlint`, `contextcheck`, `noctx`,
  `sqlclosecheck`, `rowserrcheck`, `tparallel`, `paralleltest`, `thelper`, `gocyclo`,
  `unconvert`, `unparam`, `misspell`, `gci`, `gofumpt`, `nolintlint`. See `.golangci.yml`.
- **Race detector on EVERY test run.** `go test -race ./...` — never skip; concurrency bugs
  in CI are 100× cheaper than in production.
- **Vulnerability scan on every change.** `govulncheck ./...` — fails the build on a CVE in
  the dependency graph (stdlib or third-party).
- **OpenAPI 3.0 spec validates in CI.** `make openapi-validate` runs against
  `docs/api/openapi.yaml`; a missing or invalid spec fails the build.
- **Coverage gate.** `go test -cover ./...` — minimum 80% on `internal/domain` and
  `internal/app` (business logic); 60% elsewhere. Exclusions are reactive with a justification.

See the [README](README.md) for the bootstrap walkthrough and the harness mental model
(influence vs. enforcement).
