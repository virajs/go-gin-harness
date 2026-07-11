---
name: bootstrap-go-gin-harness
description: Scaffold the per-repo Go/Gin harness governance (rules, hooks, settings.json, Makefile, .golangci.yml, sqlc.yaml, .editorconfig, .gitignore, .air.toml, .mcp.json, go.mod, CLAUDE.md, docs/, scripts/, migrations/, evals/, test/) into a target repository. Use when starting a new Go/Gin project, or to re-install the per-repo harness pieces into an existing repo.
argument-hint: '[target-dir] (defaults to the current directory)'
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash
---

# Bootstrap go-gin-harness into a repo

This skill installs the **per-repo** half of the harness (rules, hooks, build files,
docs) into a target directory. The plugin-level half (agents, workflows, universal
skills) is already available system-wide because the plugin is installed.

## Inputs the user must provide

Ask interactively (before doing any work):

1. **Target directory** — default `.` (current working directory). Must exist; should
   ideally be empty or contain only `.git/`.
2. **Go module path** — e.g. `github.com/acme/orders-api`. Replaces `{{ProjectName}}` in
   every copied file.
3. **Product display name** — e.g. `OrdersAPI`, `Acme Orders`. Replaces `{{ProductName}}`.
4. **Multi-tenant?** — default Yes. If No, delete `.claude/rules/backend/tenancy.md` and
   note in `CLAUDE.md` that tenancy is off.
5. **Uses LLMs / needs evals?** — default Yes. If No, delete `evals/`, the eval skill
   from any per-repo skill copy (none in this template by default), and the
   `eval-standards.md` doc.

Surface defaults; let the user accept or override.

## Source location

The template lives alongside this SKILL.md:

```
<plugin>/skills/bootstrap-go-gin-harness/template/
```

Resolve the path. Common environment variables and fallbacks (try in order):

```bash
# 1. CLAUDE_PLUGIN_ROOT (preferred — set by Claude Code when running a plugin skill)
TPL="${CLAUDE_PLUGIN_ROOT:-}/skills/bootstrap-go-gin-harness/template"

# 2. Discover via the system plugin install path
[ -d "$TPL" ] || TPL="$HOME/.claude/plugins/go-gin-harness/skills/bootstrap-go-gin-harness/template"

# 3. Fallback: search common locations
[ -d "$TPL" ] || TPL="$(find "$HOME/.claude" -type d -name template -path '*bootstrap-go-gin-harness*' 2>/dev/null | head -n1)"

# 4. Last resort — ask the user where the plugin lives
[ -d "$TPL" ] || { echo "Cannot locate plugin template; please provide the path."; }
```

Confirm the resolved `$TPL` exists and contains `CLAUDE.md`, `.claude/`, `Makefile`
before proceeding.

## Preflight (refuse to clobber)

In the target directory, check for existing harness artifacts:

```bash
TARGET="${1:-.}"
conflicts=$(
  for f in CLAUDE.md .claude .golangci.yml .editorconfig Makefile sqlc.yaml \
           .air.toml .mcp.json go.mod docs scripts migrations evals test; do
    [ -e "$TARGET/$f" ] && echo "  - $TARGET/$f"
  done
)
if [ -n "$conflicts" ]; then
  echo "Target already contains harness artifacts:"
  echo "$conflicts"
  echo ""
  echo "Refuse to clobber. Options:"
  echo "  1. Pick a different target directory."
  echo "  2. Move existing files aside first."
  echo "  3. Re-run with --force ONLY if you intentionally want to overwrite (and have a clean git status)."
  exit 1
fi
```

If `--force` is passed, require `git status --porcelain` to be empty AND ask the user
to confirm. Never silently overwrite uncommitted work.

## Copy

```bash
# Use cp -R to preserve dotfiles and the .claude tree.
cp -R "$TPL"/. "$TARGET"/

# Sanity check — the copy landed.
[ -f "$TARGET/CLAUDE.md" ]            || { echo "Copy failed: CLAUDE.md missing"; exit 1; }
[ -d "$TARGET/.claude/rules" ]        || { echo "Copy failed: rules missing"; exit 1; }
[ -x "$TARGET/.claude/hooks/protect-commands.sh" ] || true   # we re-chmod next
```

## Placeholder substitution

Replace `{{ProjectName}}` and `{{ProductName}}` everywhere:

