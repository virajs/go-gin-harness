---
name: add-endpoint
description: Add a Gin endpoint (a feature/use case) to the Go API — feature folder, REPR-style file, request binding, dispatch use case, map Result to ProblemDetails. Use when adding or changing an HTTP endpoint under internal/api/features/.
argument-hint: <Feature>/<UseCase> (e.g. Projects/CreateProject)
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# Add a Gin endpoint

Procedure for our thin, feature-sliced API layer. Source of truth (read them):
`.claude/rules/backend/api-design.md`, `result-and-errors.md`, `cqrs.md`, `gin-conventions.md`.

## Steps

1. **Confirm the use case exists** in `internal/app/<feature>/` — endpoint is a thin
   wrapper, the use case must already be authored (or author it first via the `add-command`
   / `add-query` skill).

2. **Create the feature file** at `internal/api/features/<feature>/<usecase>.go` (REPR
   style — one file per use case, contains the request struct + response struct + handler):

   ```go
   package <feature>

   import (
       "net/http"
       "github.com/gin-gonic/gin"

       app<feature> "{{ProjectName}}/internal/app/<feature>"
       "{{ProjectName}}/internal/api/middleware"
   )

   type <usecase>Request struct {
       Field string `json:"field" binding:"required,max=128"`
   }
   type <usecase>Response struct {
       ID    string `json:"id"`
       // ...
   }

   func <usecase>Handler(uc *app<feature>.<UseCase>Handler) gin.HandlerFunc {
       return func(c *gin.Context) {
           var req <usecase>Request
           if err := c.ShouldBindJSON(&req); err != nil {
               middleware.WriteBindError(c, err)
               return
           }
           tenant, ok := middleware.TenantFromContext(c.Request.Context())
           if !ok {
               middleware.WriteProblem(c, result.Unauthorized("tenant.missing", "..."))
               return
           }
           resp, err := uc.Handle(c.Request.Context(), app<feature>.<UseCase>Command{
               TenantID: tenant,
               Field:    req.Field,
           })
           if err != nil {
               middleware.WriteProblem(c, err)
               return
           }
           c.JSON(http.StatusCreated, <usecase>Response{ ID: string(resp.ID) /* ... */ })
       }
   }
   ```

3. **Register the route** in `internal/api/features/<feature>/register.go`:

   ```go
   func Register(r *gin.RouterGroup, h Handlers) {
       g := r.Group("/<feature>")
       g.POST("", <usecase>Handler(h.<UseCase>))
       // ... other use cases of the same feature
   }
   ```

   If the feature is new, also wire it in `internal/api/router.go` and add the field to
   `Dependencies` in `cmd/api/main.go`.

4. **Check the versioning ADR first.** Read `docs/decisions/0002-api-versioning.md`:
   - If `Status: proposed` → **STOP and ask the owner to resolve it.** Don't mount any
     route until the strategy is locked. The choice changes what `register.go` looks
     like, what the OpenAPI spec key is, and what deprecation looks like later — picking
     after the fact creates rework.
   - If `Status: accepted` + **Option A (URL-path versioning)** → `internal/api/router.go`
     mounts your feature under a versioned group (`r.Group("/v1")`). Your `register.go`
     mounts paths *without* a version prefix; the group supplies it.
   - If `Status: accepted` + **Option B (header-based versioning)** → URLs are
     version-free. If this is a non-v1 implementation, add a sibling handler file
     (`create_project_v2.go`) and dispatch inside the closure based on
     `middleware.APIVersionFrom(c.Request.Context())`.

   **HTTP verb + path patterns** (the version prefix differs by strategy; everything
   below is the path *as registered by your feature's `register.go`*, without a version
   prefix in either case):
   - `POST /<feature>` for create
   - `GET /<feature>` for list
   - `GET /<feature>/:id` for fetch
   - `PATCH /<feature>/:id` for partial update (rename, status)
   - `PUT /<feature>/:id` for full replace
   - `DELETE /<feature>/:id` for delete (rarely; usually archive)
   - `POST /<feature>/:id/<action>` for actions that don't fit CRUD (archive, restore,
     publish)

   The full external URL is `/v1/<feature>/...` (Option A — prefix from the route group)
   or `/<feature>/...` (Option B — version in the header).

