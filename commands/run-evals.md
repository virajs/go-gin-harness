---
description: Run an LLM eval suite against the current build — fan a dataset through the feature, grade in parallel, compare to baseline, recommend promote / regress. Skip if the product doesn't use LLMs.
allowed-tools: Workflow, Skill, Bash, Read, Write
argument-hint: <suite> (e.g. answer-quality)
---

Run the `eval-run` workflow for suite **$ARGUMENTS**.

```javascript
Workflow({
  name: "eval-run",
  args: { suite: "$ARGUMENTS", comparison: "baseline" }
})
```

Pre-check (the workflow does this too, but surface fast if obvious):
- `evals/$ARGUMENTS/` exists with `dataset.jsonl`, `runner.go`, `grader.go`.
- `cmd/evals/` builds.

After the run, surface:
- Scorecard (passing / failing / errored / aggregate / baseline / delta)
- Flipped cases (pass→fail in particular)
- Total cost + duration
- Recommendation: `promote-baseline` / `regression-fix-required` / `investigate` /
  `no-action`

Never auto-promote the baseline. The owner runs `make evals-baseline` when ready.
