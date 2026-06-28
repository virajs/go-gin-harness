## {{ProductName}} — developer Makefile
##
## Every target is reproducible and verifiable. Targets that mutate (migrate, generate)
## are explicit; targets that report (lint, vet, vuln, cover) never modify the working tree.
##
## Run `make help` to see the catalog.

.DEFAULT_GOAL := help
SHELL := /bin/bash
GO    ?= go
PKG   ?= ./...

# Coverage gate (override per invocation: `make cover COVER_MIN_DOMAIN=85`)
COVER_MIN_DOMAIN ?= 80
COVER_MIN_OTHER  ?= 60

# Build metadata (stamped into the binary via -ldflags)
VERSION  ?= $(shell git describe --tags --dirty --always 2>/dev/null || echo dev)
COMMIT   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_AT ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS  ?= -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildAt=$(BUILD_AT)

## ---------- info ----------

.PHONY: help
help:  ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	  /^[a-zA-Z_/-]+:.*##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

## ---------- format & lint ----------

.PHONY: fmt
fmt:  ## Format code (gofumpt + goimports).
	gofumpt -w .
	goimports -w -local {{ProjectName}} .

.PHONY: vet
vet:  ## Run go vet (strict).
	$(GO) vet $(PKG)

.PHONY: lint
lint:  ## Run golangci-lint (warnings = errors).
	golangci-lint run $(PKG)

.PHONY: lint-fix
lint-fix:  ## Run golangci-lint with --fix.
	golangci-lint run --fix $(PKG)

## ---------- build ----------

.PHONY: build
build:  ## Build all binaries into bin/.
	@mkdir -p bin
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/ ./cmd/...

.PHONY: tidy
tidy:  ## go mod tidy.
	$(GO) mod tidy

.PHONY: download
download:  ## Pre-cache module dependencies.
	$(GO) mod download

## ---------- test ----------

.PHONY: test
test:  ## Run unit tests with the race detector.
	$(GO) test -race -shuffle=on -count=1 $(PKG)

.PHONY: test-short
test-short:  ## Skip long-running tests (-short).
	$(GO) test -race -short -count=1 $(PKG)

.PHONY: test-integration
test-integration:  ## Run integration tests (build tag: integration). Requires Docker for testcontainers.
	$(GO) test -race -tags=integration -count=1 ./test/integration/...

.PHONY: cover
cover:  ## Test with coverage; enforce the coverage gate.
	@mkdir -p .cover
	$(GO) test -race -count=1 -covermode=atomic -coverprofile=.cover/coverage.out $(PKG)
	@$(GO) tool cover -func=.cover/coverage.out | tail -n 30
	@bash scripts/check-coverage.sh .cover/coverage.out $(COVER_MIN_DOMAIN) $(COVER_MIN_OTHER)

.PHONY: cover-html
cover-html: cover  ## Open coverage in browser.
	$(GO) tool cover -html=.cover/coverage.out -o .cover/coverage.html
	@echo "Coverage: .cover/coverage.html"

## ---------- bench ----------

.PHONY: bench
bench:  ## Run benchmarks; write results to bench/<datestamp>.txt for benchstat compare.
	@mkdir -p bench
	$(GO) test -run=^$$ -bench=. -benchmem -benchtime=3s -count=5 $(PKG) | tee bench/$$(date +%Y%m%dT%H%M%S).txt

## ---------- vuln & security ----------

.PHONY: vuln
vuln:  ## Scan for known vulnerabilities (stdlib + deps).
	govulncheck $(PKG)

.PHONY: gosec
gosec:  ## Standalone gosec scan (golangci-lint already runs gosec; this is for security audits).
	gosec -quiet -exclude-dir=test ./...

## ---------- db & migrations (goose) ----------

DB_URL ?= postgres://postgres:postgres@localhost:5432/{{ProjectName}}?sslmode=disable

.PHONY: migrate-up
migrate-up:  ## Apply all up migrations.
	goose -dir migrations postgres "$(DB_URL)" up

.PHONY: migrate-down
migrate-down:  ## Roll back one migration (asks for confirmation via the protect-commands hook).
	goose -dir migrations postgres "$(DB_URL)" down

.PHONY: migrate-status
migrate-status:  ## Show migration status.
	goose -dir migrations postgres "$(DB_URL)" status