```bash
PROJECT_NAME="github.com/acme/orders-api"  # from the user
PRODUCT_NAME="OrdersAPI"                    # from the user

# Escape for sed (slashes are common in module paths)
esc() { printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }
P=$(esc "$PROJECT_NAME"); D=$(esc "$PRODUCT_NAME")

# Find text files only; skip binary + .git
find "$TARGET" -type f \
  -not -path '*/.git/*' \
  -not -name '*.png' -not -name '*.jpg' -not -name '*.jpeg' -not -name '*.gif' \
  -not -name '*.pdf' -not -name '*.ico' \
  -print0 |
while IFS= read -r -d '' f; do
  # macOS BSD sed wants `-i ''`; GNU sed wants `-i`. Detect.
  if sed --version >/dev/null 2>&1; then
    sed -i -e "s/{{ProjectName}}/$P/g" -e "s/{{ProductName}}/$D/g" "$f"
  else
    sed -i '' -e "s/{{ProjectName}}/$P/g" -e "s/{{ProductName}}/$D/g" "$f"
  fi
done

# Verify nothing was missed.
remaining=$(grep -rln '{{ProjectName}}\|{{ProductName}}' "$TARGET" --exclude-dir=.git || true)
[ -z "$remaining" ] || { echo "WARN: placeholders remain in:"; echo "$remaining"; }
```

## Make scripts executable

```bash
chmod +x "$TARGET"/.claude/hooks/*.sh
chmod +x "$TARGET"/scripts/*.sh
```

## Optional: drop multi-tenancy

If the user said the product is single-tenant:

```bash
rm -f "$TARGET/.claude/rules/backend/tenancy.md"
# Edit CLAUDE.md / product-context.md to remove the tenancy lines (interactive — see Read/Edit).
```

Tell the user: review `CLAUDE.md`, `docs/product-overview.md`, and the rules — there are
still references to `tenant_id` that you may want to remove per your domain.

## Optional: drop LLM/eval surface

If the user said no LLMs:

```bash
rm -rf "$TARGET/evals" "$TARGET/docs/evals" "$TARGET/docs/projectStandards/eval-standards.md"
# Edit CLAUDE.md to drop the evals references.
```

## Initialize Go module

```bash
cd "$TARGET" && go mod tidy   # no-op if no deps; verifies the module declaration parses
```

## Print next steps

```
Bootstrap complete in $TARGET

Files installed:
- CLAUDE.md, README.md, .editorconfig, .gitignore, .golangci.yml, .air.toml, .mcp.json
- go.mod, Makefile, sqlc.yaml
- .claude/settings.json + hooks/ + rules/  (14 rules total)
- docs/  (product-overview, projectStandards/*, exec-plans/README, evals/README,
   decisions/{README, 0000-template, 0001-record-adrs})
- scripts/check-coverage.sh
- migrations/, evals/, test/ (README pointers)

Placeholders substituted:
- {{ProjectName}} → $PROJECT_NAME
- {{ProductName}} → $PRODUCT_NAME

Next steps:
  1. Review docs/product-overview.md — fill in the product context.
  2. Review .claude/hooks/context/product-context.md — short version, injected at session start.
  3. Verify the build pipeline: make ci  (will fail until you scaffold code — that's expected).
  4. In a fresh Claude Code session, run:
       /onboard
       /exec-plan "scaffold the api skeleton — cmd/api/main.go, middleware stack, sample feature"
     Approve the plan, then:
       /run-impl-loop docs/exec-plans/scaffold-api-skeleton.md

Optional:
  - git init && git add . && git commit -m "Initial commit (go-gin-harness)"   (owner's call — per-action approval)
```

## Hard rules

- **Never silently overwrite.** Refuse on conflict unless `--force` is passed AND
  `git status` is clean.
- **No third-party Go module without approval.** The bootstrap doesn't add deps; the
  user adds them per-module via the harness's normal flow.
- **Don't run `git init` / `git commit` automatically.** Owner-only, per-action approval.
- **Don't run `make ci`** — it'll fail (no code yet); that's expected; user runs it when
  they have code.
- **Don't push, don't open PRs.** Bootstrap is local-only.

## Common mistakes (don't)

- Running `cp -r template target` instead of `cp -R template/. target/` — the trailing
  `/.` is what copies dotfiles. Test with a temp dir before deploying.
- Forgetting `chmod +x` on hooks — Claude Code's PreToolUse hooks won't fire if not
  executable.
- Missing the sed-portability dance (macOS BSD vs GNU). The skill body handles it.
- Leaving placeholders unsubstituted. The verification `grep -rln {{...}}` catches it;
  surface as a warning.

## What this skill does NOT do

- Scaffold Go source code (`cmd/api/main.go`, `internal/*`). That's the second step,
  driven by `/exec-plan` + `/run-impl-loop` using the now-installed harness.
- Install dependencies. Per-module approval is the harness's hard rule; the user adds
  each.
- Initialize git, create remotes, push branches. Owner-only.
- Configure CI. Per-CI-platform; out of scope for the bootstrap.
