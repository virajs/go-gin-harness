# go-gin-harness — Claude Code plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go Version](https://img.shields.io/badge/Go-1.24%2B-blue.svg)](https://go.dev/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-purple.svg)](https://docs.claude.com/en/docs/claude-code/overview)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](CHANGELOG.md)

Production-grade Claude Code harness for **Go / Gin HTTP APIs**, packaged as a plugin so
the operating model travels across projects.

## Quick start

```bash
# 1. Register the marketplace (one-time per machine)
claude plugin marketplace add https://github.com/virajs/go-gin-harness

# 2. Install the plugin
claude plugin install go-gin-harness@go-gin-harness

# 3. In any repo, bootstrap the per-repo governance
cd ~/code/my-new-go-api && claude
# In the session: /bootstrap-go-gin-harness
```

Skip to [Implementing features](#implementing-features) for the day-to-day flow, or
read on for the architecture.

---

The plugin ships:
- **10 specialized agents** (architect-backend, architect-fullstack, implementer,
  validator, testing-expert, rca-investigator, security-auditor-backend,
  findings-verifier, eval-runner, exec-planner)
- **5 deterministic workflows** (impl-build, architect-review, docs-standards-sync,
  eval-run, exec-plan-build)
- **29 on-demand skills** (add-endpoint, sqlc-patterns, run-impl-loop, run-evals,
  security-backend, …) — progressive disclosure; zero token cost until invoked
- **A bootstrap skill** that scaffolds the per-repo governance (rules, hooks, Makefile,
  .golangci.yml, docs, …) into a target repository

## Why a plugin and not just a starter template?

The harness has two kinds of artifacts:

| Kind | Lives | Why |
|---|---|---|
| **Project-agnostic** — agents, workflows, universal skills | **Plugin (system-wide)** | Same operating model across every Go/Gin project |
| **Per-repo** — rules (path-globbed to `internal/**/*.go`), hooks (`${CLAUDE_PROJECT_DIR}` paths), Makefile, .golangci.yml, sqlc.yaml, docs | **Bootstrap-installed (in the target repo)** | Path globs need to match the actual project layout; hooks live with the code they gate |

Install the plugin once; bootstrap any new repo with one command.

## Install

Claude Code installs plugins **via a marketplace** (a directory or git URL containing a
`.claude-plugin/marketplace.json` registry). This plugin is a *single-plugin marketplace*
— its `.claude-plugin/` folder holds both `plugin.json` (the plugin manifest) and
`marketplace.json` (a marketplace listing exactly one plugin: itself, via `source: "."`).

```bash
# 1. Register the marketplace (one-time per machine).
claude plugin marketplace add https://github.com/virajs/go-gin-harness

# 2. Install the plugin from it.
claude plugin install go-gin-harness@go-gin-harness
```

To install from a local clone (e.g. for plugin development), point at the local path
instead of the URL:

```bash
git clone https://github.com/virajs/go-gin-harness ~/code/go-gin-harness
claude plugin marketplace add ~/code/go-gin-harness
claude plugin install go-gin-harness@go-gin-harness
```

Verify:

```bash
claude plugin list
# expect: go-gin-harness    0.1.0    enabled    go-gin-harness
```

Update later when the plugin changes:

```bash
claude plugin marketplace update go-gin-harness
claude plugin update go-gin-harness
```

**Pin to a specific version** (recommended for production teams):

```bash
claude plugin install go-gin-harness@go-gin-harness@v0.1.0
```

See [CHANGELOG.md](CHANGELOG.md) for release notes.

After install:
- The 10 agents are available across all projects.
- The 29 skills are available system-wide; auto-discovered when their description
  matches.
- The 5 workflows are available via the bundled slash commands (`/run-impl-loop`,
  `/exec-plan`, `/architect-review`, `/run-evals`, `/docs-standards-sync`).
- A new slash command — `/bootstrap-go-gin-harness` — scaffolds the per-repo bits.

## Bootstrap a new project

```bash
cd ~/code/my-new-go-api
# (optional: `git init`)
claude
```

In the Claude Code session:

```
/bootstrap-go-gin-harness
```

The skill will:
1. Ask for the **Go module path** (e.g. `github.com/acme/orders-api`) and the
   **product display name** (e.g. `OrdersAPI`).
2. Refuse to overwrite an existing harness — surface conflicts first.
3. Copy the per-repo template (CLAUDE.md, .claude/rules, .claude/hooks,
   .claude/settings.json, .golangci.yml, Makefile, sqlc.yaml, .editorconfig, .gitignore,
   .air.toml, .mcp.json, go.mod, docs/, scripts/, migrations/README.md, evals/README.md,
   test/README.md) into the target repo.
4. Run find/replace on `{{ProjectName}}` and `{{ProductName}}` across all copied files.
5. Make hooks executable (`chmod +x .claude/hooks/*.sh scripts/*.sh`).
6. Run `go mod tidy` (will be a no-op until you add deps).
7. Print next steps.

After bootstrap, in the same session:

```
/onboard            # produces an orientation grounded in the freshly-installed standards
/exec-plan "scaffold the api skeleton — cmd/api/main.go, middleware stack, sample feature"
# owner approves the plan
/run-impl-loop docs/exec-plans/scaffold-api-skeleton.md
```

Within minutes you have a working `cmd/api/main.go`, middleware, a sample feature
end-to-end, integration tests, OpenTelemetry wired, all under the harness's standards.

## Implementing features

The day-to-day flow is three phases: **install once** (above), **set up the project
once**, then a **repeating per-feature loop** (`/exec-plan` → owner approves →
`/run-impl-loop`). Everything else (RCA, security review, eval) is auxiliary.

### Phase 1 — project setup (once per repo)

After `/bootstrap-go-gin-harness`, the governance is installed but there's no Go code
yet. Scaffold the skeleton:

```
/exec-plan "scaffold the api skeleton — cmd/api/main.go with gin+otel+pgx+slog wired,
            middleware stack (RequestID, SlogLogger, otelgin, Timeout, Auth, Tenancy,
            ProblemDetails, Recovery), internal/shared/result/, sample 'health' feature
            end-to-end (handler + use case + test), graceful shutdown"
```

The `exec-plan-build` workflow (recon → draft → adversarial review → finalize) writes
`docs/exec-plans/scaffold-api-skeleton.md`. Owner reviews; once approved:

```
/run-impl-loop docs/exec-plans/scaffold-api-skeleton.md
```

A few minutes later you have a working `make run` + `make ci` green.

### Phase 2 — the per-feature loop (every feature, every time)

Two commands. That's it.

```
/exec-plan "<what you want>"
# owner reviews + approves docs/exec-plans/<topic>.md
/run-impl-loop docs/exec-plans/<topic>.md
```

What happens behind `/exec-plan`:

| Phase | What | Agent / Workflow |
|---|---|---|
| Recon | Parallel readers map existing code matching the scope (domain, app, api, persistence, tests). Cite file:line. | `Explore` agents in `exec-plan-build` |
| Draft | Pin locked decisions, write file-by-file code samples, exact named-test list. | `exec-planner` agent |
| Review | Adversarial review of the draft against the house format. | `architect-backend` agent |
| Finalize | Address issues; write `docs/exec-plans/<topic>.md`. | `exec-planner` agent |

What happens behind `/run-impl-loop`:

| Phase | What | Agent / Workflow |
|---|---|---|
| Implement | Build the plan; report deviations; build clean before returning. | `implementer` agent in `impl-build` |
| Validate | Read-only: every plan symbol exists, rules honored, `golangci-lint` clean, `go vet` clean, race detector passes. | `validator` agent |
| Fix-loop | Up to 3 attempts: implementer fixes validator's issues. | `implementer` + `validator` |
| Test | Write the plan's exact test list, run with `-race`, report exact pass/fail/skip counts. | `testing-expert` agent |
| Review | Parallel adversarial review (backend + security) → adversarial verification of each finding. | `architect-backend` + `security-auditor-backend` + `findings-verifier` in `architect-review` |
| Triage + Fix + Summary | You (main agent) decide which findings to fix; loop on the fix-list; summarize. | Main agent + `impl-build` |

You stay in the loop for the **judgment steps** (read the plan, triage deviations, decide
which findings to fix, write the summary). The mechanical steps are workflows.

### Worked example — adding a `projects` feature

```
/exec-plan "Add a projects feature — create/get/list/rename/archive endpoints under
            /v1/projects, tenant-scoped, full CRUD via REPR style. Optimistic concurrency
            via xmin. UUIDv7 ids. Cursor pagination on list."
```

The workflow produces `docs/exec-plans/add-projects-feature.md` with:
- Locked decisions table (e.g. `D1: cursor pagination, not offset; reason: O(log N)`).
- Ordered checklist (10–12 steps from migration → sqlc query → domain entity → use cases
  → repo → handlers → tests → validate gate).
- File-by-file code samples with absolute paths (`internal/domain/projects/project.go`,
  `internal/app/projects/create_project.go`, etc.) — real imports, real package names.
- Exact test list including `TestProjects_TenantIsolation_Integration_TenantACannotReadTenantB`.
- OPEN QUESTIONS table for anything not pinnable without owner input.

You read the plan, the owner resolves OPEN QUESTIONS, marks it approved.

```
/run-impl-loop docs/exec-plans/add-projects-feature.md
```

The loop runs ~10–20 minutes (size-dependent). The final summary looks like:

```
Plan: docs/exec-plans/add-projects-feature.md
Files changed: 14 (12 NEW, 2 MODIFIED)
Build: clean
Tests: passed: 22 / failed: 0 / skipped: 0 / total: 22  (race: clean)
       integration: passed: 7 / failed: 0 / total: 7
Coverage: domain 91% · app 87% · other 64%   (gates: 80% / 60% — PASS)
govulncheck: clean
Deviations: 2 reported (1 minor, 1 notable — both accepted)
Architect review: 4 real findings (0 critical, 1 high, 3 medium — all fixed)
Open questions: 0
```

Owner reviews the diff, asks you to push (per-action approval), `/push` runs `make ci`
as a preflight, pushes the branch.

### Phase 3 — auxiliary operations

| When | Command |
|---|---|
| "How does X work?" | `/onboard` for orientation; or invoke the `explain-codebase` skill for a specific area |
| Production issue / bug report | Invoke the `rca-investigator` agent — hypothesize → verify via code + SQL + telemetry → minimal fix-list. Feed the fix-list to `/run-impl-loop`. |
| Pre-merge security pass | `/architect-review backend security` |
| Drift between docs and code? | `/docs-standards-sync` |
| LLM feature change (if applicable) | `/run-evals <suite>` |
| About to push | `/push` (runs `make ci` preflight + checks branch state + asks confirmation) |

### Common failure modes (and recovery)

- **Validator never passes** (3 fix attempts exhausted) → plan is wrong OR the
  implementer is confused. Read the validator's last verdict; usually refine the plan and
  re-run.
- **`impl-build` returns `blocked: true`** → implementer hit a material divergence
  (locked decision invalidated, would need a new module, etc.). Workflow surfaces a
  blocker + recommended options; you decide. Don't override silently.
- **A test surfaces a real bug** → `testing-expert` reports it; never silently weaken the
  test. Decide whether to amend the plan or fix the implementation, then loop.
- **A critical architect finding** → STOP. Don't auto-fix critical findings; discuss the
  design with the owner first.
- **`govulncheck` finds a CVE in a new dep** → owner's call. Pin, replace, or
  accept-risk are the options; never silently ignore.

### The mental model in one line

> `/exec-plan` writes the contract. The owner approves. `/run-impl-loop` builds the
> contract. You stay in the loop for judgment; the workflows do the mechanical work.

You rarely invoke agents or workflows directly — those two commands compose them.

## Handling human-written code

The harness is designed around AI-assisted work, but it doesn't try to prevent manual
edits. Engineers will write code directly for small fixes, learning, experiments, and
hot-fixes. The honest question: **what catches manual code that bypasses `/exec-plan`
+ `/run-impl-loop`?**

### Layer-by-layer

| Layer | Catches manual code? | Why / why not |
|---|---|---|
| **Build pipeline** (golangci-lint, go vet, race detector, govulncheck, coverage gate, openapi-validate) | ✅ Fully | Runs on `make ci` / pre-commit / CI regardless of author |
| **`permissions.deny`** (secrets, `rm -rf /`, etc.) | ✅ Fully | Applies to all tool calls in any Claude Code session |
| **Hooks** (`protect-commands.sh`, `enforce-formatting.sh`) | ⚠️ Only via Claude Code | Hooks fire on Claude Code tool calls. A human editing in VS Code / Vim directly bypasses them |
| **Path-globbed rules** (`.claude/rules/*.md`) | ⚠️ Passive | Auto-load only in Claude Code sessions. Sit in the repo as Markdown — humans can read them but nothing forces it |
| **Agents** (`validator`, `architect-backend`, `security-auditor-backend`) | ⚠️ Opt-in | Don't run automatically on manual code. Human or reviewer invokes `/architect-review` |
| **Plans + ADRs** (`docs/exec-plans/`, `docs/decisions/`) | ⚠️ Convention | The implementation-plan-format doc says trivial bugfixes don't need plans. Non-trivial manual changes *should* write one, but nothing enforces it |
| **CLAUDE.md + `docs/projectStandards/`** | ⚠️ Passive | Reference material; read on joining + on demand |

### What this means in practice

**Manual code IS caught by:**

- Static analysis (~25 linters in `golangci-lint`)
- `go vet`, race detector, `govulncheck`, coverage gate
- `permissions.deny` (secrets, catastrophic shell)
- OpenAPI lint (under spec-first or code-first generation — drift fails CI)

**Manual code is NOT automatically caught by:**

- Architectural conventions that aren't lint-enforceable (rich domain entities, REPR-
  style handlers, the `Result[T]` + ProblemDetails pattern, unexported-field discipline).
  Reviewers must catch these.
