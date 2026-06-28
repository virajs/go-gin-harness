---
description: Detect drift between the governance docs (CLAUDE.md, docs/projectStandards/*, .claude/rules/*) and the actual code. One agent per doc; consolidated drift report with proposed fixes. PROPOSE ONLY — never edits.
allowed-tools: Workflow, Read, Glob, Grep
---

Run the `docs-standards-sync` workflow to audit the governance docs for drift against
the actual code/config in this repo.

```javascript
Workflow({ name: "docs-standards-sync" })
```

Pass a custom doc list via `args.docs` if the user named specific docs; otherwise the
workflow audits the default set (CLAUDE.md, README.md, docs/product-overview.md,
docs/projectStandards/*).

Report:
- Total drift items, grouped by severity
- Per-doc summary
- Proposed fixes (these are propositions; the workflow never edits)

Surface the report; the owner decides which fixes to apply (via a follow-up
`/run-impl-loop` against a small docs-only plan, OR by editing the docs directly).
