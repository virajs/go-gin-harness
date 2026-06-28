---
description: API layer design — Gin handlers, feature folders, REPR style, contract validation, dispatch use case, map Result to ProblemDetails. Auto-loads on internal/api/**.
paths:
  - "internal/api/**/*.go"
---

# API design

Authoritative refs: `add-endpoint` skill, `gin-conventions.md`, `result-and-errors.md`.

## The thin layer

API handlers are **thin glue**:

1. Bind the request body / params (shape validation via Gin tags)
2. Read auth / tenancy from context
3. Build the use-case command/query struct
4. Dispatch — call `useCase.Handle(ctx, cmd)`
5. Map the result — success to typed JSON, error to ProblemDetails

**No business logic, no persistence, no model routing in handlers.** If a handler is more
than ~30 lines, the logic almost certainly belongs in the use case.

## Feature folder layout

```
internal/api/
├─ features/
│  ├─ projects/
│  │  ├─ create_project.go          handler + request + response in REPR style
│  │  ├─ get_project.go
│  │  ├─ list_projects.go
│  │  ├─ rename_project.go
│  │  ├─ archive_project.go
│  │  └─ register.go                 Register(r *gin.RouterGroup, deps Dependencies)
│  ├─ documents/
│  │  └─ ...
│  └─ register.go                    (top-level — calls each feature's Register)
├─ middleware/
│  ├─ auth.go
│  ├─ tenancy.go
│  ├─ request_id.go
│  ├─ slog_logger.go
│  ├─ otel.go
│  ├─ timeout.go
│  └─ problem_details.go
└─ router.go                          NewRouter(deps) *gin.Engine — composition root for routing
```

## REPR style (one file per use case)

Endpoint + Request + Response together:

```go
// internal/api/features/projects/create_project.go
package projects

import (
    "net/http"
    "time"

    "github.com/gin-gonic/gin"

    appprojects "{{ProjectName}}/internal/app/projects"
    "{{ProjectName}}/internal/api/middleware"
    "{{ProjectName}}/internal/shared/result"
)

// Request — bound from JSON body. Shape validation via tags.
type createProjectRequest struct {
    Name string `json:"name" binding:"required,min=1,max=128"`
}

// Response — what the client gets.
type createProjectResponse struct {
    ID        string    `json:"id"`
    Name      string    `json:"name"`
    CreatedAt time.Time `json:"created_at"`
}

// createHandler — the actual Gin handler. Closure captures the use case.
func createHandler(uc *appprojects.CreateProjectHandler) gin.HandlerFunc {
    return func(c *gin.Context) {
        var req createProjectRequest
        if err := c.ShouldBindJSON(&req); err != nil {
            middleware.WriteBindError(c, err) // -> 400 ProblemDetails validation
            return
        }

        tenant, ok := middleware.TenantFromContext(c.Request.Context())
        if !ok {
            middleware.WriteProblem(c, result.Unauthorized("tenant.missing", "tenant context required"))
            return
        }

        resp, err := uc.Handle(c.Request.Context(), appprojects.CreateProjectCommand{
            TenantID: tenant,
            Name:     req.Name,
        })
        if err != nil {
            middleware.WriteProblem(c, err) // -> ProblemDetails per error type
            return
        }

        c.JSON(http.StatusCreated, createProjectResponse{
            ID:        string(resp.ID),
            Name:      resp.Name,
            CreatedAt: resp.CreatedAt,
        })
    }
}
```

## `register.go` per feature

```go
package projects

import (
    "github.com/gin-gonic/gin"
    appprojects "{{ProjectName}}/internal/app/projects"
)

type Handlers struct {
    Create   *appprojects.CreateProjectHandler
    Get      *appprojects.GetProjectHandler
    List     *appprojects.ListProjectsHandler
    Rename   *appprojects.RenameProjectHandler
    Archive  *appprojects.ArchiveProjectHandler
}

func Register(r *gin.RouterGroup, h Handlers) {
    g := r.Group("/projects")
    g.POST("",          createHandler(h.Create))
    g.GET("",           listHandler(h.List))
    g.GET("/:id",       getHandler(h.Get))
    g.PATCH("/:id",     renameHandler(h.Rename))
    g.POST("/:id/archive", archiveHandler(h.Archive))
}
```

