# LLM evals

Documentation + methodology + historical runs for LLM evals. Skip this folder if the
product doesn't use LLMs.

## Documents

- [eval-standards.md](../projectStandards/eval-standards.md) — methodology (why we
  eval, how the suites work, scorecard schema, promotion rules).
- `<suite>/methodology.md` — per-suite write-up of dataset design + grader rationale +
  pass thresholds.

## Suites (each lives in `evals/<suite>/` at the repo root, not here)

| Suite | What it tests | Pass threshold | Dataset size |
|-------|---------------|----------------|--------------|
| TODO  | TODO          | TODO           | TODO         |

This table is filled in as suites are added.

## Run history

Per-suite scorecards live at `evals/<suite>/runs/`. Promoted baselines live at
`evals/<suite>/baseline.json`. Headlines from notable runs may be summarized here over
time (model upgrades, scorecard regressions, baseline promotions).

## How to read a scorecard

| Field | Meaning |
|---|---|
| `aggregateScore` | mean / median per the suite config |
| `passing` / `failing` / `errored` | counts |
| `scoreDelta` | aggregate vs. baseline |
| `flippedCases` | pass→fail and fail→pass cases vs. baseline (with reasons) |
| `slowestCases` | top 5 by latency — investigation hooks |
| `totalCost` | USD spent on this run |
| `recommendation` | `promote-baseline` / `regression-fix-required` / `investigate` / `no-action` |

## Promoting a baseline

```bash
make evals-baseline   # interactive prompt, owner-driven
```

Never auto-promote. Promotion is the owner's decision.

## See also

- `.claude/skills/run-evals/SKILL.md` — operational procedure.
- `.claude/workflows/eval-run.js` — the orchestration workflow.
- `.claude/agents/eval-runner.md` — the agent that drives a run.
