#!/usr/bin/env bash
# enforce-formatting.sh — PostToolUse hook on Edit/Write/MultiEdit.
#
# After a write to a .go file: run gofumpt + goimports + go vet on the changed file's
# package. Surfaces formatting / vet failures immediately rather than at commit/CI time.
#
# This is influence-by-feedback (NOT a hard block) — Claude sees the additionalContext
# message and learns to fix it on the next turn. Failing fast keeps mistakes close to
# the edit that caused them.
#
# Fails OPEN: any tool error or missing path returns 0 (a hook bug must never hard-block).

set -uo pipefail

event="$(cat 2>/dev/null || true)"
[[ -z "$event" ]] && exit 0

# Extract the file path (toolInput.file_path or toolInput.path or toolInput.filePath).
if command -v jq >/dev/null 2>&1; then
  path="$(printf '%s' "$event" | jq -r '.toolInput.file_path // .toolInput.path // .toolInput.filePath // empty' 2>/dev/null || true)"
else
  path="$(printf '%s' "$event" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[[ -z "$path" ]] && exit 0

# Only act on .go files.
case "$path" in
  *.go) ;;
  *) exit 0 ;;
esac

# Skip generated sqlc / mock files — they're generated, don't format them.
case "$path" in
  *.sql.go|*_mock.go|*_gen.go) exit 0 ;;
esac

# Resolve to absolute path under the project.
proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"
abs="$path"
[[ "$abs" != /* ]] && abs="$proj/$abs"
[[ ! -f "$abs" ]] && exit 0

pkg_dir="$(dirname "$abs")"
notes=()

# gofumpt — stricter gofmt
if command -v gofumpt >/dev/null 2>&1; then
  if ! out=$(gofumpt -l "$abs" 2>&1); then
    notes+=("gofumpt error: $out")
  elif [[ -n "$out" ]]; then
    gofumpt -w "$abs" 2>/dev/null || true
    notes+=("gofumpt: reformatted ${path}")
  fi
fi

# goimports — group + remove unused imports
if command -v goimports >/dev/null 2>&1; then
  goimports -w "$abs" 2>/dev/null || true
fi

# go vet — fast, finds real bugs
if command -v go >/dev/null 2>&1; then
  vet_out=$(cd "$proj" && go vet "./$(realpath --relative-to="$proj" "$pkg_dir" 2>/dev/null || echo "$pkg_dir")" 2>&1) || true
  if [[ -n "$vet_out" && "$vet_out" != *"no Go files"* ]]; then
    notes+=("go vet found issues in $pkg_dir:")
    notes+=("$vet_out")
  fi
fi

# Emit the feedback as additionalContext so the next turn sees it.
if [[ ${#notes[@]} -gt 0 ]]; then
  msg=$(printf 'Formatting/vet feedback on %s:\n' "$path")
  for n in "${notes[@]}"; do msg+=$(printf '%s\n' "- $n"); done
  # JSON-escape the message.
  esc=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}' "$esc"
fi

exit 0
