# Changelog

All notable changes to this plugin are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
