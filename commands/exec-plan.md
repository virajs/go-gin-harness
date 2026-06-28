---
description: Draft an implementation plan in the house format — locked decisions, ordered checklist, code samples with absolute paths, exact named-test list, OPEN QUESTIONS. The plan is a build-from-this contract, not a sketch.
allowed-tools: Skill, Workflow, Read, Glob, Grep, Write, Bash
argument-hint: <topic> (e.g. "add projects feature")
---

The user wants a build-from-this implementation plan for: **$ARGUMENTS**.

Two ways to invoke:

1. **Lightweight (single-agent)** — invoke the `exec-plan` skill yourself. Good for
   small, well-understood changes (≤ 5 file changes, no architectural decision).

2. **Heavyweight (workflow)** — delegate to the `exec-plan-build` workflow. This fans
   out parallel reconnaissance, drafts via the `exec-planner` agent, and adversarially
   reviews. Good for non-trivial plans where missing recon = missing locked decisions.

**Default for any "add a feature" / "refactor X" / "introduce Y" request: the workflow.**
Default for "rename Z" / "fix Q" type asks: skill alone is fine.

For the workflow:

```javascript
Workflow({
  name: "exec-plan-build",
  args: {
    topic: "$ARGUMENTS",
    request: "$ARGUMENTS",
    scope: ["domain", "app", "api", "persistence", "tests"]
  }
})
```

Output the plan path and a one-paragraph summary: goal, locked-decision count, open-question
count, estimated phase / file-change count. Wait for owner approval before suggesting
`/run-impl-loop`.
