# {{ProductName}} — Build & configuration

> Where the build governance lives, why each piece exists, and how to change them
> safely.

## File map

| File | Purpose |
|---|---|
| `go.mod` / `go.sum` | Module identity + pinned dependencies. Every dep requires owner approval. `go mod tidy` keeps `go.sum` honest. |
| `.golangci.yml` | ~25-linter suite + path-scoped excludes + per-linter settings. **Warnings = errors.** |
| `.editorconfig` | Cross-stack formatting (charset, indent, final newline). Go indent is tab. |
| `Makefile` | Canonical entry points. `make ci` is the green-bar definition. `make help` lists targets. |
| `sqlc.yaml` | SQL → typed Go config. Generated code lands in `internal/infra/persistence/_sqlcgen/`. |
| `.air.toml` | Hot-reload (dev only). |
| `.mcp.json` | Optional MCP servers wired for the harness (defaults empty). |
| `migrations/*.sql` | goose migrations; `*.up.sql` + `*.down.sql` pairs. |
| `.claude/settings.json` | Permissions + hooks + MCP. Per-user overrides in `settings.local.json` (gitignored). |
| `scripts/check-coverage.sh` | Coverage-gate enforcer; called from `make cover`. |

## Module discipline

- **Pin versions explicitly** — never depend on `latest` indirectly.
- **`go mod tidy` before every commit.** The `go.sum` diff is part of the change.
- **`go mod why <pkg>`** before adding a new dep — confirm it's truly needed.
- **No `replace` directives** without a documented reason.
- **`vendor/` not committed** — the module cache + `go.sum` verify integrity.
- **`// indirect` lines managed by `go mod tidy`** — never hand-edit.

## Linter strictness

`.golangci.yml` enables the following families:

- **Correctness**: `govet`, `errcheck`, `staticcheck`, `gosec`, `bodyclose`,
  `sqlclosecheck`, `rowserrcheck`, `nilerr`, `errorlint`, `contextcheck`, `noctx`,
  `nilnil`, `exhaustive`, `asciicheck`, `durationcheck`, `makezero`, `reassign`,
  `tparallel`, `paralleltest`, `thelper`.
- **Performance**: `prealloc`, `gocritic`.
- **Style**: `revive`, `gocyclo`, `gocognit`, `funlen`, `dupl`, `unconvert`, `unparam`,
  `misspell`, `whitespace`, `gci`, `gofumpt`, `nolintlint`.

**Tuning philosophy: maximalist, reactive.** Nothing pre-disabled. Suppress per call site
with a justification:

```go
//nolint:gocyclo // generated state machine; complexity is inherent
```

Path-scoped excludes (`.golangci.yml issues.exclude-rules`):
- `_test.go` — looser cyclomatic / length / errcheck / contextcheck (tests legitimately
  do things production code shouldn't).
- `*.sql.go` — sqlc-generated; treat as vendor.
- `cmd/*/main.go` — exempt from "must comment exported" (main has no exported symbols).

## The build pipeline

`make ci` runs (in order):

```
gofumpt -w .
goimports -w -local {{ProjectName}} .
go mod tidy
go vet ./...
go build ./...
golangci-lint run
go test -race -count=1 ./...
govulncheck ./...
make cover    # coverage gate
```

Any failure = build broken. CI mirrors this exactly; divergence between local `make ci`
and CI is a bug.

## Migrations (goose)

```
migrations/
├─ 001_init_projects.up.sql
├─ 001_init_projects.down.sql
├─ 002_add_documents.up.sql
└─ 002_add_documents.down.sql
```

- **Append-only.** Never edit an applied migration.
- **Real down migrations.** `goose down` works in dev (gated by the protect-commands
  hook for safety).
- **Apply in integration tests.** `TestMain` runs `goose.Up` against the testcontainers
  Postgres before tests; a broken migration fails the integration suite.
- **No-tx blocks** for `CREATE INDEX CONCURRENTLY`:
  ```sql
  -- +goose Up
  -- +goose NO TRANSACTION
  CREATE INDEX CONCURRENTLY ...;
  ```

## sqlc

- Queries live next to the feature: `internal/infra/persistence/<feature>/queries/*.sql`.
- `make sqlc` regenerates `internal/infra/persistence/_sqlcgen/` (committed but excluded
  from the linter).
- Repository wrappers in `internal/infra/persistence/<feature>/repository.go` adapt the
  generated types to the domain interface declared in `internal/app/<feature>/`.

## Coverage gate

`make cover` runs the suite with `-covermode=atomic` and pipes the output through
`scripts/check-coverage.sh`. Per-package thresholds:

- `internal/domain/**` and `internal/app/**` → **80%** (business logic — coverage
  correlates with correctness here).
- Everywhere else → **60%** (boilerplate / adapters — coverage as regression safety).

Override per-run: `make cover COVER_MIN_DOMAIN=85`. A drop below threshold fails CI.
Exclusions need a comment in the file:

```go
// coverage:ignore — pure passthrough; tested via integration
func wireRouter(r *gin.Engine) { … }
```

## CI mirroring

CI runs `make ci`. If you change anything in the build chain (a new tool, a new
threshold, a new step), update both the Makefile AND the CI config in the same change.

## When you change a build file

| Change | Update |
|---|---|
| New linter | `.golangci.yml`, fix new findings, document the rationale in `coding-standards.md` |
| New module | `go.mod`, justify in the plan / commit, re-run `govulncheck` |
| New make target | `Makefile` with a `## description` doc comment (`make help` picks it up) |
| New migration | Run locally, regen sqlc, write the integration test, then commit |
| New env var | Document in `cmd/api/main.go`'s flag block + `.env.example` |

## Local vs. prod config

- Local config: `.env` (gitignored). Read via `os.Getenv` or a thin config struct.
- Prod config: env vars set by the platform (k8s ConfigMap / secret, systemd, etc.).
- **Never commit `.env`.** The `.gitignore` covers it; `.env.example` documents the
  variables.
- **No config library** (viper, koanf, …) without per-module approval. Stdlib `os.Getenv`
  + `flag` covers most needs.

## See also

- `coding-standards.md` — the language standard.
- `.claude/rules/build-config.md` — the auto-loaded distillation.
- `Makefile` — `make help` lists every target.
