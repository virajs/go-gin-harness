#!/usr/bin/env bash
# claude-md-maintenance.sh — SessionStart hook (+ manual --update-fingerprint mode).
#
# Automated CLAUDE.md maintenance pipeline, deterministic half:
#
#   SessionStart → this hook fingerprints the repo state that CLAUDE.md's DERIVED
#   sections are generated from (dir layout, .golangci.yml, Makefile, standards docs,
#   .claude/rules, go.mod module, tenancy signal). If any input changed since the last
#   refresh, it injects an additionalContext NUDGE telling the agent CLAUDE.md may be
#   stale and to run `/refresh-claude-md --dry-run`.
#
# A hook can't run the model, so it only DETECTS + NUDGES. The model half is the
# `/refresh-claude-md` command: it regenerates CLAUDE.md, then calls this script with
# `--update-fingerprint` to write a fresh baseline — which clears the nudge until an
# input changes again. Detect → nudge → refresh → re-baseline → quiet.
#
# The fingerprint file (.claude/hooks/context/.claude-md.fingerprint) is COMMITTED, so
# a teammate's input change makes it stale for everyone until someone refreshes.
#
# Influence-by-feedback, NOT a hard block. Fails OPEN: any error emits nothing, exit 0.

set -uo pipefail

proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"
fp="$proj/.claude/hooks/context/.claude-md.fingerprint"
claude="$proj/CLAUDE.md"

# Fixed set of tracked inputs (keys). Same list drives detect + baseline.
KEYS="tree golangci makefile standards rules module tenancy"

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else cksum | awk '{print $1}'; fi
}

# compute <key> → a stable hash of that input's current state.
compute() {
  case "$1" in
    tree)      find "$proj/cmd" "$proj/internal" "$proj/pkg" "$proj/migrations" \
                    "$proj/test" "$proj/evals" "$proj/docs" -maxdepth 3 -type d 2>/dev/null \
                    | sed "s|^$proj/||" | sort ;;
    golangci)  cat "$proj/.golangci.yml" 2>/dev/null ;;
    makefile)  cat "$proj/Makefile" 2>/dev/null ;;
    standards) ls "$proj/docs/projectStandards" 2>/dev/null | sort ;;
    rules)     find "$proj/.claude/rules" -type f 2>/dev/null | sed "s|^$proj/||" | sort ;;
    module)    grep -m1 '^module ' "$proj/go.mod" 2>/dev/null ;;
    tenancy)   { grep -rIl 'tenant_id' "$proj/internal" "$proj/migrations" 2>/dev/null | head -1; } ;;
  esac | hash_stdin
}

# Human-readable label for the nudge message.
label() {
  case "$1" in
    tree)      echo "directory layout" ;;
    golangci)  echo ".golangci.yml (linters)" ;;
    makefile)  echo "Makefile (build gates)" ;;
    standards) echo "docs/projectStandards/" ;;
    rules)     echo ".claude/rules/" ;;
    module)    echo "go.mod module path" ;;
    tenancy)   echo "tenancy signal" ;;
  esac
}

write_fp() {
  mkdir -p "$(dirname "$fp")" 2>/dev/null || return 0
  local tmp="$fp.tmp.$$"
  : > "$tmp" 2>/dev/null || return 0
  local k
  for k in $KEYS; do
    printf '%s\t%s\n' "$k" "$(compute "$k")" >> "$tmp"
  done
  mv "$tmp" "$fp" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

stored_hash() {
  # tab-delimited "key<TAB>hash"; return the hash for $1.
  grep -m1 "^$1$(printf '\t')" "$fp" 2>/dev/null | cut -f2-
}

# ── Mode: re-baseline (called by /refresh-claude-md after it rewrites CLAUDE.md) ──
if [[ "${1:-}" == "--update-fingerprint" ]]; then
  write_fp
  echo "claude-md-maintenance: fingerprint baseline updated ($fp)" >&2
  exit 0
fi

# ── Mode: detect (SessionStart) ──
# Drain stdin (SessionStart payload) without blocking if invoked from a terminal.
[ -t 0 ] || cat >/dev/null 2>&1 || true

# Nothing to maintain if the repo has no CLAUDE.md.
[[ -f "$claude" ]] || exit 0

# First run (no baseline yet): establish it silently — a freshly bootstrapped CLAUDE.md
# already matches the repo, so there's nothing to nudge about.
if [[ ! -f "$fp" ]]; then
  write_fp
  exit 0
fi

changed=()
for k in $KEYS; do
  [[ "$(compute "$k")" != "$(stored_hash "$k")" ]] && changed+=("$(label "$k")")
done
[[ ${#changed[@]} -eq 0 ]] && exit 0

# Build the nudge. Join changed labels with ", ".
joined=""
for c in "${changed[@]}"; do
  [[ -n "$joined" ]] && joined+=", "
  joined+="$c"
done

msg="⚠ CLAUDE.md may be stale — its derived sections are generated from repo state that has changed since the last refresh.
Changed since last refresh: ${joined}.
Run \`/refresh-claude-md --dry-run\` to review the drift (or \`/refresh-claude-md\` to apply). This notice clears once CLAUDE.md is refreshed."

esc=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
      || printf '"%s"' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}' "$esc"
exit 0
