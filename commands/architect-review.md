---
description: Run parallel architect reviewers (backend / fullstack / security) against the current diff, then adversarially verify each finding. Returns real findings with confidence + evidence.
allowed-tools: Workflow, Bash, Read, Glob, Grep
argument-hint: '[scope] (default: backend; options: backend, fullstack, security — space-separated to combine)'
---

Run the `architect-review` workflow against the current diff.

Scope: `$ARGUMENTS` if provided, otherwise default to `backend`. For a security audit
pass: `backend security`. For an API-↔-consumer change: `backend fullstack`.

```javascript
Workflow({
  name: "architect-review",
  args: {
    scope: <scope as array>,
    changedPaths: "the current git diff (`git diff` / `git diff --staged`)"
  }
})
```

Report:
- Total findings (before verification)
- Real findings after adversarial verification, grouped by severity
- Noise dismissed
- A recommendation: fix all critical/high now; defer mediums to follow-up; ignore lows
  unless cheap.

Do not edit code; reviewers are read-only. The owner triages.
