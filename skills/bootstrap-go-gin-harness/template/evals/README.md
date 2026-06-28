# evals/

LLM evals at runtime. Each subdirectory is one suite. **Skip / delete this folder if the
product doesn't use LLMs.**

## Layout

```
evals/
├─ README.md                         (this file)
├─ <suite>/
│  ├─ dataset.jsonl                  one case per line: {id, input, expected}
│  ├─ runner.go                      Run(ctx, deps, raw) → output
│  ├─ grader.go                      Grade(case, output) → Score
│  ├─ methodology.md                 dataset design + grader rationale + pass threshold
│  ├─ baseline.json                  last-promoted scorecard
│  └─ runs/
│     ├─ <run-id>.json               machine-readable scorecard
│     └─ <run-id>.md                 human-readable summary
└─ ...
```

## Operational pointers

- **Run a suite**: `make evals` (all) or `go run ./cmd/evals -suite <suite>` (one).
- **Promote a baseline**: `make evals-baseline` (interactive; owner decides).
- **Authoring procedure**: `.claude/skills/run-evals/SKILL.md`.
- **Methodology**: `docs/projectStandards/eval-standards.md`.
- **Run history**: `docs/evals/README.md`.

## Hard rules (restated)

- **Synthetic / sanitized data only.** No customer data in `dataset.jsonl`.
- **Real model calls** — never mock the LLM.
- **Determinism where possible** — `Temperature: 0`.
- **Judge ≠ candidate** — LLM-as-judge uses a different model from the one being evaluated.
- **Race detector on the Go runner code.**
- **No auto-promote.** Promotion is the owner's call.
- **Cost accountability** — every run reports `totalCost`.