- Decision-recording (ADRs). A human can ship a substantive change without writing one;
  the *why* is lost.
- Local destructive operations (a human's `git push --force` in their terminal doesn't
  hit the hook — only Claude Code tool calls do).
- Semantic concerns like tenancy correctness, overposting prevention, SSRF —
  review-only, not lint-enforceable.

### Mitigations the harness already has

- **Code review**: reviewers can invoke `/architect-review` on a teammate's branch. The
  agent reads the diff against the loaded rules and flags violations.
- **`/docs-standards-sync`**: workflow that detects systemic drift between rules and
  code, on demand.
- **CI gates**: ~25 linters + race detector + coverage gate + vuln scan + OpenAPI lint,
  all in `make ci`. Catches the mechanical class of issues regardless of author.
- **Branch protection**: if `main` requires PR review + green CI, the worst manual
  escapes are blocked at merge.

### Recommended addition — `/architect-review` on every PR

The biggest gap is that **architect-level review only runs when someone invokes it**.
For teams doing significant manual editing, the highest-leverage addition is a CI
workflow that invokes `/architect-review` on the PR diff and blocks merge on critical
findings:

```yaml
# .github/workflows/architect-review.yml (sketch)
name: architect-review
on: [pull_request]
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: anthropics/setup-claude-code@v1     # or equivalent
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      - run: claude /architect-review --diff-base origin/${{ github.base_ref }}
        # Fail the job (and block merge) if /architect-review surfaces a 'critical' finding.
```

