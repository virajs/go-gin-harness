---
name: run-evals
description: Run LLM evals against the current build — fan a dataset through the running feature, grade in parallel, compare to baseline, recommend promote / regress. Use when validating an LLM feature change or scheduled regression evals. Skip if the product doesn't use LLMs.
argument-hint: <suite> (e.g. answer-quality)
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill, Workflow
---

# Run LLM evals

Evals are how we test non-deterministic behaviour. Unit tests aren't enough for LLM
features — the same prompt can give different outputs, and the grader has to score
quality. Evals are the rigor.

## Mental model

| Test type | What it checks | Determinism | Cost |
|---|---|---|---|
| Unit | Pure logic | Deterministic | Free |
| Integration | Endpoint → DB | Deterministic | Cheap (testcontainers) |
| Eval | LLM output quality | Non-deterministic; we measure aggregate | Real provider tokens; not free |

## Layout

```
evals/<suite>/
├─ dataset.jsonl       one line per case: {"id":"...", "input":{...}, "expected":...}
├─ runner.go           knows how to call the feature against case.input
├─ grader.go           Grade(case, output) (Score, error)
├─ baseline.json       last-promoted scorecard (compare against this)
├─ runs/<run-id>.json  per-run scorecard (committed for history)
└─ runs/<run-id>.md    human-readable summary
```

Each suite tests **one LLM feature**. A typical product has 2–10 suites.

## Authoring a suite

### 1. Dataset

JSONL — one case per line:

```json
{"id":"q1", "input":{"question":"What's the refund policy?"}, "expected":{"category":"policy","contains":["30 days"]}}
{"id":"q2", "input":{"question":"How do I delete my account?"}, "expected":{"category":"account","contains":["settings","delete"]}}
```

- **`id`** — stable identifier; never changes (you compare runs by id).
- **`input`** — whatever your feature takes.
- **`expected`** — shape depends on the grader; common patterns:
  - `{"contains":["..."]}` — substring match
  - `{"category":"X"}` — classification
  - `{"reference":"..."}` — gold reference for LLM-as-judge to compare against

Datasets should be **synthetic or sanitized** — never raw customer data.

### 2. Runner

```go
// evals/<suite>/runner.go
package <suite>

import (
    "context"
    "encoding/json"
    "{{ProjectName}}/internal/app/<feature>"
)

func Run(ctx context.Context, deps Deps, raw json.RawMessage) (json.RawMessage, error) {
    var in <Suite>Input
    if err := json.Unmarshal(raw, &in); err != nil { return nil, err }

    resp, err := deps.UseCase.Handle(ctx, <feature>.<UseCase>Command{
        // map in -> command; use a synthetic tenant
        TenantID: "eval-tenant",
        ...
    })
    if err != nil { return nil, err }
    return json.Marshal(resp)
}
```

### 3. Grader

Two grader styles:

**Deterministic** — exact-match / regex / substring / structural:
```go
func Grade(c Case, output json.RawMessage) (Score, error) {
    var out <SuiteOutput>
    if err := json.Unmarshal(output, &out); err != nil {
        return Score{Pass: false, Reason: "invalid JSON: " + err.Error()}, nil
    }
    for _, needle := range c.Expected.Contains {
        if !strings.Contains(out.Answer, needle) {
            return Score{Pass: false, Score: 0, Reason: "missing: " + needle}, nil
        }
    }
    return Score{Pass: true, Score: 1.0, Reason: "matched all needles"}, nil
}
```

**LLM-as-judge** — a second LLM call grades the output against the gold reference. Slower
+ costs tokens, but handles open-ended outputs:
```go
func Grade(c Case, output json.RawMessage) (Score, error) {
    judge := judgeClient // ai.Client wrapping a frozen, capable model (e.g. opus)
    rubric := fmt.Sprintf(`Judge whether the response is acceptable.
