# 0002. API versioning strategy — URL-path vs. header-based

* Status: **proposed** — owner must resolve before any routes are mounted
* Date: TBD (fill in when resolved)
* Deciders: TBD
* Related:
  * Rule: `.claude/rules/backend/api-design.md` (Versioning section)
  * Standard: `docs/projectStandards/backend-architecture.md`
  * Supersedes: n/a

> **STOP — do not mount routes until this ADR is resolved.** The agent (architect-backend,
> validator) will block PRs that add routes while this ADR's status is `proposed`. Pick an
> option below, fill in the Status / Date / Deciders / Decision sections, change status to
> `accepted`, then continue.

## Context

The product exposes an HTTP API. Over its lifetime it will need to evolve — new endpoints,
new fields, renamed fields, removed endpoints. Each of those is a versioning event in
some form. We need a single, consistent strategy so:

- Clients know how to request a specific contract version.
- The server knows how to route a request to the right handler.
- We can deprecate old versions without breaking clients.
- The OpenAPI spec (or equivalent contract document) has a stable structure.

The two mainstream strategies are URL-path versioning and header-based versioning.
Both are valid; the right choice depends on the product's client surface, tooling, and
deprecation cadence. **There is no general best answer; this is a per-project decision.**

## Decision

> Fill in ONE of the two options below. Delete the other. Move `Status:` to `accepted`.

---

### ☐ Option A — URL-path versioning (`/v1/projects`)

**We will version the API in the URL path.** Routes mount under versioned groups
(`r.Group("/v1")`). The version is part of every request URL.

**Implementation locks (binding once accepted):**
- `internal/api/router.go` is the only place version prefixes are chosen. Features
  receive a pre-grouped `*gin.RouterGroup` and do not write `/v1/` themselves.
- Health / readiness / metrics endpoints stay at the top level, unversioned.
- New major versions are mounted as sibling groups (`r.Group("/v2")`). Old versions stay
  live through a documented deprecation window.
- OpenAPI paths are `/v1/...`, `/v2/...`.
- Architect-backend agent rejects PRs that add unversioned routes outside the
  health-check allow-list.

---

### ☐ Option B — Header-based versioning (`X-API-Version` or `Accept` header)

**We will version the API via a request header.** URLs stay version-free; a middleware
reads the version from the header and the handler dispatches to the right code path.

**Implementation locks (binding once accepted):**
- `internal/api/middleware/api_version.go` reads the version header and puts the value
  in `context.Context` via a typed key.
- Header name: `X-API-Version` (simple) OR `Accept: application/vnd.{{ProjectName}}.vN+json`
  (RFC-aligned). Pick one and document.
- Default version when the header is absent: the **first stable** version, NOT "latest"
  — clients that don't set the header lock to the version that existed when they
  integrated.
- Handlers with multiple versions live as siblings: `create_project.go` (v1),
  `create_project_v2.go` (v2); dispatch happens inside the handler closure based on
  `APIVersionFrom(ctx)`.
- OpenAPI: one path per endpoint, with `X-API-Version` listed as a header parameter
  with enumerated values.
- Architect-backend agent rejects PRs that mount routes with `/v\d+/` in the URL.

---

## Consequences

### If Option A (URL-path) is chosen

- **Easier**: explicit in every request and log; trivial to curl-test (no header
  ceremony); browser-friendly; caches `Vary` correctly out of the box.
- **Easier**: deprecation is visible — `/v1/...` still up, `/v2/...` ships, `/v1/...`
  removed on schedule.
- **Easier**: OpenAPI tooling treats each version as a separate spec — clean SDK
  generation per version.
- **Harder**: URL surface doubles for every major version (until the old one sunsets).
- **Harder**: clients hard-coding `/v1/` URLs need code changes to upgrade — but this
  is true everywhere; URL versioning just makes it visible.
- **Cost**: minor router-config complexity; one extra `r.Group("/vN")` per live version.

### If Option B (header-based) is chosen

- **Easier**: stable URLs — mobile apps and partner integrations can hard-code URLs
  without rewriting on a major bump.
- **Easier**: a single conceptual endpoint per resource; OpenAPI URL keys stay clean.
- **Easier**: REST purists' preferred shape; aligns with content-negotiation semantics.
- **Harder**: hidden in the request — easy to forget the header in curl/tests;
  tooling support for header-based versioning is patchier (some clients, some SDK
  generators).
- **Harder**: HTTP caches need explicit `Vary: X-API-Version` (or `Vary: Accept`); a
  misconfigured CDN can serve v2 responses to v1 clients.
- **Harder**: a per-handler dispatch on version inside the closure is more complex than
  separate route trees.
- **Cost**: ~30 lines of middleware + a context key + a discipline for naming
  per-version handler files.

## Alternatives considered

| Option | Why not (one-line) |
|---|---|
| Query-string versioning (`/projects?api_version=1`) | Mixes data and version; URLs hash differently per version; cache-unfriendly. |
| No versioning at all | Works until the first breaking change; then breaks every client at once. |
| Subdomain versioning (`v1.api.example.com`) | Splits TLS/DNS surface; useful only for very-long-lived public APIs. |
| Date-based versioning (`2026-06-15`) | Stripe-style; powerful but complex to manage; overkill until the API has thousands of consumers. |
| Both URL major + header minor | Cute; doubles the cognitive surface; deferred unless the API has unusual evolution needs. |

## How to resolve this ADR

1. Discuss with the owner. Consider:
   - **Who are the clients?** Long-lived mobile apps / partner SDKs → header tends to
     win (stable URLs). Internal browser clients / curl-heavy debugging → URL tends to
     win (explicit).
   - **Cache infrastructure?** If you don't control the CDN, URL is safer.
   - **OpenAPI tooling?** If SDK generation is critical, URL is the path of least
     resistance.
   - **Deprecation cadence?** Frequent breaking changes → URL gives visible deprecation;
     stable contract with rare changes → header keeps URLs clean.
2. Pick ONE option above. Delete the other.
3. Update `Status:` to `accepted`, fill in `Date:` and `Deciders:`.
4. (If A) Wire `internal/api/router.go` with the version group. (If B) Wire
   `internal/api/middleware/api_version.go` + the context key.
5. Update the OpenAPI spec template to reflect the chosen shape.
6. From this point, `/exec-plan` and `/add-endpoint` honor the choice automatically.
