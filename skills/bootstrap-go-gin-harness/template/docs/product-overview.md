# {{ProductName}} — product overview

> **TEMPLATE — fill in.** This is the source of truth for product vision, domain, and
> the high-level technical decisions. It is loaded indirectly via
> `.claude/hooks/context/product-context.md` (a short version of this is injected at
> session start). Edit both when the product evolves.

## Goal — one sentence

TODO — what {{ProductName}} is, in one sentence.

## What it is NOT

TODO — bound the scope. The most useful product definitions say what something isn't.

## The moat

TODO — the durable advantage that compounds with usage. A moat is not a feature; it's
something that makes the product harder to replicate the longer it operates.

## Who it's for

| Persona | Role | Pain solved |
|---|---|---|
| TODO | TODO | TODO |

Buyer vs. user can differ — name both. Anchor on the buyer's economic decision.

## Differentiators (why we win)

1. TODO — vs. incumbent X
2. TODO — vs. open-source alternative Y
3. TODO — vs. building-it-yourself

## First-class invariants (non-negotiable)

- **Tenancy** — `tenant_id` everywhere; Tenant/Organization is the top-level isolation
  boundary; never cross tenant. *(Harness default — remove if single-tenant.)*
- TODO — any other invariant (data residency, write-once audit trail, financial precision,
  single-writer ordering, etc.).

## Core domain nouns

TODO — your entities. Examples (replace with your own):

- **Tenant / Organization** — the top-level account; everything is scoped under one.
- **Member / User** — belongs to a tenant; has roles.
- **Project** — a workspace; tenant-scoped; has documents.
- **Document** — content; project-scoped; has versions.

Map the domain explicitly; ambiguity here is the source of every later confusion.

## Stack (decided)

- **API**: Gin (HTTP/JSON; SSE for streaming)
- **DB**: PostgreSQL via **pgx** (`jackc/pgx/v5`) + **sqlc** (typed queries from SQL)
- **Migrations**: `pressly/goose/v3`
- **Logging**: `log/slog` (stdlib structured logging, JSON in prod)
- **Observability**: OpenTelemetry (traces + metrics + logs; OTLP exporter)
- **Testing**: stdlib `testing` + `testify` + `testcontainers-go` (integration)
- **Linting**: `golangci-lint` (~25 linters, warnings = errors)
- **Vuln scanning**: `govulncheck` (CI gate)
- **Hot reload (dev)**: `air`
- **LLM provider** (if applicable): TODO — Anthropic / OpenAI / Bedrock / Gemini …
- **Object storage** (if applicable): TODO — S3 / GCS / Azure Blob
- **Identity** (if applicable): TODO — OIDC provider name

## Roadmap

### Now (current quarter)

TODO

### Next

TODO

### Later (signal-only)

TODO

## How we work

- **Lead with the product vision, not the tech.** When planning or grilling an idea, the
  "why / who / moat" comes first; the stack is the substrate.
- **Decisions are the owner's.** When a decision is needed, present concrete options with
  a recommendation; don't pick silently.
- **Plan before non-trivial code.** `docs/exec-plans/<topic>.md` in the house format.
- **Build via `/run-impl-loop`** once a plan is approved.
- **Evidence over assertion.** Source-of-truth hierarchy:
  code > DB > telemetry > docs > AI output.
- **No new third-party module without explicit, per-module approval.**
- **No `git commit` / `push` / `amend` without per-action approval.**

## Open questions

| ID | Question | Owner | Recommendation | Blocking? |
|----|----------|-------|----------------|-----------|

## References

- Architecture: [backend-architecture.md](projectStandards/backend-architecture.md)
- Coding standards: [coding-standards.md](projectStandards/coding-standards.md)
- Testing standards: [testing-standards.md](projectStandards/testing-standards.md)
- Observability standards: [observability-standards.md](projectStandards/observability-standards.md)
- Security baseline: [security-standards.md](projectStandards/security-standards.md)
- Eval methodology: [eval-standards.md](projectStandards/eval-standards.md)
- Plan format: [implementation-plan-format.md](projectStandards/implementation-plan-format.md)
