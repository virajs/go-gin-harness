---
name: openapi-spec
description: Author or update the OpenAPI 3.0 spec for the API — find the chosen generator approach in the ADR, follow the matching procedure (spec-first / code-first / manual), regenerate, validate, embed the spec for the serving endpoint. Use when adding or changing an endpoint, reshaping a response, or changing the error contract. Complements the add-endpoint skill.
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# Author / update the OpenAPI 3.0 spec

OpenAPI 3.0 is **mandatory** in this harness (see `.claude/rules/backend/openapi.md`).
The running API serves the spec at `GET /openapi.json` and `GET /openapi.yaml`; CI
validates with `make openapi-validate`; a missing or invalid spec fails the build.

This skill is the **procedure**. Pair with `add-endpoint` (which invokes this skill at
step 7) and `add-command` / `add-query` (which produce the use cases the spec describes).

## Step 0 — find the chosen generator

The spec is produced one of three ways per project. Read
`docs/decisions/*-openapi-generation.md`:

| ADR status | What to do |
|---|---|
| `proposed` | **STOP.** Surface to the owner; resolve the ADR before continuing. Mounting routes without a locked generator creates rework. |
| `accepted` + **Option A (spec-first, oapi-codegen)** | Edit the YAML directly; `make openapi` regenerates server interfaces; implement against the new interface. |
| `accepted` + **Option B (code-first, swaggest/rest or huma)** | Edit the handler + request/response struct tags; `make openapi` regenerates the YAML; **NEVER hand-edit `docs/api/openapi.yaml`** — your edits get clobbered. |
| `accepted` + **Option C (manual)** | Hand-edit both the YAML and the handler; integration tests catch drift. |

The remainder of this skill branches on the chosen option.

---

## Option A — Spec-first (oapi-codegen / ogen)

### 1. Edit `docs/api/openapi.yaml`

Add or update the path entry. The minimum every path needs:

```yaml
paths:
  /v1/projects:                            # (or /projects under header-versioning per ADR-0002)
    post:
      operationId: create-project
      summary: Create a project
      description: |
        Creates a new project in the caller's tenant. Returns the project id and
        timestamps.
      tags: [Projects]
      security:
        - bearerAuth: []                   # or `security: []` for unauthenticated routes
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateProjectRequest'
      responses:
        '201':
          description: Project created.
          headers:
            Location:
              description: URL of the created project.
              schema: { type: string }
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CreateProjectResponse'
        '400': { $ref: '#/components/responses/Validation' }
        '401': { $ref: '#/components/responses/Unauthorized' }
        '403': { $ref: '#/components/responses/Forbidden' }
        '409': { $ref: '#/components/responses/Conflict' }
        '500': { $ref: '#/components/responses/InternalServerError' }
```

### 2. Add / update component schemas

```yaml
components:
  schemas:
    CreateProjectRequest:
      type: object
      required: [name]
      properties:
        name:
          type: string
          minLength: 1
          maxLength: 128
          description: Human-readable name.
        description:
          type: string
          maxLength: 1024
          description: Optional description.
    CreateProjectResponse:
      type: object
      required: [id, name, created_at]
      properties:
        id: { type: string, format: uuid }
        name: { type: string }
        created_at: { type: string, format: date-time }
```

`ProblemDetails` + the shared `responses` (Validation, NotFound, Unauthorized, etc.) live
in `components` and are `$ref`'d by every error response. Don't duplicate them.

### 3. Regenerate server stubs

```bash
make openapi
```

