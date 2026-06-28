# 0003. OpenAPI 3.0 — generation approach (code-first via swaggest/rest)

* Status: **accepted**
* Date: 2026-06-27
* Deciders: harness defaults — supersede with your own ADR if your project needs a
  different approach
* Related:
  * Rule: `.claude/rules/backend/openapi.md`
  * ADR: `0002-api-versioning.md` (affects what paths look like in the spec)
  * Makefile targets: `make openapi`, `make openapi-validate`

> **Note:** this ADR ships **pre-accepted** in the harness template as the recommended
> default. If your project warrants a different approach (e.g. spec-first because you
> publish an SDK, or manual because the API surface is tiny), supersede this ADR with
> a new one that sets `Status: superseded by ADR-NNNN` here and explains the chosen
> alternative. **Never delete this file** — supersession chains are part of the record.

## Context

The OpenAPI rule (`openapi.md`) makes OpenAPI 3.0 documentation mandatory and requires
the spec to be served at `GET /openapi.json` / `GET /openapi.yaml`. The rule is enforced
at review time and via `make openapi-validate` in CI.

The rule deliberately does NOT pick *how* the spec is produced. Three valid approaches
exist (spec-first via oapi-codegen; code-first via huma or swaggest/rest; manual with
validation-only). The harness default is **code-first with swaggest/rest** because:

- The harness uses Gin with REPR-style handlers in
  `internal/api/features/<feature>/<usecase>.go`. That structure is established by the
  rules.
- A spec-first approach (oapi-codegen) would generate `ServerInterface`s that handlers
  implement, adding a layer between the REPR handlers and the router.
- huma (the other strong code-first option) is a full framework that replaces the Gin
  handler signature; adopting it would restructure every handler.
- swaggest/rest is **non-invasive**: it wraps Gin handlers, derives the schema from the
  request/response struct tags + a small per-route registration, and emits OpenAPI 3.0+
  as a side-effect of routing. The REPR shape stays intact.

## Decision

**We will use `github.com/swaggest/rest` for code-first OpenAPI 3.0 generation.**

- Each handler's request and response types carry `json:"..."` tags (already true per
  the api-design rule) plus `description:"..."` / `example:"..."` tags for OpenAPI
  metadata.
- Each `register.go` per feature mounts the handler via swaggest/rest's wrapper, which
  registers it with both Gin and the OpenAPI reflector in a single call. The reflector
  walks the Go types via reflection at startup and produces the spec.
- A small `cmd/openapi-gen/main.go` constructs the full router (without serving) and
  writes the reflected spec to `docs/api/openapi.yaml` + `docs/api/openapi.json`. This
  is what `make openapi` invokes.
- The running API embeds the generated `openapi.yaml` and `openapi.json` via `//go:embed`
  and serves them at `GET /openapi.yaml` and `GET /openapi.json` (the rule's required
  endpoints).
- `make openapi-validate` lints the generated spec with `redocly lint`. CI runs it; a
  spec that doesn't lint fails the build.

### Implementation locks (binding)

- **Reflection-driven**: request/response struct tags are the source of truth for the
  spec. **NEVER hand-edit `docs/api/openapi.yaml`** — it's regenerated on every
  `make openapi` and hand-edits get clobbered. Treat it like sqlc's `_sqlcgen/` output.
- **Per-route registration**: every `register.go` mounts handlers via swaggest/rest's
  `web.Service` (or the equivalent Gin adapter), not directly via
  `gin.RouterGroup.POST`. Direct Gin route registration bypasses the reflector →
  undocumented endpoint → CI failure (the integration test asserts spec/route parity).
- **Component schemas auto-generated**: a request type named `CreateProjectRequest`
  becomes `#/components/schemas/CreateProjectRequest`. Use distinct type names per
  endpoint to keep the schema set clean.
- **Errors**: a shared `internal/shared/result/ProblemDetails` struct is registered
  once and `$ref`'d by every non-2xx response. Each error response declares
  `400/401/403/404/409/500` with `description` set to the meaningful name (e.g.
  "validation failure").
- **Generator binary**: `cmd/openapi-gen/main.go` builds the same router as
  `cmd/api/main.go` (share an `internal/api.NewRouter` constructor), with stub
  dependencies; writes the spec; exits. Never serves traffic.