What this buys you:

- Closes the "manual edits skip the agent layer" gap.
- Token cost: ~$2–6 per PR depending on diff size — predictable, modest.
- Gates at PR time, which is when humans expect review.
- Doesn't interrupt local workflow; humans write code however they like.

### What the harness expects of human contributors

The design assumes:

1. **Engineers read `CLAUDE.md` and `docs/projectStandards/` once on joining** — same as any onboarding doc.
2. **Engineers know the rules apply to all code** — caught by reviewers, by `/architect-review`, or by the architect-backend agent if invoked.
3. **Engineers choose when to use AI assistance** — trivial bugfixes are fine to edit directly; non-trivial work goes through `/exec-plan` → `/run-impl-loop`.
4. **Engineers participate in the decision-recording culture** — when they make a substantive call, they write an ADR via `/record-adr`.

The harness doesn't try to *make* engineers follow the standards — it *encodes* the
standards so that everyone (human, AI, new joiner) reads from the same source.

### The principle

The harness is **not a cage**. Humans editing manually still benefit from:

- The build pipeline catching mechanical issues
- The rules being documented and readable
- The plan + ADR conventions available to use
- The architect-review agents one slash command away

What the harness does NOT do:

- Forbid manual edits
- Force every change through the AI workflow
- Replace human judgment with automated gates

