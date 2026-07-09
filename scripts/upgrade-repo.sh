#!/usr/bin/env bash
# upgrade-repo.sh — safely bring an already-bootstrapped repo up to date with the per-repo
# pieces of the current harness (the "isolated dev environments" delta, v0.5.0).
#
# WHY this exists: `/bootstrap-go-gin-harness` refuses to overwrite an existing repo, and its
# --force does a wholesale copy that clobbers your customized Makefile/CLAUDE.md/rules. This
# script instead applies ONLY the missing pieces, idempotently and without clobbering:
#
#   - copies new files only if absent        (compose.dev.yaml, scripts/worktree.sh)
#   - adds Makefile lines only if missing     (-include .env / export, DB_URL fallback, env targets)
#   - adds .gitignore lines only if missing   (/.worktrees/, .env)
#   - NEVER edits your Go code                 (warns if cmd/api doesn't read PORT/DATABASE_URL)
#
# It refuses to run on a dirty working tree (so the result is one clean, revertable diff),
# unless --force. Use --dry-run to preview. Re-running is safe — it converges.
#
# NOTE: the plugin half (/worktree command, dev-worktree skill, /exec-plan --isolate) upgrades
# separately with `claude plugin update go-gin-harness`. This script only does the per-repo half.
#
# Usage: bash scripts/upgrade-repo.sh [target-dir] [--dry-run] [--force]

set -euo pipefail

DRY_RUN=0; FORCE=0; TARGET_ARG=""
usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown flag: $1" >&2; exit 2 ;;
    *)         [ -z "$TARGET_ARG" ] && TARGET_ARG="$1" || { echo "unexpected arg: $1" >&2; exit 2; }; shift ;;
  esac
done

TARGET="$(cd "${TARGET_ARG:-.}" 2>/dev/null && pwd)" || { echo "target dir not found: ${TARGET_ARG:-.}" >&2; exit 1; }

# ---- locate the plugin template (relative to this script, then fallbacks) --------------
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
for cand in \
  "${CLAUDE_PLUGIN_ROOT:-}/skills/bootstrap-go-gin-harness/template" \
  "$SCRIPT_DIR/../skills/bootstrap-go-gin-harness/template" \
  "$HOME/.claude/plugins/go-gin-harness/skills/bootstrap-go-gin-harness/template"; do
  [ -n "$cand" ] && [ -d "$cand" ] && { TPL="$(cd "$cand" && pwd)"; break; }
done
[ -n "${TPL:-}" ] && [ -f "$TPL/compose.dev.yaml" ] || {
  echo "Cannot locate the plugin template (need compose.dev.yaml). Set CLAUDE_PLUGIN_ROOT or run from the plugin." >&2
  exit 1
}

# ---- sanity: is TARGET a bootstrapped harness repo? ------------------------------------
{ [ -f "$TARGET/CLAUDE.md" ] && [ -d "$TARGET/.claude" ] && [ -f "$TARGET/Makefile" ]; } || {
  echo "Target does not look like a bootstrapped harness repo (missing CLAUDE.md / .claude/ / Makefile):" >&2
  echo "  $TARGET" >&2
  echo "Run /bootstrap-go-gin-harness first if this is a fresh repo." >&2
  exit 1
}

# ---- require a clean git tree (so the upgrade is a reviewable diff) ---------------------
IS_GIT=0
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
  if [ -n "$(git -C "$TARGET" status --porcelain)" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "Working tree is not clean. Commit or stash first so this upgrade lands as one" >&2
    echo "reviewable diff — or pass --dry-run to preview, or --force to override." >&2
    exit 1
  fi
else
  echo "WARNING: $TARGET is not a git repo — changes will not be revertable via git."
fi

# ---- reporting -------------------------------------------------------------------------
APPLIED=(); SKIPPED=(); WARN=()
tag() { [ "$DRY_RUN" -eq 1 ] && echo "[dry-run] would $*" || echo "  $*"; }
did()  { APPLIED+=("$1"); }
skip() { SKIPPED+=("$1"); }
warn() { WARN+=("$1"); }

echo "Upgrade (isolated dev environments) — target: $TARGET"
echo "Template source: $TPL"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — no files will be changed)"
echo

# ---- 1. copy new files if absent -------------------------------------------------------
copy_if_absent() { # relpath [chmodx]
  local rel="$1" mode="${2:-}" src="$TPL/$1" dst="$TARGET/$1"
  if [ -e "$dst" ]; then
    skip "$rel (already present — left as-is)"
    return
  fi
  tag "copy $rel"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    [ "$mode" = "+x" ] && chmod +x "$dst"
  fi
  did "$rel (new file)"
}
copy_if_absent "compose.dev.yaml"
copy_if_absent "scripts/worktree.sh" "+x"

