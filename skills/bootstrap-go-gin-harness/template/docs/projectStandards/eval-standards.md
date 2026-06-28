# {{ProductName}} — LLM eval standards

> How we test non-deterministic LLM features. Skip if the product doesn't talk to a
> model. See `.claude/skills/run-evals/SKILL.md` for the operational procedure.

## Why evals (and not just unit tests)

Unit tests work when the same input always produces the same output. LLMs don't.

- The same prompt can return different outputs.
- Outputs are open-ended; "correct" is fuzzier than `==`.
- Quality is a distribution, not a binary.

Evals are how we measure this distribution rigorously: a dataset of cases, a grader that
scores each output, an aggregate scorecard, and a comparison to baseline.

## The eval program

| Element | What it is |
|---|---|
| **Suite** | A folder under `evals/<name>/` testing one LLM feature. |
| **Dataset** | `dataset.jsonl` — one case per line: `{id, input, expected}`. |
| **Runner** | `runner.go` — calls the feature against `case.input`. |
| **Grader** | `grader.go` — scores each output (deterministic OR LLM-as-judge). |
| **Baseline** | `baseline.json` — last-promoted scorecard. Runs compare against it. |
| **Run** | `runs/<run-id>.json` + `runs/<run-id>.md` — per-run scorecard. |

## Authoring a suite

### 1. Dataset

JSONL — one case per line:

```json
{"id":"q-001", "input":{"question":"What's the refund policy?"}, "expected":{"category":"policy","contains":["30 days"]}}
{"id":"q-002", "input":{"question":"How do I delete my account?"}, "expected":{"category":"account","contains":["settings","delete"]}}
```

- **`id`** — stable; never changes (compared across runs by id).
- **`input`** — feature input.
- **`expected`** — grader-specific (substring list, classification, reference text, etc.).

**Dataset hygiene:**
- **Synthetic / sanitized only.** Never raw customer data.
- **Diverse cases.** Cover the happy path, edge cases, adversarial inputs.
- **Held out.** If you ever fine-tune, NEVER use the eval dataset for training — leakage
  invalidates the eval.
- **Size**: aim for ≥ 50 cases. Smaller is too noisy to trust a delta.

### 2. Runner

`evals/<suite>/runner.go` knows how to call the feature:

```go
func Run(ctx context.Context, deps Deps, raw json.RawMessage) (json.RawMessage, error) {
    var in <Suite>Input
    if err := json.Unmarshal(raw, &in); err != nil { return nil, err }
    resp, err := deps.UseCase.Handle(ctx, <feature>.<UseCase>Command{ /* map in */ })
    if err != nil { return nil, err }
    return json.Marshal(resp)
}
```

### 3. Grader

Two graders coexist; pick by the suite:

**Deterministic** — for outputs with structural expectations (substring, regex,
classification):
```go
func Grade(c Case, out json.RawMessage) (Score, error) {
    var o Output
    if err := json.Unmarshal(out, &o); err != nil {
        return Score{Pass: false, Score: 0, Reason: "invalid JSON"}, nil
    }
    for _, needle := range c.Expected.Contains {
        if !strings.Contains(o.Answer, needle) {
            return Score{Pass: false, Score: 0, Reason: "missing: " + needle}, nil
        }
    }
    return Score{Pass: true, Score: 1, Reason: "all needles present"}, nil
}
```

**LLM-as-judge** — for open-ended outputs:
```go
func Grade(c Case, out json.RawMessage) (Score, error) {
    rubric := fmt.Sprintf(`Judge the candidate answer against the reference.
Question: %s
Reference: %s
Candidate: %s
Respond with JSON: {"score": 0-1, "reason": "..."}`, c.Input.Question, c.Expected.Reference, out)

    resp, err := judgeClient.Complete(context.Background(), ai.CompleteRequest{
        Model: "claude-opus-4-7",   // capable + different from the candidate's model
        Messages: []ai.Message{{Role: "user", Content: rubric}},
        Temperature: 0,
        MaxTokens: 256,
    })
    if err != nil { return Score{}, err }
    var s Score
    if err := json.Unmarshal([]byte(resp.Content), &s); err != nil {
        return Score{Pass: false, Score: 0, Reason: "judge unparseable"}, nil
    }
    s.Pass = s.Score >= 0.7
    return s, nil
}
```