A human deciding "this is a 10-line bugfix; I'll just write it directly" is making a
legitimate call. The harness only gets in the way if the change is non-trivial AND the
human skips the discipline — and even then, the consequence is "drift between standards
and code," caught later by review or `/docs-standards-sync`, not "the agent refuses to
work."

## Slash commands (installed by the plugin)

| Command | What it does |
|---|---|
| `/bootstrap-go-gin-harness` | Scaffold the per-repo governance into the current directory |
| `/onboard` | Produce a grounded orientation for the project (cites file:line) |
| `/exec-plan <topic>` | Draft an implementation plan in the house format |
| `/run-impl-loop <plan path>` | Build an approved plan end-to-end (implement → validate → fix → test → review) |
| `/architect-review` | Adversarial review of the current diff (backend + security lenses) |
| `/record-adr "<title>"` | Record an Architecture Decision Record (ADR) for a non-plan / cross-cutting / mid-flight decision under `docs/decisions/` |
| `/run-evals <suite>` | Fire an LLM eval suite against the current build (if the product uses LLMs) |
| `/docs-standards-sync` | Detect drift between governance docs and the actual code |
| `/gen-launch-json` | Generate `.vscode/launch.json` for debugging the project with Delve (one config per `cmd/` entrypoint, plus debug-test / attach) |

