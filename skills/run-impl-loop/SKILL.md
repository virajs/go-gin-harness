---
name: run-impl-loop
description: Drive plan → build → review loop end-to-end. Delegates mechanical stages to the impl-build and architect-review workflows; the main agent keeps the judgment steps (analyze, triage, decide). Use when an approved plan needs to be built.
argument-hint: <plan path> (e.g. docs/exec-plans/add-projects.md)
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill, Agent, Workflow
---

# Run the implementation loop

The operating model for building an approved plan. **You stay in the loop** as the main
agent — making judgment calls — and **delegate the mechanical stages** to workflows.

## Inputs

`<plan path>` — the approved plan, in house format
(`docs/projectStandards/implementation-plan-format.md`).

## Stages (you drive these)

### 1. Analyze the plan

Read the plan in full. Identify:
- The scope (which files/symbols, which packages, which tests)
- The locked decisions (D1, D2, ...) — the constraints you must honor
- The open questions (if any) — STOP if any are blocking
- The exact test list (the testing-expert will implement these verbatim)

If something is unclear / contradicts the actual code / depends on an unanswered open
question — **STOP** and ask the owner before proceeding.

### 2. Delegate `impl-build` workflow

```javascript
Workflow({
  name: "impl-build",
  args: { planPath: "<plan path>", focus: "the entire plan", maxFixes: 3 }
})
```

The workflow runs implement → validate → fix-loop → test. It returns:
- `implemented` — what files changed, what deviations were reported
- `validated` — pass/fail of the validator (true means clean build + rule adherence)
- `tests` — exact pass/fail/skip counts
- `blocked: true` if a material divergence was hit; with `blocker` + `recommendedOptions`

**If blocked**: stop, present the blocker + options to the owner. Don't improvise.

### 3. Triage deviations

Read every deviation the implementer reported. For each:
- **Minor** — accept, note in the summary.
- **Notable** — confirm the adaptation was correct; if wrong, queue a fix in the next
  `impl-build` call.
- **Blocking** — should have stopped the workflow. If it ran anyway, that's a bug in
  the workflow.

### 4. Delegate `architect-review` workflow

```javascript
Workflow({
  name: "architect-review",
  args: {
    scope: ["backend", "security"],
    changedPaths: "the implementation diff",
    planPath: "<plan path>"
  }
})
```

The workflow runs parallel reviewers (backend architect + security auditor) + verifies
each finding adversarially. Returns `real` (verified findings to fix) and `noise`
(dismissed).

### 5. Triage real findings

For each real finding:
- **Critical / high** → must fix.
- **Medium** → fix unless explicitly out of scope (note in summary).
- **Low** → judgment call; default to fix if cheap.

### 6. Fix loop (if findings)

```javascript
Workflow({
  name: "impl-build",
  args: {
    planPath: "<plan path>",
    focus: "fix these findings:\n" + JSON.stringify(realFindings),
    maxFixes: 2,
    skipTests: false
  }
})
```

Re-runs implement → validate → test on the fix-list. Iterate until clean.

### 7. Summarize and surface decisions worth recording

Final summary to the owner:
- Plan: `<plan path>`
- Files changed: N
- Build: clean / not clean
- Tests: passed N / failed M / skipped K / total T (race detector: clean)
- Coverage: domain X% (gate: 80%) · app Y% · other Z%
- govulncheck: clean / N findings
- Deviations: N reported (M minor, K notable, L blocking — should be 0 blocking)
- Architect review: R real findings (X critical, Y high, Z medium) — all fixed / N pending
- Open questions surfaced: N (if any)

**Then scan for decisions worth preserving as ADRs.** Many loops have material
decisions buried in the deviation list or the review triage; without an ADR they
evaporate after the session.

| Item | Worth an ADR? |
|---|---|
| Notable deviation accepted by owner that affects future work | **Yes** — suggest `/record-adr "<one-line summary>"` |
| Deferred architect-review finding (not fixed this loop) | **Yes** — suggest `/record-adr "defer <finding> until <trigger>"` |
| Accepted-as-risk architect finding | **Yes** — suggest `/record-adr "accept <risk> — <rationale>"` |
| Pattern-level standard you ended up rewriting in `.claude/rules/` | **Yes** — suggest `/record-adr "supersede <pattern>"` |
| Minor mechanical adaptation (rename, signature drift) | No — plan's deviation list + git suffices |
| Issue fully fixed in this loop with no rule change | No — git commit + plan status banner suffices |

Surface a one-line ADR suggestion per qualifying item so the owner can run
`/record-adr` per item. **Never write ADRs autonomously** — the owner approves each
title and content. When an ADR is written, cross-link by adding a row to the plan's
Locked Decisions table or status banner: `D-N | <decision> | ADR-NNNN`.

## What you (main agent) DO NOT delegate

- The plan analysis. You read the plan and judge ambiguity.
- The triage of deviations. You decide whether each is acceptable.
- The decision to fix vs. defer a finding.
- The summary to the owner.
- The decision to commit / push (always per-action, with owner approval — see CLAUDE.md).

## What the workflows OWN

- The `impl-build` workflow drives implement → validate → fix → test mechanically.
- The `architect-review` workflow runs reviewers + verifies findings.
- These are **deterministic orchestration**; you call them and read the result.

## Failure modes

- **Validator never passes**: 3 fix attempts exhausted. Either the plan is wrong (stop and
  surface) or the implementer is confused (consider splitting the focus into smaller
  chunks and re-running).
- **Tests fail after implementation**: the test surfaced a real defect. The testing-expert
  reports it; you decide whether to amend the plan or fix the implementation.
- **Architect review surfaces a critical finding**: STOP. This isn't a "fix later" item;
  it's a "stop and discuss the design" item.
- **govulncheck finds a CVE**: the new dep (if any) or stdlib version may be vulnerable.
  Surface to the owner; the decision to upgrade / replace / accept-risk is theirs.

## Common mistakes (don't)

- Skipping the architect-review because "tests pass". Tests passing means the code does
  what the tests say; review confirms it does what the rules say.
- Calling `impl-build` with `skipTests: true` for the main build. Skipping tests is for
  small fix passes only (and even then, only if no behavior changed).
- Auto-fixing every architect finding without owner triage. Some findings are
  out-of-scope and should be filed as follow-ups, not fixed silently.
- Committing without the owner's explicit per-action approval. The `protect-commands`
  hook asks; respect it.

## Example invocation

```bash
# In a Claude Code session:
/run-impl-loop docs/exec-plans/add-projects.md
```

The main agent reads this skill, calls the workflows, and reports the summary.
