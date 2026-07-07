# Changelog

All notable changes to this plugin are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] — 2026-07-07

### Added

- **Dynamic isolated dev environments** — develop features/bugs/improvements in parallel,
  each in its own git worktree + isolated runtime (per-worktree Docker Compose Postgres,
  deterministic collision-free ports, generated `.env`).
  - New `dev-worktree` skill + `/worktree` command (`new`/`ls`/`env`/`up`/`down`/`rm`/`doctor`),
    driven by a repo-local `scripts/worktree.sh`. Registry-based lowest-free-index port
    allocation under an atomic lock; push-style safety gates (refuses a dirty worktree or an
    unmerged branch without `--yes`). Runtime-aware — worktree-only in repos without
    `compose.dev.yaml` (e.g. this plugin repo itself).
  - Bootstrap template gains `compose.dev.yaml` (parameterized Postgres 16-alpine),
    `scripts/worktree.sh`, `Makefile` `.env` include + `env`/`env-up`/`env-down` targets, and
    a `PORT`/`DATABASE_URL`-from-env config contract (`gin-conventions.md`, `build-config.md`,
    `CLAUDE.md`). Integration tests are untouched (they use testcontainers).
  - `/exec-plan <topic> --isolate` provisions a worktree for the plan before running the
    `exec-plan-build` workflow (workflow unchanged — isolation happens in the command layer).

## [0.4.0] — 2026-07-06

### Added

- **Automated CLAUDE.md maintenance pipeline** (bootstrap template) — a new per-repo
  `SessionStart` hook, `.claude/hooks/claude-md-maintenance.sh`, fingerprints the repo
  state that CLAUDE.md's derived sections are generated from (directory layout,
  `.golangci.yml`, `Makefile`, `docs/projectStandards/`, `.claude/rules/`, `go.mod`
  module, tenancy signal). When any tracked input drifts from the committed baseline
  (`.claude/hooks/context/.claude-md.fingerprint`), it injects a passive `additionalContext`
  nudge to run `/refresh-claude-md`. The hook detects; the `/refresh-claude-md` command
  regenerates CLAUDE.md and re-baselines the fingerprint (`--update-fingerprint`), clearing
  the nudge. Fails open; wired into `template/.claude/settings.json` alongside the existing
  session-start context hook.

## [0.3.0] — 2026-07-05

### Added

- **`/refresh-claude-md` slash command** — on-demand refresh of the repo's CLAUDE.md
  against the actual code: regenerates the derived sections (status banner, "Where things
  live" tree, build gates, doc-pointer links) from ground truth, preserves the
  human-authored "Ways of working" governance and product vision, flags dead links, and
  asks before rewriting or dropping any governance rule / design non-negotiable. Supports
  `--dry-run` (propose-only, like `docs-standards-sync`).

## [0.2.0] — 2026-07-01

### Added

- **`/gen-launch-json` slash command** — generates a VS Code `.vscode/launch.json` for
  debugging the project with Delve: one `launch`/`debug` config per `cmd/` entrypoint,
  plus debug-current-file, debug-package-tests, and attach-to-process. Detects
  entrypoints and `.env` from the real repo layout and merges into an existing
  `launch.json` rather than clobbering it.

## [0.1.0] — 2026-06-29

Initial public release.

### Added

- **Plugin manifest + single-plugin marketplace** (`.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`) — install via
  `claude plugin marketplace add https://github.com/virajs/go-gin-harness` then
  `claude plugin install go-gin-harness@go-gin-harness`.
- **10 specialized agents** — architect-backend, architect-fullstack, implementer,
  validator, testing-expert, rca-investigator, security-auditor-backend,
  findings-verifier, eval-runner, exec-planner.
- **5 deterministic workflows** — impl-build, architect-review, docs-standards-sync,
  eval-run, exec-plan-build.
- **29 on-demand skills** — including bootstrap-go-gin-harness (scaffolds per-repo
  governance), add-endpoint, add-command, add-query, add-domain-entity, sqlc-patterns,
  result-pattern, validation-scopes, write-unit-tests, write-integration-tests,
  otel-instrumentation, race-detector, govulncheck, pprof-profiling, benchmarking,
  go-performance-review, query-postgres, query-telemetry, security-backend, go-ai-stack,
  mcp-go, run-impl-loop, run-evals, exec-plan, record-adr, openapi-spec, onboard, push,
  explain-codebase, pgx-query-performance.
- **8 slash commands** — `/bootstrap-go-gin-harness`, `/onboard`, `/exec-plan`,
  `/run-impl-loop`, `/architect-review`, `/record-adr`, `/run-evals`,
  `/docs-standards-sync`.
- **Per-repo template** installed by the bootstrap skill — 44 files covering:
  CLAUDE.md (project law), 14 path-globbed rules (`.claude/rules/`), 3 hooks
  (protect-commands, enforce-formatting, session-start-context), build pipeline
  (`Makefile`, `.golangci.yml`, `sqlc.yaml`, `.air.toml`), 8 standards docs
  (`docs/projectStandards/`), ADR convention (`docs/decisions/` with template +
  meta-ADR + pre-accepted defaults for API versioning and OpenAPI generation), plan
  format (`docs/exec-plans/`), coverage-gate script.
- **OpenAPI 3.0 mandate** as a first-class harness concern — auto-loaded rule, CI gate
  (`make openapi-validate`), `/openapi.{json,yaml}` serving endpoints, dedicated
  `openapi-spec` skill, ADR-locked generator choice (default: code-first via
  swaggest/rest).
- **ADR convention** — `docs/decisions/` with `0000-template.md`, meta-ADR
  `0001-record-adrs.md`, pre-accepted defaults for `0002-api-versioning` and
  `0003-openapi-generation`. `/record-adr` skill + slash command for recording new
  decisions.
- **Multi-agent operating model documentation** — README sections covering install,
  bootstrap, implementing features (three-phase loop), handling human-written code,
  customization, uninstall.

### Notes

This is the first public release. Expect minor breaking changes through v0.x as the
operating model stabilizes. v1.0 will lock the slash command surface + per-repo
template + agent contracts.

[Unreleased]: https://github.com/virajs/go-gin-harness/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/virajs/go-gin-harness/releases/tag/v0.1.0