`internal/api/router.go`:

```go
func NewRouter(deps Dependencies) *gin.Engine {
    r := gin.New()
    r.Use(/* middleware stack — see gin-conventions.md */)

    v1 := r.Group("/v1")
    projects.Register(v1, projects.Handlers{
        Create:  deps.CreateProject,
        Get:     deps.GetProject,
        // ...
    })
    documents.Register(v1, documents.Handlers{...})

    // Top-level (unversioned, unauthenticated): health + OpenAPI spec.
    r.GET("/healthz", healthz)
    r.GET("/readyz",  readyz(deps.DB))
    openapi.Register(r.Group(""))           // GET /openapi.json, GET /openapi.yaml
    return r
}
```

## Request validation — shape only at this layer

```go
type createProjectRequest struct {
    Name        string    `json:"name" binding:"required,min=1,max=128"`
    Description string    `json:"description,omitempty" binding:"max=1024"`
    Visibility  string    `json:"visibility,omitempty" binding:"oneof=public private"`
}
```

- **Required / max / min / oneof** — shape. Good.
- **"Name not already in use"** — business; goes in the use-case validator.
- **"Tenant exists and is active"** — business; use-case.
- **"Project name doesn't contain banned word"** — debatable. Static list? Shape (tag with
  `notblacklisted=...`). Dynamic / per-tenant? Business.

## Response shapes

- **Always use a typed response struct.** Never `gin.H{"name": p.Name}` literals — that's
  how fields silently drift from documentation.
- **Snake_case JSON keys.** Configurable per repo, but pick one and use it everywhere.
  Domain code keeps PascalCase fields; the JSON tag on the response struct does the mapping.
- **Optional fields use pointers OR `omitempty`** — be deliberate. `omitempty` on a value
  type hides the zero value; pointer makes "null" vs "absent" distinguishable.
- **No `internal/domain` types in responses.** Map domain → response struct in the handler.
  The API contract is decoupled from the domain shape.

## Error responses

Always RFC 9457 ProblemDetails. The `WriteProblem(c, err)` middleware helper handles every
typed error from `internal/shared/result/`. Status codes:

| Type | Status |
|---|---|
| `result.TypeFailure` (unexpected) | 500 |
| `result.TypeValidation` | 400 |
| `result.TypeNotFound` | 404 |
| `result.TypeConflict` | 409 |
| `result.TypeUnauthorized` | 401 |
| `result.TypeForbidden` | 403 |

A bare panic in a handler → recovery middleware → 500 with a generic ProblemDetails
(without leaking the stack trace). Logged at `Error` level with full stack for diagnosis.

## Auth and tenancy

- **Auth middleware** validates JWT / session and puts claims in the request context
  (`AuthFromContext(ctx)` → `(Claims, bool)`).
- **Tenancy middleware** derives `tenant_id` from claims and puts it in the context
  (`TenantFromContext(ctx)` → `(TenantID, bool)`). **Reject the request if no tenant** —
  fail-closed.
- **Handlers read tenant from context, never from the request body.** Overposting protection.

## Versioning

**The versioning strategy is a per-project decision.** The two supported options are
**URL-path versioning** (`/v1/projects`) and **header-based versioning** (e.g.
`Accept: application/vnd.{{ProjectName}}.v1+json` or `X-API-Version: 1`). Neither is
the default; the owner picks.

The decision is recorded in [`docs/decisions/0002-api-versioning.md`](../../../docs/decisions/0002-api-versioning.md).

> **STOP and ask the owner to resolve ADR-0002 before mounting any routes** if its
> `Status:` is still `proposed`. Both options shape `router.go`, the OpenAPI spec, the
> client SDK contract, and deprecation policy — committing routes before the decision is
> made creates rework. The validator agent treats unresolved ADR-0002 + new routes as a
> blocking issue.

### Once decided (regardless of strategy)

