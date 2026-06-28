# docs/decisions/ — Architecture Decision Records (ADRs)

Append-only record of architecturally-significant decisions that don't fit inside an
exec-plan's Locked Decisions table. See [`0001-record-adrs.md`](0001-record-adrs.md) for
the meta-decision behind this convention.

## Layout

```
docs/decisions/
├─ README.md                       (this file)
├─ 0000-template.md                template; copy when creating a new ADR
├─ 0001-record-adrs.md             meta-ADR: why we have this folder
├─ 0002-<slug>.md
├─ 0003-<slug>.md
└─ ...
```

## Numbering

- Zero-padded 4-digit sequence: `0001`, `0002`, ... `9999`.
- Numbers never repeat; superseded ADRs keep their number and gain a `Status: superseded
  by ADR-NNNN` header.
- `0000-template.md` is fixed; never renumbered.

## Authoring

```
/record-adr "<short imperative title>"
```

The `record-adr` skill walks you through:
1. Finding the next number.
2. Copying the template.
3. Filling in Context / Decision / Consequences / Alternatives.
4. Cross-linking from the related plan or PR.

See `.claude/skills/record-adr/SKILL.md` (or the plugin's installed copy) for the full
procedure and house style.

## When to write an ADR (quick reference)

Write one for:
- Cross-cutting / non-plan decisions ("use sqlc not GORM", "defer rate-limit on search")
- Mid-flight deviations with lasting effect (accepted by the owner during `/run-impl-loop`)
- Architect-review findings that are deferred or accepted-as-risk
- Pattern-level standard changes (rule rewrites, supersession of an earlier approach)
- "We considered X and rejected it" worth preserving so it isn't re-litigated

Don't write one for:
- Decisions already in a plan's Locked Decisions table — those are recorded there.
- Trivial micro-choices — commit messages suffice.
- Bug fixes whose rationale fits in a commit message.

## House style (restated)

- **Short** — ≤ 1 page printed. Long ADRs are smells.
- **Declarative** — "We will X." An accepted ADR is a decision, not a proposal.
- **Honest about costs** — list the bad consequences too.
- **Concrete alternatives** — name at least two; cite real reasons for rejecting each.
- **Cite code** — `internal/.../file.go:42` beats "the X layer".
- **Append-only** — never delete an ADR; supersede with a new one.

## Status values

| Status | Meaning |
|---|---|
| `proposed` | Draft; not yet approved |
| `accepted` | Active; team follows this |
| `deprecated` | No longer followed but not replaced (rare) |
| `superseded by ADR-NNNN` | Replaced by a newer ADR (linked) |

## See also

- `docs/projectStandards/implementation-plan-format.md` — for in-plan decisions
- `docs/projectStandards/backend-architecture.md` — for pattern-level decisions ratified
  into the standards
- `.claude/rules/` — for enforceable distillations of standards
- The `record-adr` skill (`/record-adr "<title>"`) — for the authoring procedure
