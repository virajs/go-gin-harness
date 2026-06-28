// {{ProjectName}} — replace this module path with your actual module after find/replace.
//
// Runtime dependencies are NOT pinned here yet — every third-party module requires the
// owner's explicit, per-module approval. Add them one at a time as the harness scaffolds
// (Gin, pgx, sqlc-generated code is part of your repo so no module needed for that,
// log/slog handlers, otel sdk + exporters, testify, testcontainers-go, goose, etc.).
//
// The canonical expected set (each requires per-module approval):
//
//   github.com/gin-gonic/gin                                v1.x   HTTP framework
//   github.com/jackc/pgx/v5                                 v5.x   PostgreSQL driver + pool
//   github.com/google/uuid                                  v1.x   UUIDv7 (stdlib alternative: roll own)
//   go.opentelemetry.io/otel                                v1.x   OTel SDK + exporters
//   go.opentelemetry.io/contrib/instrumentation/.../otelgin v0.x   Gin middleware
//   github.com/stretchr/testify                             v1.x   assert/require/mock
//   github.com/testcontainers/testcontainers-go             v0.x   integration test infra
//   github.com/pressly/goose/v3                             v3.x   migrations
//   github.com/golang-jwt/jwt/v5                            v5.x   JWT auth
//   github.com/go-playground/validator/v10                  v10.x  Gin's default binding validator
//
// Until a module is approved and added, the corresponding code path stays stdlib-only
// or hand-rolled. `golangci-lint`, `gofumpt`, `goimports`, `govulncheck`, `sqlc` are
// developer tools (installed via `go install ...`), not module deps.

module {{ProjectName}}

go 1.24