# ---- 2. .gitignore: ensure lines -------------------------------------------------------
ensure_line() { # file literal-line label
  local file="$1" line="$2" label="$3"
  [ -f "$file" ] || { : > "$file"; }
  if grep -qxF "$line" "$file" 2>/dev/null; then
    skip "$label (already ignored)"
    return
  fi
  tag "add to $(basename "$file"): $line"
  if [ "$DRY_RUN" -eq 0 ]; then
    # ensure trailing newline before appending
    [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && printf '\n' >> "$file"
    printf '%s\n' "$line" >> "$file"
  fi
  did "$label"
}
ensure_line "$TARGET/.gitignore" "/.worktrees/" ".gitignore: /.worktrees/"
ensure_line "$TARGET/.gitignore" ".env"         ".gitignore: .env"

# ---- 3. Makefile edits (idempotent) ----------------------------------------------------
MK="$TARGET/Makefile"

# 3a. -include .env + export near the top
if grep -qE '^-include[[:space:]]+\.env' "$MK"; then
  skip "Makefile: -include .env (already present)"
else
  tag "Makefile: add -include .env + export"
  if [ "$DRY_RUN" -eq 0 ]; then
    anchor="$(grep -nE '^(PKG|SHELL|GO)[[:space:]]*[:?]?=' "$MK" | head -1 | cut -d: -f1 || true)"
    tmp="$MK.up.$$"
    # Insert with head/tail (no awk -v — macOS awk rejects newlines in -v strings).
    print_block() {
      printf '%s\n' \
        '# Per-worktree dev env (generated by scripts/worktree.sh). `-include` is silent when' \
        '# .env is absent; `export` propagates PORT/DATABASE_URL/... to recipe subprocesses.' \
        '-include .env' \
        'export'
    }
    if [ -n "$anchor" ]; then
      { head -n "$anchor" "$MK"; echo; print_block; tail -n "+$((anchor + 1))" "$MK"; } > "$tmp"
    else
      { print_block; echo; cat "$MK"; } > "$tmp"
    fi
    mv "$tmp" "$MK"
  fi
  did "Makefile: -include .env + export"
fi

# 3b. DB_URL fallback to $(DATABASE_URL) — preserve the repo's existing default
if ! grep -qE '^DB_URL[[:space:]]*\?=' "$MK"; then
  warn "Makefile has no 'DB_URL ?=' line — skipped DB_URL fallback (add it by hand if you use goose)"
elif grep -E '^DB_URL[[:space:]]*\?=' "$MK" | grep -q 'DATABASE_URL'; then
  skip "Makefile: DB_URL fallback (already wired)"
else
  tag "Makefile: make DB_URL fall back to \$(DATABASE_URL)"
  if [ "$DRY_RUN" -eq 0 ]; then
    tmp="$MK.up.$$"
    awk '
      /^DB_URL[[:space:]]*\?=/ && $0 !~ /DATABASE_URL/ && !done {
        i = index($0, "?="); rhs = substr($0, i+2); sub(/^[[:space:]]+/, "", rhs)
        print "DB_URL ?= $(if $(DATABASE_URL),$(DATABASE_URL)," rhs ")"
        done=1; next
      }
      {print}
    ' "$MK" > "$tmp"
    mv "$tmp" "$MK"
  fi
  did "Makefile: DB_URL fallback"
fi

# 3c. env / env-up / env-down targets (append if missing)
if grep -qE '^env-up:' "$MK"; then
  skip "Makefile: env-up/env-down targets (already present)"
else
  tag "Makefile: append env / env-up / env-down targets"
  if [ "$DRY_RUN" -eq 0 ]; then
    cat >> "$MK" <<'MKEOF'

## ---------- worktree dev env (scripts/worktree.sh) ----------

.PHONY: env
env:  ## (Re)generate this worktree's .env from the registry. Add ARGS=--force to overwrite.
	bash scripts/worktree.sh env $(ARGS)

.PHONY: env-up
env-up:  ## Start this worktree's Postgres, wait healthy, apply migrations.
	bash scripts/worktree.sh up

.PHONY: env-down
env-down:  ## Stop this worktree's Postgres and drop its data volume.
	bash scripts/worktree.sh down
MKEOF
  fi
  did "Makefile: env/env-up/env-down targets"
fi

# ---- 4. cmd/api config contract — DETECT + WARN (never auto-edit code) -----------------
if [ -d "$TARGET/cmd" ]; then
  if grep -rqsE 'os\.Getenv\("PORT"\)|Getenv\("DATABASE_URL"\)' "$TARGET/cmd" 2>/dev/null; then
    skip "cmd/api reads PORT/DATABASE_URL from env (contract satisfied)"
  else
    warn "cmd/api does NOT appear to read PORT + DATABASE_URL from the environment."
    warn "  → Isolation needs this. Update your server bootstrap to read os.Getenv(\"PORT\") (default 8080)"
    warn "    and DATABASE_URL from env. See .claude/rules/gin-conventions.md ('Config from environment')."
  fi
else
  warn "no cmd/ dir yet — when you scaffold cmd/api, make it read PORT + DATABASE_URL from env."
fi

# ---- summary ---------------------------------------------------------------------------
echo
echo "──────── summary ────────"
if [ ${#APPLIED[@]} -eq 0 ]; then
  echo "Applied: (nothing — already up to date)"
else
  echo "Applied:"; for a in "${APPLIED[@]}"; do echo "  ✓ $a"; done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Skipped (already present):"; for s in "${SKIPPED[@]}"; do echo "  – $s"; done
fi
if [ ${#WARN[@]} -gt 0 ]; then
  echo "Manual attention needed:"; for w in "${WARN[@]}"; do echo "  ! $w"; done
fi
echo
echo "Next steps:"
echo "  1. claude plugin update go-gin-harness   # get /worktree, the skill, /exec-plan --isolate"
[ "$IS_GIT" -eq 1 ] && echo "  2. git diff                              # review the per-repo changes"
echo "  3. /refresh-claude-md                    # re-baseline the CLAUDE.md drift fingerprint (if you use that hook)"
echo "  4. /worktree new <slug>                  # try it"
[ "$DRY_RUN" -eq 1 ] && echo && echo "(dry run — nothing was changed)"