- **One major version per breaking change.** Additive changes (new field, new endpoint)
  ship without a version bump.
- **Removals or renames** require a new major version + a deprecation window.
- **OpenAPI 3.0 spec is MANDATORY** at `docs/api/openapi.yaml`, served by the API at
  `GET /openapi.json` and `GET /openapi.yaml`. See [`openapi.md`](openapi.md) for the
  contract and [`docs/decisions/0003-openapi-generation.md`](../../../docs/decisions/0003-openapi-generation.md)
  for the generator choice (spec-first / code-first / manual). The validator agent
  blocks PRs that add an endpoint without updating the spec.

### Option A — URL-path versioning

Routes mount under a versioned group; version is part of the URL.

```go
// router.go
v1 := r.Group("/v1")
projects.Register(v1, ...)            // → POST /v1/projects, GET /v1/projects/:id, ...

v2 := r.Group("/v2")                  // when v2 ships
projectsV2.Register(v2, ...)          // → POST /v2/projects, ...
```

- The version prefix is chosen ONCE in `router.go`. Features do not write `/v1/` into
  their own `register.go` — they receive a pre-grouped `*gin.RouterGroup`.
- Health endpoints (`/healthz`, `/readyz`, `/metrics`) stay at the top level
  unversioned.

### Option B — Header-based versioning

URL stays version-free; a middleware reads the version from a request header and
dispatches to the appropriate handler chain.

```go
// router.go
r.Use(middleware.APIVersion("X-API-Version", "1"))   // header name + default
projects.Register(r.Group("/projects"), ...)         // → POST /projects (version from header)
```

```go
// middleware/api_version.go
func APIVersion(header, defaultVer string) gin.HandlerFunc {
    return func(c *gin.Context) {
        v := c.GetHeader(header)
        if v == "" { v = defaultVer }
        ctx := WithAPIVersion(c.Request.Context(), v)
        c.Request = c.Request.WithContext(ctx)
        c.Next()
    }
}
```

- Each handler that has multiple versions reads the version from context and dispatches.
  Common pattern: a thin `vN` shim in `internal/api/features/<feature>/<usecase>_v2.go`
  invoked from the same route when the header says v2.
- Common in REST-heavy designs where stable URLs are valued (mobile clients, partner
  integrations that hard-code URLs).
- Trade-off: harder to test from a browser / `curl` without remembering headers; some
  HTTP caches don't `Vary` on custom headers by default.

### Implementation locks (binding to whichever option is chosen)

| Concern | URL-path | Header-based |
|---|---|---|
| Where the version is set | `router.go` route group | `APIVersion` middleware reading a request header |
| What `register.go` per feature looks like | Receives a `*gin.RouterGroup`; mounts paths *without* a version prefix | Same — receives a `*gin.RouterGroup`; mounts paths *without* a version prefix |
| Handler reads version from | Not needed — different handlers per version live under different route trees | `APIVersionFrom(ctx)` |
| OpenAPI spec key | `/v1/projects`, `/v2/projects` | `/projects` with `parameters: [{ in: header, name: X-API-Version }]` |
| Deprecation signal | New `/vN+1/` group; eventually remove `/vN/` | Reject the old version in middleware with 410; document the sunset |

## Idempotency

- **GET / HEAD / OPTIONS** are safe + idempotent by definition.
- **PUT / DELETE** are idempotent — designed so.
- **POST** is not idempotent by default. For dangerous POSTs (creating a billed resource,
  triggering a payment), accept an `Idempotency-Key` header; the use case checks for the
  key + tenant in a dedupe table and returns the cached response on repeat.

## What we don't do at the API layer

- **No business logic.** Move to `internal/app/<feature>/`.
- **No persistence calls.** No `pgx` imports in `internal/api`.
- **No model routing.** If the API decides which downstream service to call based on
  request content, that's business logic — move it.
- **No in-band auth.** The auth middleware decides; the handler trusts the context.
- **No `internal/domain` types leak in responses.** Always map to a response struct.
- **No reflection-based handler discovery.** The `Register` per feature is hand-maintained —
  the slight wiring cost buys compile-time correctness.
