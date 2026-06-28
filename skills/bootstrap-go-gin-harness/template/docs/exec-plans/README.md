# Implementation plans

Build-from-this contracts for non-trivial changes. Format spec:
[../projectStandards/implementation-plan-format.md](../projectStandards/implementation-plan-format.md).

## Layout

```
exec-plans/
├─ <topic>.md                       single-file plan (≤ 5-12 file changes)
├─ <topic>/
│  ├─ master.md                     index + locked decisions + roadmap + status
│  └─ phases/
│     ├─ 01-<phase>.md
│     ├─ 02-<phase>.md
│     └─ ...
```

## Workflow

1. **Draft** — `/exec-plan <topic>` invokes the `exec-plan-build` workflow:
   recon (parallel) → draft → review → finalize.
2. **Review** — the owner reads the plan, asks questions, locks remaining decisions.
3. **Approve** — once OPEN QUESTIONS are resolved, the plan is approved.
4. **Build** — `/run-impl-loop <plan path>` drives:
   - `impl-build` workflow (implement → validate → fix → test)
   - `architect-review` workflow (parallel reviewers + verification)
   - main agent triages findings + summarizes
5. **Status banner** — gets filled in as the plan executes (`drafted` → `approved` →
   `implementing` → `validated` → `tested` → `complete`).
6. **Archive** — once complete, the plan stays here as historical record of the change.

## Naming

`<topic>.md` or `<topic>/master.md` — kebab-case, descriptive:

- `add-projects-feature.md`
- `migrate-sessions-to-redis.md`
- `extract-billing-from-orders/`

## What belongs in `docs/exec-plans/`

- Non-trivial implementations (≥ 3 file changes OR ≥ 1 architectural decision).
- Refactors that span > 1 package.
- Migrations (data, schema, infra).
- New features.

## What does NOT belong here

- Bug fixes that are obvious from the failing test. Just fix.
- Trivial dependency bumps.
- Documentation-only changes.
- Single-file refactors.

For those, write code directly with the owner's approval; no plan needed.
