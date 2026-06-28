export const meta = {
  name: 'architect-review',
  description: 'Run relevant reviewers (backend / fullstack / security) in parallel for rule adherence, security (OWASP API Top 10 / tenancy / residency), and bug hunt; then adversarially verify each finding. Returns the REAL findings with confidence + evidence.',
  phases: [
    { title: 'Review' },
    { title: 'Verify' },
  ],
}

// args: { scope?: string[], changedPaths?: string, planPath?: string }
const SCOPE_DEFAULT = ['backend']
const scope = (args && Array.isArray(args.scope) && args.scope.length > 0)
  ? args.scope
  : SCOPE_DEFAULT
const changedPaths = (args && args.changedPaths) || 'the current git diff (`git diff` / `git diff --staged`)'
const planPath = (args && args.planPath) || null

const LENSES = {
  backend:   { agentType: 'go-gin-harness:architect-backend',         label: 'review:backend',   description: 'Go/Gin backend — rule adherence + real bugs (tenancy, domain model, Result/error, CQRS, layering, persistence, observability, concurrency).' },
  fullstack: { agentType: 'go-gin-harness:architect-fullstack',       label: 'review:fullstack', description: 'API ↔ consumer seam — contract parity, ProblemDetails fidelity, SSE/streaming, auth/tenancy across boundary, BFF discipline.' },
  security:  { agentType: 'go-gin-harness:security-auditor-backend', label: 'review:security',  description: 'OWASP API Top 10 mapped to Go/Gin/pgx, tenant isolation, secrets, residency.' },
}

const lenses = scope.filter(s => LENSES[s])
if (lenses.length === 0) {
  return { error: `architect-review: no valid scope. Pass one or more of: ${Object.keys(LENSES).join(', ')}` }
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          symbol: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          kind: { type: 'string' },           // e.g. 'tenancy', 'concurrency', 'A01-BOLA'
          title: { type: 'string' },
          detail: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['file', 'severity', 'kind', 'title', 'detail'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['findings', 'summary'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    real: { type: 'boolean' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    evidence: { type: 'string' },
    reason: { type: 'string' },
  },
  required: ['real', 'confidence', 'evidence', 'reason'],
}

phase('Review')
log(`Reviewing ${changedPaths} from ${lenses.length} lens(es): ${lenses.join(', ')}`)

const reviews = await parallel(
  lenses.map(s => () =>
    agent(
      `Review ${changedPaths} from the ${s} lens (${LENSES[s].description}). ${planPath ? `Plan for context: \`${planPath}\`.` : ''}
Read .claude/rules/** before judging. Cite file:line for every finding. Report real bugs / rule violations / security gaps only — style nits are NOT findings. If the diff is small and clean, return findings=[] with a one-sentence summary per checked dimension.`,
      { agentType: LENSES[s].agentType, label: LENSES[s].label, phase: 'Review', schema: FINDINGS_SCHEMA }
    )
  )
)

const allFindings = reviews
  .filter(Boolean)
  .flatMap(r => (r.findings || []).map(f => ({ ...f, _lens: r._lens })))

if (allFindings.length === 0) {
  log('All lenses returned 0 findings.')
  return {
    scope, changedPaths, planPath,
    reviews,
    allFindings: [],
    verified: [],
    real: [],
    summary: 'Architect-review clean: no findings across all lenses.',
  }
}

phase('Verify')
log(`Verifying ${allFindings.length} finding(s) adversarially`)

const verified = await parallel(
  allFindings.map((f, i) => () =>
    agent(
      `Adversarially verify this finding. Default to NOISE if you cannot prove it from source. Quote the actual code (file:line). Findings to verify:
${JSON.stringify(f, null, 2)}`,
      { agentType: 'go-gin-harness:findings-verifier', label: `verify-${i}-${f.severity}`, phase: 'Verify', schema: VERDICT_SCHEMA }
    ).then(v => ({ finding: f, verdict: v }))
  )
)

const real = verified
  .filter(Boolean)
  .filter(v => v.verdict && v.verdict.real === true)

const noise = verified
  .filter(Boolean)
  .filter(v => v.verdict && v.verdict.real !== true)

log(`Verified: ${real.length} REAL · ${noise.length} NOISE (of ${allFindings.length})`)

return {
  scope, changedPaths, planPath,
  reviews,
  allFindings,
  verified,
  real,
  noise,
  summary: `${real.length} real finding(s) (${real.filter(v => v.finding.severity === 'critical').length} critical, ${real.filter(v => v.finding.severity === 'high').length} high) · ${noise.length} dismissed as noise.`,
}
