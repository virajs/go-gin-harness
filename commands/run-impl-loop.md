---
description: Build an approved implementation plan end-to-end — implement → validate → fix loop → test → architect-review → triage → fix → summary. Delegates mechanical stages to impl-build and architect-review workflows; main agent keeps the judgment steps.
allowed-tools: Skill, Workflow, Read, Glob, Grep, Edit, Write, Bash, Agent
argument-hint: <plan path> (e.g. docs/exec-plans/add-projects.md)
---

The user wants to build the plan at: **$ARGUMENTS**.

Invoke the `run-impl-loop` skill to drive the loop. The skill specifies the exact stages:

1. **Analyze the plan** (you, main agent) — read it in full; identify scope + locked
   decisions + open questions. STOP if a blocking open question is unanswered.

2. **Delegate `impl-build` workflow** with `{ planPath: "$ARGUMENTS", focus: "the entire
   plan", maxFixes: 3 }`. The workflow runs implement → validate → fix-loop → test.

3. **Triage deviations** that the implementer reported.

4. **Delegate `architect-review` workflow** with
   `{ scope: ["backend", "security"], changedPaths: "the implementation diff", planPath:
   "$ARGUMENTS" }`. Returns real findings (verified) and noise (dismissed).

5. **Triage real findings** — must-fix vs. defer vs. out-of-scope.

6. **Fix loop** for the must-fix items: another `impl-build` call scoped to the
   fix-list.

7. **Summarize** — files changed, build status, exact test counts, coverage delta,
   govulncheck status, deviations, findings, open questions.

You stay in the loop for the judgment steps; the workflows handle the mechanical
implement / validate / test / review stages.

If the impl-build workflow returns `blocked: true`, STOP and surface the blocker +
recommended options. Do not improvise.

Do not commit or push without per-action owner approval.