- **Embed at build**: `cmd/api/main.go` consumes the generated files via
  `//go:embed docs/api/openapi.yaml docs/api/openapi.json`. CI runs `make openapi`
  BEFORE `make build` so the embed source exists.

### Why not the alternatives

| Considered | Why rejected as the default |
|---|---|
| **Option A — Spec-first (oapi-codegen)** | Adds a `ServerInterface` layer between the REPR handler and the router; restructures the prescribed `internal/api/features/<feature>/<usecase>.go` shape. The contract-first benefit is real but the migration cost isn't worth it for a generic harness default. Supersede this ADR with Option A if your project publishes SDKs to external consumers, has a contract-first culture, or needs complex `oneOf` schemas reflection can't infer. |
| **Option B alt — huma** | A full framework; replaces Gin handler signatures with huma's `huma.Register` API. Strong tool but the migration would touch every handler and reshape the REPR pattern. swaggest/rest preserves Gin and the existing shape. Supersede with huma if you want stronger ergonomics for things like middleware and context propagation built into the framework. |
| **Option C — Manual** | Acceptable for tiny APIs; supersede this ADR if your project has < 10 endpoints and the team prefers minimum tooling. Discipline-only doesn't scale for larger surfaces; drift bites within months. |

## Consequences

- **Easier**: spec drift is impossible by construction — the Go types are reflected;
  there's no second source of truth to keep aligned.
- **Easier**: Go-native workflow; no YAML editing for routine endpoints; struct tags +
  `register.go` are the entire surface.
- **Easier**: existing REPR handlers stay as-is; the swaggest/rest wrapper is a thin
  layer at the route registration site.
- **Easier**: `docs/api/openapi.yaml` is generated → reviewers see the schema diff per
  PR alongside the code; catches contract changes nobody intended.
- **Harder**: a hand-edit to `docs/api/openapi.yaml` survives until the next
  `make openapi`, then vanishes. Treat the file as a generated artifact; never
  hand-edit. Documented in the file header and in the openapi rule.
- **Harder**: complex shapes the reflector can't infer (e.g. `oneOf` based on a
  discriminator field) need swaggest/rest's manual schema annotations, which are more
  verbose than YAML. If hand-tuning becomes common (more than ~3 endpoints needing
  manual schema annotations), supersede this ADR and move to Option A.
- **Cost**: one new module (`github.com/swaggest/rest`) — owner-approved per the
  harness's per-module rule. Pulls in `github.com/swaggest/openapi-go` and
  `github.com/swaggest/jsonschema-go` transitively; all maintained by the same author
  with reasonable activity.
- **Cost**: one new binary (`cmd/openapi-gen/`) that builds the spec; ~50 lines.
- **Cost**: CI ordering matters — `make openapi` runs before `make build` so the embed
  source exists. Documented in the Makefile and CI config.

## Alternatives considered (full record)

| Option | Why not the default |
|---|---|
| **Spec-first (oapi-codegen)** | Adds an interface layer; restructures handlers; migration cost not justified for a generic default |
| **Code-first (huma)** | Full framework; replaces Gin handler signatures; restructures every handler |
| **Code-first (swag — original)** | Native OpenAPI 2.0; 3.x support is recent and less battle-tested; comment-based annotations are noisier than struct tags |
| **Manual + validation** | Works for tiny surfaces; drift inevitability past ~10 endpoints |
| **Postman / Insomnia collections** | Documentation, not contract; drift fast; not a standard |
| **ProtoBuf + gRPC-gateway → OpenAPI** | Reasonable if gRPC is the canonical contract; out of scope for an HTTP/JSON-first harness |

## How to supersede this ADR

If your project warrants a different generation approach:

1. Author a new ADR (e.g. `0NNN-openapi-spec-first.md`) with `Status: accepted` that
   explains the chosen alternative.
2. Edit this ADR's header: `Status: superseded by ADR-0NNN`. Keep the rest of the file
   intact — the supersession chain is part of the record.
3. Update `.claude/rules/backend/openapi.md` to point at the new ADR.
4. Update the Makefile's `openapi` / `openapi-validate` targets per the new approach.
5. Update `cmd/openapi-gen/` (or replace with the new tool's equivalent).

The harness honors supersession via the agent layer — once the new ADR is `accepted`,
the rule's auto-load tells every agent to follow the new approach.
