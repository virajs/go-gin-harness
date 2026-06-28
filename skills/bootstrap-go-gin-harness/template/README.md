# Go / Gin Claude Code Harness

A reusable Claude Code harness for production Go HTTP APIs built on **Gin · pgx + sqlc ·
log/slog · OpenTelemetry · testify + testcontainers-go · goose**. The harness encodes the
project standards, multi-agent operating model, and enforcement gates **as files that travel
with the repo**, so a new contributor (human or agent) gets the full operating context the
moment they clone.

This README is the bootstrap guide and mental model. The session-by-session law is in
[CLAUDE.md](CLAUDE.md); the rationale is in [docs/projectStandards/](docs/projectStandards/).

---

## The mental model: influence vs. enforcement

Three concentric rings, in order of strictness:

| Primitive | Role | Influence or Enforcement? |
|---|---|---|
| `CLAUDE.md` | Always-loaded project law (loaded every session) | **Influence (strong)** |
| `.claude/rules/` | Auto-load when touching files matching their `paths:` glob | **Influence (scoped)** |
| `.claude/skills/` | On-demand procedures (load **only** when invoked) — **progressive disclosure** | **Influence (just-in-time)** |
| `.claude/agents/` | Specialized sub-personas spawned in their own context window | **Influence (isolated)** |
| `.claude/workflows/` | Deterministic multi-agent orchestration scripts | **Influence (scripted)** |
| `.claude/hooks/` | Run on every matching tool call | **Enforcement** |
| `permissions.deny` | Hard tool/path blocks | **Enforcement** |
| Strict build (`golangci-lint`, `go vet`, `govulncheck`, race detector, coverage gate) | Fails the build on a violation | **Enforcement** |

**Progressive disclosure** is the design principle: only `CLAUDE.md` and matching rules
load by default. Skills, agent personas, and workflow scripts cost zero tokens until
invoked. Every artifact the harness generates is itself disclosed progressively — a plan
header gates a phase, a phase gates a checklist, a checklist gates a code edit.

### Three hard enforcement gates

1. **`.claude/hooks/protect-commands.sh`** — gates destructive shell.
   - **DENY:** `rm -rf /`, `rm -rf ~`, `rm -rf $HOME` (catastrophic, no recovery).
   - **ASK:** any deletion (`rm`, `rmdir`), `git push --force`, `git reset --hard`,
     `git clean -f`, `git add`, `git commit`, `git push` (per-action confirmation),
     `goose down`, `migrate down`, `DROP DATABASE|SCHEMA|TABLE`, `TRUNCATE`,
     unqualified `DELETE FROM` / `UPDATE` without `WHERE`.
2. **`.claude/hooks/enforce-formatting.sh`** — gates Go edits: on Edit/Write to a `.go`
   file the post-tool hook runs `gofumpt`, `goimports`, and `go vet` on the touched
   package; a vet failure surfaces immediately rather than at commit time. (Influence-by-
   feedback, not a hard block.)
3. **`.claude/hooks/session-start-context.sh`** — injects product vision at session
   start so every session leads with **why / who / moat**, not tech.

Plus `permissions.deny` in `.claude/settings.json` blocks reads of `.env`, `secrets/**`,
and `*.pem` files — secrets never enter context.

---

## Bootstrap (new project)

1. **Copy the harness** into a new repo (or clone this one and rename).
2. **Find/replace placeholders:**
   - `{{ProjectName}}` → your Go module name (e.g. `github.com/acme/orders-api`)
   - `{{ProductName}}` → your product's display name
   - Search command: `grep -rl '{{ProductName}}\|{{ProjectName}}' . | xargs sed -i ''
     -e 's|{{ProductName}}|...|g' -e 's|{{ProjectName}}|...|g'`
3. **Fill in product context:**
   - `docs/product-overview.md` — vision / domain model / roadmap / tech stack
   - `.claude/hooks/context/product-context.md` — short product blurb injected at session start