This runs `oapi-codegen` (per ADR-0003's configuration), regenerating
`internal/api/_generated/server.gen.go`. **Verify the diff matches your intent** — no
surprise schema changes.

### 4. Implement the handler against the new interface

The generated `ServerInterface` now has a method matching your new operation. Implement
it in `internal/api/features/<feature>/<usecase>.go` per the existing REPR pattern.

### 5. Validate + commit

```bash
make openapi-validate     # lints the spec
go build ./...            # confirms handler satisfies the generated interface
```

Commit spec + handler + tests in **one commit**.

---

## Option B — Code-first (swaggest/rest, huma)

### 1. Update the request / response struct tags

The struct tags ARE the spec under Option B. Annotate aggressively:

```go
type CreateProjectRequest struct {
    Name        string `json:"name"        binding:"required,min=1,max=128" description:"Human-readable name." example:"Apollo"`
    Description string `json:"description,omitempty" binding:"max=1024"     description:"Optional description."`
}

type CreateProjectResponse struct {
    ID        string    `json:"id"         description:"UUIDv7 project id."  example:"01HN2K..."`
    Name      string    `json:"name"`
    CreatedAt time.Time `json:"created_at" description:"UTC creation time."   format:"date-time"`
}
```

Tags vary slightly by library — check the ADR-0003 / 0004 lock for the chosen one
(swaggest/rest uses `description`, `example`, `format`; huma uses `doc`, `example`).

### 2. Register the handler via the framework

For swaggest/rest:

```go
// register.go
func Register(s *web.Service, h Handlers) {
    s.Post("/projects", createHandler(h.Create),
        nethttp.SuccessStatus(http.StatusCreated),
        nethttp.OperationID("create-project"),
        nethttp.Tags("Projects"),
    )
}
```

For huma, the `huma.Register` form. Either way, **never call `router.POST(...)`
directly** — direct Gin registration bypasses the reflector and produces an undocumented
endpoint.

### 3. Regenerate the spec

```bash
make openapi
```

This runs `cmd/openapi-gen/main.go`, which builds the full router with stub deps and
dumps `docs/api/openapi.yaml` + `docs/api/openapi.json`.

### 4. **Verify the diff** in `docs/api/openapi.yaml`

Even though the spec is generated, **review it like code** — the reflector occasionally
produces an unintended schema (e.g. a pointer field that should be required is marked
optional). Adjust the struct tags until the spec is right.

### 5. Validate + commit

```bash
make openapi-validate
go build ./...
go test -race ./...
```

Commit struct + register.go + generated spec in **one commit**.

### When the reflector can't express what you need

Some shapes don't reflect cleanly:
- `oneOf` with a discriminator field
- Conditional required fields
- Polymorphic responses

swaggest/rest exposes manual schema overrides (`openapi3.SchemaOrRef`); huma exposes
similar. Use sparingly — if you reach for overrides more than ~3 times in a project,
revisit ADR-0003 / 0004 and consider migrating to Option A.

---

## Option C — Manual

### 1. Hand-write the path entry in `docs/api/openapi.yaml`

Same shape as Option A's example, but no codegen — you author it.

### 2. Hand-write the handler

Same as any add-endpoint flow, but you're responsible for keeping the two in sync.

### 3. Validate

```bash
make openapi-validate
```

### 4. Verify drift via the integration test

Every integration test for an endpoint MUST assert the response shape matches the spec.
Two practical approaches:

- **`kin-openapi` runtime validator**: load the spec at test setup; for each request,
  validate the response against the operation's schema. Catches drift on every test run.
- **Hand-written schema check**: parse the response JSON; assert required fields present,
  unexpected fields absent.

Without one of these, Option C drifts silently. The harness recommends the runtime
validator.

---

## Hard rules (regardless of option)

- **Every error response `$ref`s `#/components/schemas/ProblemDetails`** — the shape from
  the result-and-errors rule (RFC 9457). Never inline error schemas.
- **Every endpoint declares EVERY status it can emit** — success + 400 (validation) +
  401 + 403 + 404 + 409 + 500. Missing one means the contract lies.
- **`operationId` is unique, kebab-case** — derived from `{Verb}{Noun}` (`create-project`).
  Some client generators key off this.
- **`tags`** groups endpoints by feature. One tag per endpoint; tag value matches the
  feature folder name.
- **`security`** is explicit — `[{ bearerAuth: [] }]` for authenticated endpoints,
  `security: []` (empty array, not absent) for explicitly-public ones.
- **The `/openapi.{json,yaml}` endpoints are unauthenticated** — clients pull the spec
  to generate SDKs before they have credentials.
- **Spec version is OpenAPI 3.0.x or 3.1.x** — never 2.0.
- **`info.version`** reflects the API version, not the build. Bump on breaking changes
  (matching the api-versioning ADR's strategy).

## Common mistakes (don't)

- **Hand-editing `docs/api/openapi.yaml` under Option B.** It gets clobbered on the next
  `make openapi`. The struct tags are the source of truth.
- **Forgetting to add an error response.** A 4xx the client receives but isn't in the
  spec = silent contract drift. CI doesn't catch missing error responses; the validator
  agent does.
- **Inlining schemas instead of `$ref`'ing components.** The spec becomes unreadable and
  client generators produce ugly type names.
- **Versioning the wrong way for the project.** URL-path projects have `/v1/...` in the
  path; header-versioned projects have a single `/...` path with `X-API-Version` as a
  header parameter. Don't mix.
- **Skipping `make openapi-validate`.** A spec that doesn't lint silently breaks SDK
  generation downstream — even if it serves fine.

## After the change

- `make openapi-validate` clean.
- Spec diff reviewed in the PR.
- Integration test asserts response shape against the spec (runtime validator if Option
  C; build-time guarantee if Option A; reflector-guaranteed if Option B).
- ProblemDetails responses still `$ref` the shared component.
- The `/openapi.{json,yaml}` endpoints serve the updated spec when the server restarts.

## See also

- `.claude/rules/backend/openapi.md` — the contract (auto-loaded on API files).
- `docs/decisions/*-openapi-generation.md` — the per-project ADR locking the generator.
- `add-endpoint` skill — invokes this skill at step 7.
- `write-integration-tests` skill — the test that asserts spec/code parity.
