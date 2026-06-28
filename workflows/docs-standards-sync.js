export const meta = {
  name: 'docs-standards-sync',
  description: 'Detect drift between governance docs and actual code. One agent per doc compares claims to reality; consolidated drift report with proposed fixes. PROPOSE ONLY — never edits docs or code.',
  phases: [
    { title: 'Audit' },
  ],
}

// args: { docs?: string[] }
const DEFAULT_DOCS = [
  'docs/projectStandards/coding-standards.md',
  'docs/projectStandards/backend-architecture.md',
  'docs/projectStandards/build-configuration.md',
  'docs/projectStandards/testing-standards.md',
  'docs/projectStandards/observability-standards.md',
  'docs/projectStandards/security-standards.md',
  'docs/projectStandards/eval-standards.md',
  'docs/projectStandards/implementation-plan-format.md',
  'docs/product-overview.md',
  'CLAUDE.md',
  'README.md',
  // Rules that are likely to drift from code and are worth auditing alongside the standards.
  '.claude/rules/backend/openapi.md',
  '.claude/rules/backend/api-design.md',
  '.claude/rules/backend/tenancy.md',
  '.claude/rules/backend/persistence.md',
]
const docs = (args && Array.isArray(args.docs) && args.docs.length > 0)
  ? args.docs
  : DEFAULT_DOCS

const DRIFT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    doc: { type: 'string' },
    drift: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          claim: { type: 'string' },        // what the doc says
          reality: { type: 'string' },       // what the code/config actually is
          location: { type: 'string' },     // file:line of the reality
          proposal: { type: 'string' },     // suggested change to the doc (NOT the code)
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
        },
        required: ['claim', 'reality', 'location', 'proposal', 'severity'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['doc', 'drift', 'summary'],
}

phase('Audit')
log(`Auditing ${docs.length} doc(s) for drift vs. actual code`)

const reports = await parallel(
  docs.map(doc => () =>
    agent(
      `Audit \`${doc}\` for drift against the actual code/config in this repo.
Method:
1. Read the doc in full.
2. Extract its claims about the code/config (module versions, file paths, conventions, decisions, linter rules, etc.).
3. For each claim, verify against the actual code (Glob/Grep/Read). Cite file:line.
4. Report only DRIFT — claims that contradict reality, are out of date, or were never true. Do NOT report style preferences or aspirational items the doc explicitly marks as "open".
5. Propose the smallest doc edit that reconciles the doc to reality (or, in rare cases where the code is wrong, flag it as a code drift to surface to humans — but still propose the doc edit, since this workflow is propose-only).

Default to NOT reporting if you can't prove drift. Quote the actual code (file:line) for every reported drift.
Report only — do not edit the doc or the code.`,
      { label: `audit:${doc}`, phase: 'Audit', schema: DRIFT_SCHEMA }
    )
  )
)

const allDrift = reports
  .filter(Boolean)
  .flatMap(r => (r.drift || []).map(d => ({ ...d, doc: r.doc })))

const totalDrift = allDrift.length
const critical = allDrift.filter(d => d.severity === 'critical').length
const high     = allDrift.filter(d => d.severity === 'high').length

log(`Total drift found: ${totalDrift} (${critical} critical, ${high} high)`)

return {
  docs,
  reports,
  allDrift,
  totals: {
    drift: totalDrift,
    critical,
    high,
    medium: allDrift.filter(d => d.severity === 'medium').length,
    low: allDrift.filter(d => d.severity === 'low').length,
  },
  summary: totalDrift === 0
    ? 'No drift detected across the standards docs.'
    : `${totalDrift} drift item(s) detected (${critical} critical, ${high} high) across ${reports.filter(r => r.drift && r.drift.length).length} doc(s).`,
}
