export const meta = {
  name: 'eval-run',
  description: 'Fan an LLM eval dataset through the current build, grade in parallel, score vs. baseline. Returns a scorecard with delta and a promote-baseline recommendation. Skip for products without LLM features.',
  phases: [
    { title: 'Eval', detail: 'eval-runner agent runs setup->run->grade->report in one step' },
  ],
}

// args: { suite: string, dataset?: string, model?: string, runId?: string, comparison?: 'baseline' | 'last' }
const suite = (args && args.suite) || (typeof args === 'string' ? args : null)
if (!suite) {
  return { error: 'eval-run requires a suite (args.suite or bare string, e.g. "answer-quality").' }
}
const dataset    = (args && args.dataset)    || `evals/${suite}/dataset.jsonl`
const model      = (args && args.model)      || null
const runId      = (args && args.runId)      || `run-${suite}-{{ProjectName}}`  // workflows can't read clock; main agent stamps it
const comparison = (args && args.comparison) || 'baseline'

const SCORECARD_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    runId: { type: 'string' },
    suite: { type: 'string' },
    dataset: { type: 'string' },
    model: { type: 'string' },
    totalCases: { type: 'integer' },
    passing: { type: 'integer' },
    failing: { type: 'integer' },
    errored: { type: 'integer' },
    aggregateScore: { type: 'number' },
    baselineScore: { type: 'number' },
    scoreDelta: { type: 'number' },
    flippedCases: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          caseId: { type: 'string' },
          from: { type: 'string', enum: ['pass', 'fail', 'error'] },
          to:   { type: 'string', enum: ['pass', 'fail', 'error'] },
          reason: { type: 'string' },
        },
        required: ['caseId', 'from', 'to', 'reason'],
      },
    },
    slowestCases: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { caseId: { type: 'string' }, durationMs: { type: 'integer' } },
        required: ['caseId', 'durationMs'],
      },
    },
    totalCost: { type: 'number' },
    totalDurationMs: { type: 'integer' },
    runArtifactJson: { type: 'string' },
    runArtifactMd:   { type: 'string' },
    recommendation: { type: 'string', enum: ['promote-baseline', 'investigate', 'regression-fix-required', 'no-action'] },
    summary: { type: 'string' },
  },
  required: ['runId', 'suite', 'totalCases', 'passing', 'failing', 'errored', 'aggregateScore', 'recommendation', 'summary'],
}

// The eval-runner agent owns the full setup->run->grade->report cycle in one call
// (the suite's runner.go/grader.go do the staging internally), so this workflow is a
// single agent step rather than four orchestrated phases.
phase('Eval')
log(`Eval run: suite=${suite} dataset=${dataset} model=${model || 'suite-default'} comparison=${comparison}`)

const result = await agent(
  `Run the LLM eval suite "${suite}".
Inputs:
  suite         = ${suite}
  dataset       = ${dataset}
  model         = ${model || '(use the suite-default)'}
  runId         = ${runId}
  comparison    = ${comparison}  ('baseline' = compare to evals/<suite>/baseline.json; 'last' = compare to evals/<suite>/runs/<latest>.json)

Steps:
1. Confirm the suite exists at evals/${suite}/ and contains dataset.jsonl + grader.go + runner.go.
2. Compile: \`go build ./evals/${suite}/...\` and \`go build ./cmd/evals\`. Surface any error.
3. Run the suite via \`go run ./cmd/evals -suite ${suite} -dataset ${dataset} -run-id ${runId}${model ? ' -model ' + model : ''}\`.
4. Wait for completion. The runner writes evals/${suite}/runs/${runId}.json and runs/${runId}.md.
5. Compare to the chosen baseline (read evals/${suite}/baseline.json or runs/<previous>.json). Compute scoreDelta and the list of flipped cases.
6. Surface the scorecard fields per the schema. Recommend:
   - promote-baseline   if scoreDelta >= +0.02 with no critical regressions and errored < 5%
   - regression-fix-required if scoreDelta <= -0.02 OR any flipped 'pass' -> 'fail' case is tagged critical
   - investigate        if errored > 5% OR ambiguous signal (small delta + flips in both directions)
   - no-action          if essentially unchanged

Never auto-promote the baseline — that is the owner's call. Surface the recommendation only.`,
  { agentType: 'go-gin-harness:eval-runner', label: 'eval', phase: 'Eval', schema: SCORECARD_SCHEMA },
)

if (!result) {
  return {
    suite, dataset, model, runId, comparison,
    error: true,
    summary: `Eval suite "${suite}" produced no scorecard — the eval-runner agent was skipped or died. Verify evals/${suite}/ exists (dataset.jsonl + grader.go + runner.go) and re-run /run-evals ${suite}.`,
  }
}

return result