.PHONY: migrate-new
migrate-new:  ## Scaffold a new migration. NAME=add_orders make migrate-new
	@if [ -z "$(NAME)" ]; then echo "Usage: NAME=<name> make migrate-new"; exit 1; fi
	goose -dir migrations -s create $(NAME) sql

## ---------- sqlc ----------

.PHONY: sqlc
sqlc:  ## Generate typed Go from SQL queries.
	sqlc generate

## ---------- openapi ----------
##
## OpenAPI 3.0 is MANDATORY (see .claude/rules/backend/openapi.md).
## Generation approach: code-first via github.com/swaggest/rest (ADR-0003, accepted as
## the harness default — supersede with a new ADR if your project picks differently).
## The spec at $(OPENAPI_SPEC) is GENERATED — never hand-edit it.
## `cmd/openapi-gen/main.go` builds the router (with stub deps) and dumps the spec.

OPENAPI_SPEC      ?= docs/api/openapi.yaml
OPENAPI_SPEC_JSON ?= docs/api/openapi.json

.PHONY: openapi
openapi:  ## (Re)generate docs/api/openapi.{yaml,json} via swaggest/rest reflection (per ADR-0003).
	@if [ ! -f docs/decisions/0003-openapi-generation.md ]; then \
	  echo "ERROR: docs/decisions/0003-openapi-generation.md missing — see .claude/rules/backend/openapi.md"; exit 1; \
	fi
	@grep -q '^\* Status: accepted\|^\* Status: superseded' docs/decisions/0003-openapi-generation.md || { \
	  echo "ERROR: ADR-0003 (OpenAPI generation) is not accepted. Status must be 'accepted' before running make openapi."; \
	  exit 1; \
	}
	@if [ ! -d cmd/openapi-gen ]; then \
	  echo "ERROR: cmd/openapi-gen/ missing. ADR-0003 requires a generator binary that reflects the router."; \
	  echo "       Scaffold via /exec-plan + /run-impl-loop. See docs/decisions/0003-openapi-generation.md."; \
	  exit 1; \
	fi
	@mkdir -p docs/api
	$(GO) run ./cmd/openapi-gen -out-yaml $(OPENAPI_SPEC) -out-json $(OPENAPI_SPEC_JSON)
	@echo "✓ OpenAPI spec regenerated at $(OPENAPI_SPEC) and $(OPENAPI_SPEC_JSON)"

.PHONY: openapi-validate
openapi-validate:  ## Lint the OpenAPI 3.0 spec (fails CI if the spec is invalid).
	@if [ ! -f $(OPENAPI_SPEC) ]; then \
	  echo "ERROR: $(OPENAPI_SPEC) missing. Every API must ship an OpenAPI 3.0 spec — see .claude/rules/backend/openapi.md"; \
	  exit 1; \
	fi
	@echo "Validating $(OPENAPI_SPEC) ..."
	@if command -v redocly >/dev/null 2>&1; then \
	  redocly lint $(OPENAPI_SPEC); \
	elif command -v spectral >/dev/null 2>&1; then \
	  spectral lint $(OPENAPI_SPEC); \
	elif command -v npx >/dev/null 2>&1; then \
	  npx -y @redocly/cli@latest lint $(OPENAPI_SPEC); \
	else \
	  echo "ERROR: install one of: redocly, spectral, or npx (for @redocly/cli)"; exit 1; \
	fi
	@echo "✓ OpenAPI 3.0 spec valid"

.PHONY: openapi-serve
openapi-serve:  ## Open the spec in a local Redoc preview (dev convenience).
	@npx -y @redocly/cli@latest preview-docs $(OPENAPI_SPEC)

## ---------- dev ----------

.PHONY: dev
dev:  ## Run with hot reload (requires `air`).
	air -c .air.toml

.PHONY: run
run:  ## Run the API binary directly.
	$(GO) run ./cmd/api

## ---------- evals (LLM) ----------

.PHONY: evals
evals:  ## Run all eval suites under evals/.
	$(GO) run ./cmd/evals -dir evals

.PHONY: evals-baseline
evals-baseline:  ## Promote the most recent eval run to baseline.
	$(GO) run ./cmd/evals -dir evals -promote-baseline

## ---------- meta ----------

.PHONY: ci
ci: tidy fmt vet lint test cover vuln openapi-validate  ## What CI runs.
	@echo "✓ CI green"

.PHONY: clean
clean:  ## Remove build artifacts.
	rm -rf bin/ dist/ .cover/ coverage.* *.out *.prof *.pprof