4. **Decide optional defaults** (each is wired ON by default — turn OFF if it doesn't apply):
   - **Multi-tenancy** — `tenant_id` everywhere, fail-closed scoping. Drop if single-tenant
     by deleting `.claude/rules/backend/tenancy.md` and removing tenancy middleware.
   - **LLM features / evals** — `evals/`, `run-evals` skill, `eval-run` workflow,
     `eval-runner` agent. Delete these if the product doesn't talk to an LLM.
   - **Data residency** — note it in `product-context.md` if required (e.g. EU-only);
     the security audit checks for cross-region egress.
   - **Linter strictness** — tune in `.golangci.yml` (start strict, suppress reactively
     with a one-line justification comment).
5. **Scaffold the app:**
   - `go mod init {{ProjectName}}` (already set in `go.mod` if you used find/replace)
   - `mkdir -p cmd/api internal/{domain,app,infra/persistence,api/features,api/middleware,shared} migrations test/integration evals`
   - Add the dependencies you need (Gin, pgx, sqlc, slog handler, otel, testify,
     testcontainers-go) — one at a time, each requiring the owner's per-module approval.
6. **Install dev tooling** (the linter expects these on PATH):
   - `go install mvdan.cc/gofumpt@latest`
   - `go install golang.org/x/tools/cmd/goimports@latest`
   - `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`
   - `go install golang.org/x/vuln/cmd/govulncheck@latest`
   - `go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest`
   - `go install github.com/pressly/goose/v3/cmd/goose@latest`
   - (Optional) `go install github.com/air-verse/air@latest` for hot reload.
7. **Verify the harness loads:** open Claude Code in the repo and run
   `/onboard` — it should produce a grounded orientation that cites `file:line`s in this
   repo and the standards docs.

---

## Day-to-day operating model

**For a non-trivial change:**

1. **Plan first.** `/exec-plan <topic>` (or write `docs/exec-plans/<topic>.md` by hand) —
   produces a build-from-this contract: locked decisions, ordered checklist, code samples
   with absolute paths, exact named-test list.
2. **Review & approve the plan** with the owner. Plans are decisions.
3. **Build the plan.** `/run-impl-loop docs/exec-plans/<topic>.md` — the main agent drives:
   - analyze the plan
   - delegate `implement → validate → fix → test` to the `impl-build` workflow
   - delegate `architect-review` (parallel reviewers + adversarial verification) to the
     `architect-review` workflow
   - triage, fix, summarize
4. **Verify.** `make test cover lint vet vuln` — exact pass/fail/skip counts in the
   status banner.

**For an LLM feature:**

5. **Define the eval.** Drop a dataset in `evals/<feature>/dataset.jsonl` (one prompt +
   expected output per line) and a `grader.go` that scores each output.
6. **Run the eval.** `/run-evals <feature>` — fans the dataset through the current build,
   runs the grader in parallel, reports a scorecard with per-case verdicts and a delta
   vs. the last baseline run.
7. **Promote** the baseline when satisfied (`evals/<feature>/baseline.json`).

**For a production issue:**

8. **Investigate.** `/rca <symptom>` — the `rca-investigator` agent hypothesizes, then
   verifies via code + telemetry + SQL (read-only); returns a confirmed root cause + a
   minimal fix-list ready to feed back into `/run-impl-loop`.

---

## Customization points (the dials)

| Dial | Default | Where to flip |
|---|---|---|
| Multi-tenancy | ON | delete `.claude/rules/backend/tenancy.md` + tenancy middleware |
| LLM features / evals | ON (skill + workflow + agent + docs present) | delete `evals/`, `.claude/skills/run-evals/`, `.claude/workflows/eval-run.js`, `.claude/agents/eval-runner.md` |
| DB access | **pgx + sqlc** | swap `sqlc-patterns` skill content if you change ORM (approved per-package) |
| Logging | `log/slog` (stdlib) | swap handler config in `cmd/api/main.go` |
| Tracing | OpenTelemetry (OTLP exporter) | configured in `internal/api/middleware/otel.go` + `cmd/api/main.go` |
| Auth | JWT (claims-based) | implement in `internal/api/middleware/auth.go` — provider-pluggable |
| Migrations | `goose` | swap to `golang-migrate` (per-module approval) by replacing in Makefile + skill |
| Validation | `go-playground/validator` (Gin's default) | escape hatch only for shape checks; business rules → `IValidator[T]` in app layer |
| Coverage gate | 80% domain/app · 60% elsewhere | tune in Makefile `cover` target |
| Permission posture | broad allow + targeted ask/deny | edit `.claude/settings.json` |

---

## What's NOT in the harness (and why)

- **Database choice other than PostgreSQL** — the harness targets PostgreSQL (via pgx
  driver), and Postgres has the strongest Go ecosystem
  (sqlc, pgx, pgvector). MySQL/SQLite would work but skills target PG specifics.
- **gRPC / Twirp / Connect** — out of scope; this is an HTTP/JSON API harness. If you
  need gRPC, add it as a parallel transport in `cmd/grpc/` and write a sibling rule set.
- **A pre-baked DI framework** (wire / fx / dig). Manual constructor injection in
  `cmd/api/main.go` is sufficient up to ~50 services; adopt `wire` later if wiring
  becomes a chore — per-package approval.
- **A custom CLI framework** (cobra / urfave-cli). `cmd/api/main.go` parses flags with
  the stdlib `flag` package; add `cobra` only if you grow multiple subcommands.

Each absence is a deliberate "no, until you need it" — the harness fights speculative
abstractions as hard as it fights weak conventions.

---

## Repository contents (high-level)

```
golang/
├─ CLAUDE.md                          always-on project law (loaded every session)
├─ README.md                          this file — bootstrap + mental model
├─ .editorconfig                      shared formatting (charset, indent, final newline)
├─ .gitignore                         secrets, build artifacts, tool caches
├─ .golangci.yml                      strict linter suite (warnings = errors)
├─ .air.toml                          hot-reload config (dev only)
├─ .mcp.json                          MCP server config (gopls bridge — optional)
├─ go.mod                             module + Go version
├─ Makefile                           build · test · lint · cover · bench · vuln · evals
├─ sqlc.yaml                          sqlc query → typed Go config
├─ docs/                              standards + plans + product vision
├─ migrations/                        goose SQL migrations
├─ evals/                             LLM eval datasets + runners (if applicable)
├─ test/                              integration tests + fixtures
└─ .claude/
   ├─ settings.json                   permissions + hooks + MCP wiring
   ├─ hooks/                          enforcement scripts (bash, macOS/Linux)
   │  ├─ protect-commands.sh
   │  ├─ enforce-formatting.sh
   │  ├─ session-start-context.sh
   │  └─ context/product-context.md   product vision blurb (template)
   ├─ rules/                          scoped, path-auto-loaded standards (.md)
   │  ├─ go-conventions.md
   │  ├─ build-config.md
   │  ├─ gin-conventions.md
   │  ├─ concurrency.md
   │  ├─ observability.md
   │  ├─ security.md
   │  ├─ testing.md
   │  └─ backend/
   │     ├─ clean-architecture.md
   │     ├─ domain-model.md
   │     ├─ cqrs.md
   │     ├─ result-and-errors.md
   │     ├─ api-design.md
   │     ├─ persistence.md
   │     └─ tenancy.md
   ├─ skills/                         on-demand procedures (~27 SKILL.md files)
   ├─ agents/                         10 specialized sub-personas
   └─ workflows/                      5 orchestrated multi-agent scripts
```

---

## Why this harness exists

Standards are only real if they're encoded. A `STYLE.md` that nobody reads is decoration;
a `golangci-lint` rule that fails the build is law. The harness moves every convention as
far up the strictness ladder as it can — from prose in a doc, to a rule auto-loaded on
matching paths, to a skill invoked at the moment of need, to a hook that blocks the wrong
shell command before it runs, to a build that refuses to compile a warning.

The result: **a junior engineer (or a fresh Claude Code session) writes the same code a
senior engineer would, on day one, without needing to read every line of every doc**.
Progressive disclosure means the right standard surfaces at the right moment — not before
(noise), not after (drift).