Question: %s
Reference answer: %s
Candidate answer: %s
Respond with JSON: {"score": 0-1, "reason": "..."}`, c.Input.Question, c.Expected.Reference, output)
    resp, err := judge.Complete(context.Background(), ai.CompleteRequest{
        Model: "claude-opus-4-7",
        Messages: []ai.Message{{Role: "user", Content: rubric}},
        MaxTokens: 256,
        Temperature: 0,  // determinism
    })
    if err != nil { return Score{}, err }
    var s Score
    if err := json.Unmarshal([]byte(resp.Content), &s); err != nil {
        return Score{Pass: false, Score: 0, Reason: "judge unparseable: " + err.Error()}, nil
    }
    s.Pass = s.Score >= 0.7  // threshold per-suite
    return s, nil
}
```

Use deterministic where you can; LLM-as-judge where the output is open-ended.

## Running

Invoke the workflow:

```javascript
Workflow({
  name: "eval-run",
  args: { suite: "answer-quality", comparison: "baseline" }
})
```

Or directly:

```bash
# `cmd/evals` is the harness runner — drives a suite, writes the scorecard.
go run ./cmd/evals -suite answer-quality -run-id "$(date +%Y%m%dT%H%M%S)"
```

The runner:
1. Loads the dataset.
2. For each case, calls the suite's `Run` (concurrent, default 8 workers).
3. Grades each output.
4. Writes `runs/<run-id>.json` (machine) + `runs/<run-id>.md` (human).
5. Compares to `baseline.json` (or last run).
6. Surfaces a recommendation.

## Scorecard

```json
{
  "runId":           "20260620T143012",
  "suite":           "answer-quality",
  "dataset":         "evals/answer-quality/dataset.jsonl",
  "model":           "claude-sonnet-4-6",
  "totalCases":      120,
  "passing":         98,
  "failing":         18,
  "errored":         4,
  "aggregateScore":  0.81,
  "baselineScore":   0.78,
  "scoreDelta":      0.03,
  "flippedCases":    [
    {"caseId":"q42", "from":"fail", "to":"pass", "reason":"now includes refund window"},
    {"caseId":"q87", "from":"pass", "to":"fail", "reason":"hallucinated policy line"}
  ],
  "slowestCases":    [{"caseId":"q12","durationMs":4823}, ...],
  "totalCost":       1.42,
  "totalDurationMs": 184320,
  "recommendation":  "investigate"
}
```

Recommendations:
- **promote-baseline** — `scoreDelta >= +0.02` AND no critical regression AND `errored < 5%`.
- **regression-fix-required** — `scoreDelta <= -0.02` OR a `pass→fail` flip on a critical
  case.
- **investigate** — `errored > 5%` OR ambiguous signal (small delta with flips both ways).
- **no-action** — essentially unchanged.

**Baseline promotion is never automatic.** The owner decides; `make evals-baseline` is
the manual step.

## Hard rules

- **Determinism where possible** — `Temperature: 0` in both the feature and the judge.
- **Real model calls** — never mock the LLM in evals; that defeats the purpose.
- **Synthetic / sanitized data only** — never customer data in `dataset.jsonl`.
- **Race detector on the runner** — even though the LLM is non-deterministic, the runner /
  grader Go code must pass `go test -race`.
- **Cost accountability** — every run reports total token spend; long runs go through the
  owner.
- **Report honestly** — if 30% errored, the scorecard says so; don't average errors as
  zeros.
- **No auto-promote** — only the owner promotes a baseline.

## Common pitfalls (avoid)

- Tiny dataset (5 cases) — too noisy to trust a 5% delta. Aim for ≥ 50 cases per suite.
- Reusing the dataset for training the model (if you ever fine-tune) — leakage. Keep
  evals strictly held out.
- LLM-as-judge that uses the same model as the candidate — judge is biased to its own
  outputs. Use a different (often more capable) model.
- Treating eval scores as truth. They're directionally useful but each case has noise;
  delta trends matter more than single-run numbers.

## What this skill does NOT do

- Build the LLM feature itself (use the `go-ai-stack` skill).
- Promote baselines silently — that's the owner's call.
- Replace user studies / manual review for high-stakes UX changes.