5. **Status code on success**:
   - `201 Created` for resource creation (set the `Location:` header to the full external
     URL — `/v1/<feature>/<id>` under Option A, `/<feature>/<id>` under Option B)
   - `200 OK` for everything else that returns a body
   - `204 No Content` for actions with no useful body (rare — usually return the new state)

6. **Validation:**
   - **Shape** — Gin `binding:"required,min=1,max=128"` tags on the request struct
   - **Business** — already in the use case (the handler trusts the use case to validate)
   - **Invariant** — domain layer (returns typed error → use case wraps → handler maps)

7. **Update the OpenAPI 3.0 spec** at `docs/api/openapi.yaml`. This is **mandatory**
   (see `.claude/rules/backend/openapi.md` and the dedicated `openapi-spec` skill — the
   full per-option procedure lives there). The spec change ships in the **same commit**
   as the handler code.
   - First, check ADR-0003 (`docs/decisions/0003-openapi-generation.md`):
     - If `Status: proposed` → STOP and ask the owner to resolve it.
     - If **Option A (spec-first)** → edit `docs/api/openapi.yaml` to add the path /
       method / parameters / request body schema / response schemas; then `make openapi`
       regenerates server interfaces; implement the handler to satisfy the new interface.
     - If **Option B (code-first)** → add the framework annotations / typed handler;
       `make openapi` regenerates `docs/api/openapi.yaml`; verify the diff matches intent.
     - If **Option C (manual)** → hand-write the path entry in `docs/api/openapi.yaml`
       and the handler in parallel; the integration test asserts they agree.
   - Every endpoint MUST include in the spec: `summary`, `tags`, `operationId`,
     `parameters` (path/query/header), `requestBody` (when applicable), `responses` for
     **every** status the endpoint can emit (success + each error class — 400, 401, 403,
     404, 409, 500), and `security` (or `security: []` for public endpoints).
   - Use `$ref` to component schemas (`#/components/schemas/<Name>`) — never inline.
   - Errors `$ref` the shared `#/components/schemas/ProblemDetails` component (matches the
     RFC 9457 shape from `internal/api/middleware/problem_details.go`).
   - Run `make openapi-validate` — broken spec is a build failure.

8. **Run the build pipeline**:
   ```bash
   gofumpt -w .
   goimports -w -local {{ProjectName}} .
   go vet ./internal/api/...
   go build ./...
   golangci-lint run ./internal/api/...
   make openapi-validate
   ```

9. **Write the tests** — invoke the `write-unit-tests` skill for the handler (mostly
   covers binding + dispatch + mapping) and `write-integration-tests` for the end-to-end
   path (real HTTP request → DB row). The integration test SHOULD also assert the
   response payload conforms to the OpenAPI spec (use `kin-openapi` runtime validator or
   a hand-written schema check) — catches code/spec drift even under Option B's codegen.

## Conventions (restated)

- **No business logic, persistence, or model routing in the handler.** It binds, validates
  shape, dispatches, maps.
- **No `gin.H{}` literals in responses** — always the typed response struct.
- **No `c.AbortWithStatus(500)`** — every error goes through the ProblemDetails mapper.
- **`c.Request.Context()`** propagated to the use case — never `context.Background()`.
- **No new module imports** (FastAPI-style validation libraries, alternate response
  serializers) without per-module approval.
- **Tenant from context, NOT from the request body.** Overposting protection is
  non-negotiable.

## Common mistakes (don't)

- Binding `c.ShouldBindJSON` onto a domain entity directly. Always bind to a request DTO.
- Putting business validation in the handler ("if x.IsArchived { return … }"). That belongs
  in the use case or domain.
- Reading from the DB in the handler. The use case loads.
- Returning `*domain.Project` directly as the response body. Map to a `ProjectResponse`.
- Using `gin.H` instead of a typed struct. The JSON shape drifts silently.

## After the change

Update the OpenAPI spec (if maintained) at `docs/api/openapi.yaml`. Add the example
request/response. Bump the version banner in the plan once the tests pass.
