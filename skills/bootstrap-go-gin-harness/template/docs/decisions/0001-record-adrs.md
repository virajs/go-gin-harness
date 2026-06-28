# 0001. Record architecturally-significant decisions as ADRs

* Status: accepted
* Date: 2026-06-25
* Deciders: harness defaults — supersede with your own ADR if your team doesn't want this
* Related:
  * Plan: n/a (decision predates any plan)
  * Standard: `docs/projectStandards/implementation-plan-format.md`

## Context

Exec plans (`docs/exec-plans/<topic>.md`) record forward-looking decisions inside their
"Locked decisions" table — but only the decisions pinned **at planning time**, scoped to
that plan. The harness's day-to-day operation produces other decisions:

- **Mid-flight deviations** during `/run-impl-loop` — the implementer adapts the plan
  to reality (`implementer` agent's deviations report) and the owner accepts. The
  workflow surfaces them once; nothing persists them.
- **Architect-review triage** — the `architect-review` workflow returns findings;
  the owner fixes some, defers some, accepts-risk others. The triage decision is
  ephemeral.
- **Cross-cutting / non-plan choices** — "we'll defer rate-limiting on the search
  endpoint", "we tried algorithm X and rejected it", "we accept the GDPR risk on
  field Y until Q4". These don't fit inside any single plan.
- **Pattern-level shifts** — when a rule in `.claude/rules/` is rewritten, the rationale
  for the change is visible in `git log` but not in a stable, linkable location.

Without a structured place to record these, "why did we do it this way?" answers must
be reconstructed from `git log --grep`, Slack history, and tribal memory.

## Decision

**We will record architecturally-significant non-plan decisions as Architecture Decision
Records (ADRs) under `docs/decisions/`.** Each ADR is one Markdown file named
`NNNN-<kebab-slug>.md`, append-only, following the template in `0000-template.md`.

Trigger conditions, scope, and procedure are codified in the `record-adr` skill (invoked
via `/record-adr "<title>"`).

## Consequences

- **Easier**: 6-months-later "why?" questions have a citable answer (`ADR-0007`) instead
  of requiring git archaeology.
- **Easier**: deferred-finding rationale is preserved through team rotations.
- **Easier**: supersession chains (`Status: superseded by ADR-NNNN`) make decision
  evolution legible.
- **Easier**: PRs can cite the ADR they implement; reviewers see the rationale alongside
  the code.
- **Harder**: requires discipline — when a decision is approved, someone must invoke
  `/record-adr`. The skill makes it cheap (~2 minutes per ADR) but not free.
- **Harder**: distinguishing "this needs an ADR" from "a commit message is enough"
  requires judgment. The skill's "When to record" section codifies it; review when
  unsure.
- **Cost**: one extra Markdown file per significant decision; small in the small case,
  meaningful only after dozens accumulate.

## Alternatives considered

| Option | Why not |
|---|---|
| Decisions only in exec plans + git commits | Loses anything not bound to a single plan; commits are searchable but not linkable from prose. |
| One single `DECISIONS.md` append-only log | Grows unbounded; harder to link individual decisions; merge conflicts on the one file. |
| GitHub Discussions / Confluence / Notion | Lives outside the repo — drifts from code; not visible to agents during reviews. |
| No structured record (rely on tribal knowledge) | Catastrophic in any team > 2 people or any project > 6 months old. |

## Migration / opt-out

If your team doesn't want ADRs, supersede this ADR with your own (`Status: superseded by
ADR-NNNN`). Don't delete this file — the supersession chain is part of the record.
