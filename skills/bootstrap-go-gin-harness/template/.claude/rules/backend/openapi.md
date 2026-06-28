---
description: Every API change MUST update the OpenAPI 3.0 spec at docs/api/openapi.yaml. The API serves the spec at GET /openapi.json (and /openapi.yaml). CI validates the spec; broken spec fails the build. Generation approach (spec-first / code-first / manual) is a per-project decision recorded in an ADR.
paths:
  - "internal/api/**/*.go"
  - "docs/api/**"
  - "Makefile"
---

# OpenAPI 3.0 documentation

**Every endpoint in this API MUST be documented in OpenAPI 3.0.** No exceptions, no
"will document later". The spec is part of the same commit as the endpoint code.

## The contract — non-negotiable

1. **Spec format**: OpenAPI 3.0 or later (NOT Swagger 2.0 / OpenAPI 2.0).
2. **Spec location**: `docs/api/openapi.yaml` (YAML preferred; `.json` also acceptable —
   pick one per project).
3. **Spec endpoints exposed by the running service** (unauthenticated, no tenancy):
   - `GET /openapi.json` — serves the spec as JSON, `Content-Type: application/openapi+json`
   - `GET /openapi.yaml` — serves the spec as YAML, `Content-Type: application/yaml`
   - `Cache-Control: public, max-age=300` (short TTL — spec evolves)
4. **Optional documentation UI** at `GET /docs` (Redoc / Swagger UI / Scalar) — locked
   behind feature flag in production; always on in dev.
5. **Spec MUST validate** — every CI run validates with a real OpenAPI linter
   (`redocly lint` or `spectral lint`); broken spec fails the build.
6. **Spec MUST be versioned with the code** — committed, reviewed in PRs, never `.gitignore`d.
7. **Generation approach**: **code-first via `github.com/swaggest/rest`**, the harness
   default in [`docs/decisions/0003-openapi-generation.md`](../../../docs/decisions/0003-openapi-generation.md)
   (status: accepted, 2026-06-27). The spec at `docs/api/openapi.yaml` is **generated** —
   never hand-edit it; `make openapi` regenerates it by reflecting registered routes +
   request/response types. `cmd/openapi-gen/main.go` is the generator binary; the
   running API embeds the generated spec via `//go:embed` and serves the required
   endpoints. *Supersede ADR-0003 with a new ADR if your project warrants a different
   approach (spec-first / huma / manual) — see ADR-0003's "How to supersede" section.*

## What every endpoint contributes to the spec

Each `internal/api/features/<feature>/<usecase>.go` adds to the spec:

- **Path + method** — the route + HTTP verb (`POST /v1/projects`, `GET /projects/:id`, etc.,
  depending on the api-versioning ADR's choice).
- **Summary + description** — one-sentence summary; multi-paragraph description.
- **Request body schema** — `$ref` to a component schema named after the request DTO
  (`#/components/schemas/CreateProjectRequest`).
- **Path / query / header parameters** — typed, required vs optional, descriptions.
- **Response schemas** — at minimum: success (200/201) AND each failure status the
  endpoint can emit (400 validation, 401, 403, 404, 409, 500). Each `$ref`s a component
  schema.
- **Tags** — group by feature (`tags: [Projects]`).
- **operationId** — unique, kebab-case, derived from `{Verb}{Noun}` (`create-project`).
- **Security requirements** — which auth schemes apply (or `security: []` for public).
- **Deprecation marker** — `deprecated: true` + `x-deprecation-date` + sunset header
  when applicable.

## Component schemas

- **One schema per DTO** (request, response, error). Reuse via `$ref`.
- **Error response schema** is shared: `#/components/schemas/ProblemDetails` mirrors the
  RFC 9457 ProblemDetails shape used by `internal/api/middleware/problem_details.go`.
- **No inlined object schemas** in the path responses. Every named shape is a component.

## What the spec serving endpoint looks like

```go
// internal/api/features/openapi/openapi.go (or wherever you place it)
package openapi

import (
    "net/http"
    "github.com/gin-gonic/gin"
)

// Spec — loaded once at startup. Embed via `//go:embed` or read from disk at boot.
//go:embed openapi.yaml
var specYAML []byte
//go:embed openapi.json
var specJSON []byte    // generated alongside the yaml via `make openapi`

func Register(r *gin.RouterGroup) {
    r.GET("/openapi.yaml", func(c *gin.Context) {
        c.Header("Content-Type", "application/yaml")
        c.Header("Cache-Control", "public, max-age=300")
        c.Data(http.StatusOK, "application/yaml", specYAML)
    })
    r.GET("/openapi.json", func(c *gin.Context) {
        c.Header("Cache-Control", "public, max-age=300")
        c.Data(http.StatusOK, "application/openapi+json", specJSON)
    })
}
```

Mount at the top level (not under `/v1`), since the spec describes ALL versions:

```go
// router.go
r := gin.New()
r.Use(/* middleware stack */)

openapi.Register(r.Group(""))       // → GET /openapi.json, GET /openapi.yaml
r.GET("/healthz", healthz)
r.GET("/readyz",  readyz(deps.DB))
// versioned routes
v1 := r.Group("/v1")
projects.Register(v1, deps.Projects)
```

## Build pipeline integration

The `Makefile` provides three targets (the actual commands depend on the chosen ADR-0003
generator):

```bash
make openapi              # regenerate the spec OR code (per the ADR's chosen direction)
make openapi-validate     # validate the spec — `redocly lint` or `spectral lint`
make ci                   # runs `openapi-validate` as part of the green-bar check
```

CI must include `openapi-validate`. A spec that doesn't lint is a build failure, same
class as a failing test.

## When you add or change an endpoint

The `add-endpoint` skill walks this; restated for emphasis:

1. **Write or update the spec** at `docs/api/openapi.yaml`.
2. **Run `make openapi`** to regenerate the other side (server stubs if spec-first; spec
   if code-first).
3. **Verify the diff** matches your intent — no surprise schema changes.
4. **Update the integration test** to assert the response shape matches the spec.
5. **Commit the spec + the code + the test in the same commit** — they travel together.

## Hard rules

- Spec MUST be OpenAPI 3.0 or later — never 2.0.
- Spec MUST be the source of truth — code drift is a bug, fix the drift, never the spec.
- Spec MUST be in the repo, committed, reviewed.
- Spec MUST validate in CI; a broken spec fails the build.
- The `/openapi.{json,yaml}` endpoints MUST be served by the running API.
- Every endpoint MUST be in the spec (no "internal-only" undocumented routes; if it's
  reachable, it's documented).
- Every error response shape MUST be `ProblemDetails` per the result-and-errors rule.

## What this rule does NOT cover

- The choice of generator (spec-first / code-first / manual) — see ADR-0003.
- The choice of documentation UI tool (Redoc / Swagger UI / Scalar) — pick at scaffold
  time; document in the foundation plan.
- API versioning shape (URL-path vs header) — see ADR-0002 + the api-design rule's
  Versioning section.
- Webhook documentation (AsyncAPI) — out of scope; this rule is HTTP/REST only.
