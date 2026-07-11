---
name: record-adr
description: Record an Architecture Decision Record (ADR) under docs/decisions/. Use when an architectural / cross-cutting / mid-flight decision is approved that doesn't fit inside an exec-plan's Locked Decisions table — e.g. a deferred architect-review finding, a tech-stack choice, an accepted deviation that affects future work, a "we tried X and rejected it" rationale worth preserving.
argument-hint: '"<short imperative title>" (e.g. "use sqlc over GORM")'
allowed-tools: Read, Glob, Grep, Edit, Write, Bash
---

# Record an Architecture Decision Record (ADR)

ADRs capture the *why* behind decisions that aren't already pinned in an exec-plan. They
are short (≤ 1 page typically), append-only, and live in `docs/decisions/`.

## When to record an ADR

Write one when:

- **A non-plan decision is approved** — chosen library, retired pattern, accepted-risk
  finding, tenancy / residency / SLA call.
- **A mid-flight deviation has lasting effect** — implementer chose pattern Y over plan's
  pattern X, and the choice will influence future work.
- **An architect-review finding is deferred or accepted-as-risk** — record why it's not
  fixed now and what would trigger fixing later.
- **A pattern-level standard changes** — a rule in `.claude/rules/` or a section in
  `docs/projectStandards/` was rewritten. The ADR explains the shift.
- **An "we considered X and rejected it"** is worth preserving so future devs don't
  re-litigate it.

Do **not** write an ADR for:

- **Decisions already inside a plan's Locked Decisions table** — those are recorded
  there. Don't duplicate.
- **Trivial micro-choices** — variable names, file layout within an established convention,
  formatting. Git commits cover those.
- **Bug fixes whose rationale fits in a commit message** — use the commit; don't inflate
  to an ADR.

## Procedure

### 1. Find the next sequence number

```bash
cd docs/decisions
last=$(ls -1 [0-9]*.md 2>/dev/null | sed -n 's/^\([0-9]\+\).*/\1/p' | sort -n | tail -1)
next=$(printf "%04d" $((10#${last:-0} + 1)))
echo "Next ADR number: $next"
```

Numbers are zero-padded to 4 digits (`0001`, `0002`, …). `0000-template.md` is a fixed
template — never renumbered.

### 2. Choose a kebab-case slug

Short, imperative, descriptive. Examples:
- `0007-use-sqlc-over-gorm.md`
- `0008-defer-rate-limit-on-search.md`
- `0009-tenant-id-from-jwt-only.md`
- `0010-supersede-result-pattern-with-stdlib-errors.md`

### 3. Create the file from the template

```bash
cp docs/decisions/0000-template.md docs/decisions/$next-<slug>.md
```

Open the new file and fill in every section. The template is intentionally short — keep
yours short too. A long ADR is a smell; either split it or trim.

### 4. Fill in the sections

```markdown
# NNNN. <Short imperative title — same as filename, sentence case>

* Status: accepted             ← proposed | accepted | deprecated | superseded by ADR-XXXX
* Date: YYYY-MM-DD             ← today's date in UTC
* Deciders: <names>            ← who approved; for a solo project, the owner
* Related:
  * Plan: docs/exec-plans/<topic>.md       ← if this decision came out of a plan
  * Supersedes: ADR-NNNN                    ← if replacing an earlier ADR
  * PRs: #142, #156                         ← if related git history exists
  * Discussion: <link or thread reference>  ← optional

## Context

What's the situation? What forces are at play? What problem is this decision solving?
Two to four sentences. Cite `file:line` if grounded in real code.

## Decision

What we chose. One declarative sentence first ("We will use sqlc instead of GORM for
all persistence queries."), then a supporting paragraph if needed.

## Consequences

What this makes easier and harder. List both — every decision has costs.

- **Easier**: compile-time-typed queries; no surprise runtime SQL.
- **Easier**: pgx + sqlc patterns documented in `.claude/skills/sqlc-patterns/`.
- **Harder**: dynamic-shape queries need raw pgx escape hatch.
- **Harder**: contributors unfamiliar with sqlc face a learning curve.
- **Cost**: sqlc must run before tests can compile (build step added to Makefile).

## Alternatives considered

| Option | Why not |
|---|---|
| GORM   | Runtime SQL generation; weaker typing; surprising behaviour under load |
| ent    | Heavier; codegen output is verbose; requires schema migration in Go |
| Raw pgx + hand-rolled scanners | Too much boilerplate; sqlc generates it cleanly |
```

### 5. Cross-link

If this ADR relates to an exec plan, add a row to the plan's Locked Decisions table or
status banner:

```markdown
| ID | Decision | Reference |
|----|----------|-----------|
| D5 | Persistence layer uses sqlc | ADR-0007 |
```

If this ADR supersedes another, edit the older ADR's `Status:` to
`superseded by ADR-NNNN`.

### 6. Commit alongside the change

Include the ADR in the same commit/PR as the code change it records. The git history then
shows: code + the decision rationale arriving together.

## House style

- **Short.** ≤ 1 page printed. If you're writing 3 pages, split into multiple ADRs.
- **Declarative.** "We will X" — not "we might X" or "X seems good". An accepted ADR is
  a decision, not a proposal.
- **Honest about costs.** Every decision has consequences; list the bad ones too.
- **Concrete alternatives.** "We considered X, Y, Z — chose this because A, B, C." If you
  can't name two real alternatives, the decision may not need an ADR (or may not be a
  real decision yet).
- **Cite code where it grounds the decision.** `internal/infra/persistence/projects/
  repository.go:42` beats "the repo layer".

## Status transitions

| From       | To               | When |
|------------|------------------|------|
| proposed   | accepted         | Owner approves |
| accepted   | deprecated       | We no longer follow it but haven't replaced it |
| accepted   | superseded by NN | A newer ADR replaces this one (link it) |
| (any)      | deprecated       | The decision no longer applies; don't delete the file — mark and keep |

**Never delete an ADR.** They are append-only history; superseded ADRs stay readable.

## Output

Print the new ADR path + a one-paragraph summary of the decision. If a related plan
exists, surface the cross-link suggestion.

## Common mistakes (don't)

- Writing an ADR for a decision already in a plan's Locked Decisions table.
- Writing an ADR with vague Context ("we need persistence") — be specific about the
  constraints.
- Omitting Alternatives — without them, the ADR can't answer "why not X?" six months later.
- Updating an existing ADR's content rather than superseding. Edits are fine for
  typos / format; substantive content changes require a new ADR that supersedes.
- Inflating commit-message-sized decisions ("renamed a function") into ADRs.
