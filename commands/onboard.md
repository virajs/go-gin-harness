---
description: Produce a grounded orientation for this project — vision, architecture, conventions, where things live, how to do common tasks, current state. Optionally writes docs/ONBOARDING.md.
allowed-tools: Skill
argument-hint: [--write to also produce/refresh docs/ONBOARDING.md]
---

Invoke the `onboard` skill to produce a structured orientation of the current Go/Gin
project, grounded in the real code and the harness standards. Cite `file:line` for every
claim.

If `$ARGUMENTS` contains `--write`, also write/refresh `docs/ONBOARDING.md` (preserve
existing structure if the file exists).
