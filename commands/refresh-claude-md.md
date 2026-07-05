---
description: Refresh the repo's CLAUDE.md against the actual code — regenerate the derived sections (status banner, "Where things live" tree, build gates, doc pointers) from ground truth, preserve human-authored governance/vision, flag dead links. Applies the safe refreshes; asks before rewriting or dropping any governance content.
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Skill
argument-hint: "[--dry-run to propose only, without editing]"
---

The user wants to refresh this repo's **CLAUDE.md** so it matches the current code. CLAUDE.md
is the per-repo governance doc bootstrapped from the harness (see
`skills/bootstrap-go-gin-harness/template/CLAUDE.md` for the canonical section layout).

Ground rule from the harness authority hierarchy: **code is the top rung, CLAUDE.md is
documentation (a lead to verify, never an authority).** When they disagree, the code wins and
CLAUDE.md gets corrected — never the reverse.

Procedure:

1. **Locate CLAUDE.md** at the repo root. If it doesn't exist, tell the user to run
   `/bootstrap-go-gin-harness` (harness governance) or `/init` (plain scaffold) first, and stop.

2. **Establish ground truth from the real repo** (read/inspect — don't assume):
   - **Module + product name** — `go.mod` module path (fills any `{{ProjectName}}` placeholder);
     product name/vision from `docs/product-overview.md`.
   - **Status banner** — does product code actually exist? Glob `cmd/**/main.go`, `internal/**`,
     `pkg/**`. If the trees are scaffolded, the "harness / governance only — no product code yet"
     banner is stale — replace it with the real state; if still bare, keep it.
   - **"Where things live" tree** — regenerate from the actual directory layout (top 2–3 levels
     of `cmd/`, `internal/`, `pkg/`, `migrations/`, `test/`, `evals/`, `docs/`, `.claude/`).
     Drop template dirs that don't exist; add real ones the template didn't list.
   - **Build gates** — reconcile the Build section against reality: linter list from
     `.golangci.yml`, coverage thresholds from the `Makefile`/config, and the actual gate
     targets (`test -race`, `govulncheck`, `openapi-validate`). Numbers and linter names must
     match the files, not the template's defaults.
   - **Design non-negotiables** — verify each still applies. E.g. the **tenancy** invariant:
     grep for `tenant_id` / tenant middleware; if the product is single-tenant (no evidence),
     the tenancy non-negotiable is a candidate to drop — but see step 4 (ask, don't silently cut).
   - **Doc pointers** — every `docs/projectStandards/*`, `.claude/rules/*`, and `docs/decisions/*`
     path referenced in CLAUDE.md: confirm the target file exists. Collect dead links.

3. **Refresh the derived sections in place.** Regenerate the mechanical/derived content —
   status banner, directory tree, build gates, doc-pointer paths — to match ground truth.
   Fix dead links to the real path (or flag if the target is genuinely gone).

4. **Preserve human-authored governance + vision. Ask before rewriting or removing any of it.**
   - The **"Ways of working"** section is stable cross-repo governance — do **not** rewrite its
     prose. Only reconcile it with newer harness template sections if the plugin has added them
     (offer to add; don't silently overwrite).
   - Product vision / owner edits / hand-written prose: keep verbatim.
   - Any change that **removes or materially rewrites a governance rule or design
     non-negotiable** (e.g. dropping the tenancy invariant): STOP and present it as an explicit
     choice with a recommendation — this is the owner's decision, per "Decisions are the owner's."

5. **`--dry-run`** (if `$ARGUMENTS` contains it): do steps 1–4 as **propose-only** — output the
   diff/summary and stop without editing. Mirrors `docs-standards-sync`'s propose-only stance.

6. **Report**:
   - Sections refreshed (with before→after for banners/numbers).
   - Dead links found + how each was resolved.
   - Any governance/non-negotiable change that needs the owner's decision (left unapplied,
     surfaced as a question).
   - Suggest `/docs-standards-sync` for a full audit across the *other* governance docs
     (README, product-overview, projectStandards/*) — this command only touches CLAUDE.md.

Do NOT invent standards that aren't in the code or the harness template. If CLAUDE.md claims
something the code contradicts, the code is authoritative — correct the doc and note the drift.
