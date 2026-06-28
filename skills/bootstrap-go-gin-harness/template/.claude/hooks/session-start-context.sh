#!/usr/bin/env bash
# session-start-context.sh — SessionStart hook.
#
# Injects the product-context.md content as `additionalContext` so every session starts
# grounded in product vision (why / who / moat), not tech.
#
# Fails OPEN — emits nothing on any error.

set -uo pipefail

proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"
file="$proj/.claude/hooks/context/product-context.md"

[[ ! -f "$file" ]] && exit 0
text="$(cat "$file" 2>/dev/null || true)"
[[ -z "${text// /}" ]] && exit 0

# JSON-escape via python (works on macOS + Linux without jq required).
esc=$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}' "$esc"
exit 0
