# {{ProductName}} — product context

**{{ProductName}} is TODO — one-sentence what-it-is.**
TODO — one sentence on what it is *not*.

## The moat — TODO

TODO — the durable advantage that compounds with usage.

## Who it's for

TODO — buyer / user / segment.

## Differentiators (why we win)

1. TODO
2. TODO
3. TODO

## First-class invariants (non-negotiable)

- **Tenancy** — `tenant_id` everywhere; Tenant/Organization is the top-level isolation boundary;
  never cross tenant. *(Harness default — remove if this product is single-tenant.)*
- TODO — any other invariant (e.g. data residency, single-writer ordering, financial audit log).

## Core domain nouns

TODO — your entities (harness examples: Project · Document · Member).

## Stack (decided)

- **HTTP framework:** Gin
- **DB:** PostgreSQL via **pgx** + **sqlc** (typed queries from SQL)
- **Migrations:** goose
- **Logging:** `log/slog` (stdlib structured logging)
- **Observability:** OpenTelemetry (OTLP exporter)
- **Tests:** stdlib `testing` + testify + testcontainers-go (integration)
- **Hot reload (dev):** air
- TODO — identity / auth provider, object storage, mail, LLM provider (if any).

## How we work

Lead with the **product vision, not the tech** — the "why / who / moat" comes first; the stack
is the substrate. Decisions are the owner's. Plan first for non-trivial changes
(`docs/exec-plans/<topic>.md`), build via `/run-impl-loop`, verify with `make ci`.