**Hard rules for graders:**
- **Judge is a different model from the candidate.** Same model = self-bias.
- **Judge uses `Temperature: 0`** for determinism.
- **Pass-threshold is per-suite.** Document the rationale.

## Running

```javascript
Workflow({ name: "eval-run", args: { suite: "answer-quality" } })
```

Or directly:

```bash
make evals                                    # all suites
go run ./cmd/evals -suite answer-quality      # one suite
```

The runner:
1. Loads the dataset.
2. Fans each case through `Run` in parallel (default 8 workers; configurable).
3. Grades each output via `Grade`.
4. Writes `runs/<run-id>.json` + `runs/<run-id>.md`.
5. Compares to `baseline.json`.
6. Surfaces a recommendation.

## Scorecard

```json
{
  "runId": "20260620T143012",
  "suite": "answer-quality",
  "model": "claude-sonnet-4-6",
  "totalCases":      120,
  "passing":         98,
  "failing":         18,
  "errored":         4,
  "aggregateScore":  0.81,
  "baselineScore":   0.78,
  "scoreDelta":      0.03,
  "flippedCases":    [{"caseId":"q-042","from":"fail","to":"pass","reason":"..."}],
  "slowestCases":    [{"caseId":"q-012","durationMs":4823}],
  "totalCost":       1.42,
  "totalDurationMs": 184320,
  "recommendation":  "investigate"
}
```

**Recommendations:**
- `promote-baseline` — `scoreDelta ≥ +0.02` AND no critical regression AND `errored < 5%`.
- `regression-fix-required` — `scoreDelta ≤ -0.02` OR a `pass→fail` flip on a critical case.
- `investigate` — `errored > 5%` OR ambiguous signal (small delta + flips both ways).
- `no-action` — essentially unchanged.

**No auto-promote.** `make evals-baseline` is the manual promotion step; the owner
decides.

## When to run

- **On every change** to an LLM feature or its prompt. The CI may or may not run evals
  by default (they cost real tokens) — document the threshold.
- **Scheduled** — weekly regression run against the baseline catches model-provider
  drift (the model updated under us; outputs may have shifted).
- **On model upgrades** — comparing Sonnet 4.6 vs 4.7 vs Opus 4.7 for the same suite is
  THE way to choose models for a feature.

## Cost accountability

Evals cost real provider tokens. Every run reports:
- `totalCost` (USD)
- `totalDurationMs`
- Per-case duration (slowest 5 surfaced)

A suite that costs > $1 per run goes through the owner before becoming part of CI. Use
smaller datasets for CI; full datasets for release-gate runs.

## Hard rules

- **Determinism where possible.** `Temperature: 0` in both candidate and judge.
- **Real model calls** — never mock the LLM in evals.
- **Synthetic data only** — no customer data in `dataset.jsonl`.
- **Race detector on the Go code.** Even though LLM output is non-deterministic, the
  runner / grader Go code passes `go test -race`.
- **Honest reporting.** Errored cases are counted separately, not averaged as zeros.
- **No auto-promote.** Promotion is the owner's call.
- **Diff the run** — compare to baseline; surface flipped cases; never just "the score
  went up".

## Common pitfalls

- **Tiny dataset (5 cases)** — too noisy to trust a 5% delta. Aim for ≥ 50.
- **LLM-as-judge using the same model as the candidate** — self-bias. Different model
  always.
- **Re-using the eval dataset for fine-tuning** — leakage; invalidates the eval.
- **Treating scores as truth** — directionally useful; each case has noise; delta trends
  matter more than single-run numbers.

## See also

- `.claude/skills/run-evals/SKILL.md` — operational procedure.
- `.claude/skills/go-ai-stack/SKILL.md` — building the feature being evaluated.
- `.claude/workflows/eval-run.js` — the orchestration workflow.
- `.claude/agents/eval-runner.md` — the agent that drives a run.
- `evals/README.md` — repo-level pointer.
