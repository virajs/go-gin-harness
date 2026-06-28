## Summary

<!-- One paragraph: what changes and why. Link the issue it fixes / feature it implements. -->

## Was this generated via the harness's own operating model?

- [ ] **Yes** — `/exec-plan` → owner approval → `/run-impl-loop`. Link the plan:
- [ ] **No** — manual edit. Why? (Brief justification — e.g. "trivial doc fix", "v0.x bootstrap evolution"):

## Change category

- [ ] Agent (`agents/<name>.md`)
- [ ] Skill (`skills/<name>/SKILL.md`)
- [ ] Workflow (`workflows/<name>.js`)
- [ ] Slash command (`commands/<name>.md`)
- [ ] Per-repo template (`skills/bootstrap-go-gin-harness/template/...`)
- [ ] Plugin manifest / marketplace metadata
- [ ] Documentation (README, CHANGELOG, etc.)
- [ ] CI / build
- [ ] Security

## Verification

- [ ] Smoke-tested the plugin install: `claude plugin marketplace add . && claude plugin install go-gin-harness@go-gin-harness`
- [ ] Smoke-tested the bootstrap in a clean directory (if the change touches the template)
- [ ] Workflow JS still parses: `node --check workflows/*.js` (if workflows touched)
- [ ] JSON files still valid (`plugin.json`, `marketplace.json` — if touched)
- [ ] Shell scripts pass `bash -n` (if hooks touched)

## ADR / decision record

If this change locks an architectural decision (new convention, supersession of an
existing pattern), link the ADR or note that one is forthcoming:

- ADR:

## Breaking changes

- [ ] No breaking changes (additive only)
- [ ] Breaking — describe migration:

## Checklist

- [ ] CHANGELOG updated under `[Unreleased]`
- [ ] Version bumped in `plugin.json` AND `marketplace.json` (if this is a release)
- [ ] README / docs updated for any user-facing surface change