## What ships system-wide vs. per-repo

```
~/.claude/plugins/go-gin-harness/         (system-wide once installed)
├── .claude-plugin/plugin.json
├── README.md                              (this file)
├── agents/                                (10 .md — system-wide)
├── workflows/                             (5 .js — system-wide)
├── commands/                              (9 slash commands — system-wide)
└── skills/
    ├── bootstrap-go-gin-harness/
    │   ├── SKILL.md
    │   └── template/                      ← copied INTO the target repo
    │       ├── CLAUDE.md
    │       ├── .editorconfig
    │       ├── .gitignore
    │       ├── .golangci.yml
    │       ├── .air.toml
    │       ├── .mcp.json
    │       ├── go.mod
    │       ├── Makefile
    │       ├── sqlc.yaml
    │       ├── README.md
    │       ├── .claude/
    │       │   ├── settings.json
    │       │   ├── hooks/                 (protect-commands, enforce-formatting, session-start-context)
    │       │   └── rules/                 (go-conventions + 6 + backend/{7})
    │       ├── docs/                      (product-overview + projectStandards + README pointers)
    │       ├── scripts/check-coverage.sh
    │       ├── migrations/README.md
    │       ├── evals/README.md
    │       └── test/README.md
    └── <29 other universal skills>/SKILL.md
```

## Customization

Each plugin component is editable in place under `~/.claude/plugins/go-gin-harness/`.
Common dials:

| Dial | Where | Default |
|---|---|---|
| Multi-tenancy | `skills/bootstrap-go-gin-harness/template/.claude/rules/backend/tenancy.md` | ON (delete the rule + middleware for single-tenant) |
| LLM features / evals | `template/evals/`, `template/.claude/skills/run-evals/` (if you re-vendor), `agents/eval-runner.md` | ON (delete if the product is non-AI) |
| DB | `template/sqlc.yaml` + persistence rules | pgx + sqlc + PostgreSQL |
| Linter strictness | `template/.golangci.yml` | strict; reactive suppression with comment |
| Coverage gate | `template/scripts/check-coverage.sh` + Makefile | 80% domain/app · 60% elsewhere |

## Uninstall

```bash
claude plugin uninstall go-gin-harness
```

The plugin's components disappear from your Claude Code sessions. Per-repo files already
bootstrapped into target projects stay there (they're part of those repos now); delete
manually if you want to undo a bootstrap.

## See also

- [`CHANGELOG.md`](CHANGELOG.md) — release notes
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting + hardening recommendations
- [`LICENSE`](LICENSE) — MIT
- `agents/` — the 10 sub-personas; each has its own purpose and tool surface
- `workflows/` — the 5 deterministic orchestrations
- `skills/` — the 29 on-demand procedures
- `skills/bootstrap-go-gin-harness/SKILL.md` — the bootstrap procedure
- `skills/bootstrap-go-gin-harness/template/CLAUDE.md` — the project law installed into
  every bootstrapped repo
- [Issues](https://github.com/virajs/go-gin-harness/issues) · [Discussions](https://github.com/virajs/go-gin-harness/discussions)

## Contributing

Open an issue first for any non-trivial change (new agent, new workflow, breaking
rule modification). For small fixes, a PR is fine. See `.github/PULL_REQUEST_TEMPLATE.md`
for the checklist.

This project follows the same operating model it ships: substantive changes should
go through `/exec-plan` → owner approval → `/run-impl-loop`. The PR template asks
whether you used the harness's own flow or edited manually, with a brief justification.

## License

MIT — see [LICENSE](LICENSE).
