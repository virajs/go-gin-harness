export const meta = {
  name: 'exec-plan-build',
  description: 'Generate an implementation plan in the house format. Reconnaissance (parallel readers per area) → draft plan → adversarial review → final plan written to docs/exec-plans/<topic>.md. Returns the plan path + summary.',
  phases: [
    { title: 'Recon' },
    { title: 'Draft' },
    { title: 'Review' },
    { title: 'Finalize' },
  ],
}

// args: { topic: string, request: string, scope?: string[], outputPath?: string }
const topic   = (args && args.topic)   || (typeof args === 'string' ? args : null)
const request = (args && args.request) || topic
const scope   = (args && Array.isArray(args.scope) && args.scope.length) ? args.scope : ['domain', 'app', 'api', 'persistence', 'tests']
const outputPath = (args && args.outputPath) || `docs/exec-plans/${topic ? topic.toLowerCase().replace(/[^a-z0-9]+/g, '-') : 'plan'}.md`

if (!topic) {
  return { error: 'exec-plan-build requires a topic (args.topic, args.request, or a bare string).' }
}

const RECON_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    area: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          symbol: { type: 'string' },
          line: { type: 'integer' },
          note: { type: 'string' },
        },
        required: ['file', 'note'],
      },
    },
    relevantRules:  { type: 'array', items: { type: 'string' } },
    relevantSkills: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['area', 'findings', 'summary'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    pass: { type: 'boolean' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          section: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium'] },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['section', 'severity', 'problem'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['pass', 'issues', 'summary'],
}

phase('Recon')
log(`Reconnaissance across ${scope.length} area(s): ${scope.join(', ')}`)

const recon = await parallel(
  scope.map(area => () =>
    agent(
      `Read-only reconnaissance for an upcoming implementation plan.
Topic: ${topic}
Request: ${request}
Area: ${area}

Find:
1. Existing files / symbols / contracts the plan will touch (cite file:line).
2. Relevant rules under .claude/rules/** that constrain this area.
3. Relevant skills under .claude/skills/** that the implementer will invoke.
4. Risks — places where a naive implementation would violate a rule or break something.

Do NOT propose a design or write the plan. You are the eyes; the planner is the mind.`,
      { agentType: 'Explore', label: `recon:${area}`, phase: 'Recon', schema: RECON_SCHEMA }
    )
  )
)

phase('Draft')
const planAgent = await agent(
  `Draft an implementation plan for:
Topic: ${topic}
Request: ${request}
Output to: ${outputPath}

Reconnaissance from the recon phase (use this as ground truth, not a sketch — cite file:line from these findings):
${JSON.stringify(recon, null, 2)}

Method: read docs/projectStandards/implementation-plan-format.md before drafting. Follow the house style exactly:
- Goal in one sentence with bold ONLY/NEVER scope boundary
- Locked decisions table (D1, D2, ... with alternative + why)
- Ordered checklist ending in a Validate gate
- File-by-file code samples with absolute paths and "modelled on <existing>.go:<line>" lineage
- Exact named test list (TestX_Y_Z naming; one-line description each)
- OPEN QUESTIONS table at the bottom for anything you cannot lock without the owner

Write the plan to ${outputPath}. Return the path you wrote + a one-paragraph summary of the locked decisions and open questions.

Hard rules: never invent file paths (verify each exists or mark NEW), never invent symbol signatures, never lock a decision that requires the owner's input (put in OPEN QUESTIONS).`,
  { agentType: 'go-gin-harness:exec-planner', label: 'draft', phase: 'Draft' },
)

if (!planAgent) {
  log('Planner agent returned no result — cannot review or finalize. Returning for the main agent to resolve.')
  return {
    topic, request, scope, outputPath,
    recon,
    draft: null, review: null, final: null,
    blocked: true,
    blocker: 'The exec-planner agent produced no output (skipped or died). Re-run /exec-plan; if it recurs, narrow the request scope.',
    summary: `Plan NOT written to ${outputPath} — planner produced no output.`,
  }
}

phase('Review')
const reviewed = await agent(
  `Adversarially review the plan at ${outputPath} that was just written by the planner.
Check:
1. Every locked decision has alternative + why (not just "we'll do X").
2. Every code sample compiles in principle (real imports, real package names, plausible types).
3. Every test in the exact test list is named precisely (TestFoo_BarScenario_Expectation) and one-line described.
4. The "Validate gate" is in the checklist.
5. The ONLY/NEVER scope boundary is unambiguous.
6. No claim is unverified (every file path and symbol must exist or be marked NEW).
7. OPEN QUESTIONS lists everything that requires owner input — better to over-flag than under.

Default to NOT passing if you find any structural gap. Return issues sorted by severity.`,
  { agentType: 'go-gin-harness:architect-backend', label: 'review-plan', phase: 'Review', schema: REVIEW_SCHEMA }
)

phase('Finalize')
let final = planAgent
if (reviewed && reviewed.pass !== true && Array.isArray(reviewed.issues) && reviewed.issues.length > 0) {
  log(`Plan reviewer flagged ${reviewed.issues.length} issue(s) — revising`)
  final = await agent(
    `Revise the plan at ${outputPath} to address ALL of these issues. Keep the plan structure; do not start from scratch. Surface any issue you couldn't fix as a comment in the OPEN QUESTIONS table.

Issues:
${JSON.stringify(reviewed.issues, null, 2)}`,
    { agentType: 'go-gin-harness:exec-planner', label: 'revise', phase: 'Finalize' }
  )
}

return {
  topic, request, scope, outputPath,
  recon,
  draft: planAgent,
  review: reviewed,
  final,
  summary: `Plan written to ${outputPath}. Review: ${reviewed && reviewed.pass ? 'PASS' : 'revised'}${reviewed && reviewed.issues ? ` (${reviewed.issues.length} issue(s) addressed)` : ''}.`,
}
