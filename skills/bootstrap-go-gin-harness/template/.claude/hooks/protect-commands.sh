#!/usr/bin/env bash
# protect-commands.sh — PreToolUse hook for Bash. Gates destructive shell commands.
#
# DENY (hard-block, catastrophic):
#   - rm -rf /
#   - rm -rf ~ or $HOME
#
# ASK (recoverable-but-destructive, per-action confirmation):
#   - file deletion (rm, rmdir)
#   - git history rewrites (push --force, reset --hard, clean -f)
#   - git governance (add, commit, push) — confirm per the operating model
#   - goose down / migrate down (DB rollback)
#   - SQL destructive (DROP DATABASE|SCHEMA|TABLE, TRUNCATE)
#   - unqualified DELETE FROM / UPDATE (no WHERE)
#   - docker rm / docker volume rm (could blow away test fixtures)
#
# Fails OPEN on any parse error: a hook bug must never hard-block valid work.

set -euo pipefail

# Read the tool call event JSON from stdin (Claude Code passes it in).
event="$(cat 2>/dev/null || true)"
[[ -z "$event" ]] && exit 0

# Extract the command. Be tolerant of jq absence.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$event" | jq -r '.toolInput.command // empty' 2>/dev/null || true)"
else
  cmd="$(printf '%s' "$event" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
fi
[[ -z "$cmd" ]] && exit 0

# Normalize whitespace for regex matching.
norm="$(printf '%s' "$cmd" | tr '\t' ' ' | tr -s ' ')"

send_decision() {
  local decision="$1"; shift
  local reason="$1"; shift
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}' \
    "$decision" "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "\"%s\"", $0}')"
  exit 0
}

# -------- DENY rules (catastrophic) --------
if echo "$norm" | grep -Eqi '\brm[[:space:]]+(-[^[:space:]]*r[^[:space:]]*f|-[^[:space:]]*f[^[:space:]]*r)[[:space:]]+(/|/[[:space:]]|/$|~|\$HOME)'; then
  send_decision "deny" "Catastrophic command blocked: 'rm -rf' targeting / or \$HOME. If you really need to delete a directory, name it explicitly and ask first."
fi

# -------- ASK rules (per-action confirmation) --------
# Unqualified DELETE / UPDATE. POSIX ERE (grep -E) has no negative lookahead, so
# match the verb first, then require that no WHERE clause is present.
if echo "$norm" | grep -Eqi '\b(delete[[:space:]]+from|update[[:space:]]+[a-z_."]+[[:space:]]+set)\b' \
   && ! echo "$norm" | grep -Eqi '\bwhere\b'; then
  send_decision "ask" "Confirm destructive action: SQL DELETE/UPDATE without WHERE — touches every row."
fi

ask_patterns=(
  '\brm[[:space:]]+'                          'file/directory deletion (rm)'
  '\brmdir[[:space:]]+'                        'directory deletion (rmdir)'
  '\bgit[[:space:]]+push\b[^|;&]*--force'      'git push --force (rewrites remote history)'
  '\bgit[[:space:]]+push\b[^|;&]*-f\b'         'git push -f (force push)'
  '\bgit[[:space:]]+reset\b[^|;&]*--hard'      'git reset --hard (discards working tree)'
  '\bgit[[:space:]]+clean\b[^|;&]*-[a-zA-Z]*f' 'git clean -f (removes untracked files)'
  '\bgit[[:space:]]+rebase\b'                  'git rebase (history rewrite)'
  '\bgit[[:space:]]+add\b'                     'git add (staging — confirm per operating model)'
  '\bgit[[:space:]]+commit\b'                  'git commit (confirm per operating model)'
  '\bgit[[:space:]]+push\b'                    'git push (confirm per operating model)'
  '\bgoose\b[^|;&]*[[:space:]]+down(\b|[[:space:]])'  'goose down (DB migration rollback)'
  '\bgoose\b[^|;&]*[[:space:]]+reset'          'goose reset (rolls back all migrations)'
  '\bmigrate\b[^|;&]*[[:space:]]+down'         'migrate down (DB rollback)'
  '\b(DROP|drop)[[:space:]]+(DATABASE|SCHEMA|TABLE|INDEX)\b' 'SQL DROP — destructive'
  '\b(TRUNCATE|truncate)\b'                    'SQL TRUNCATE — wipes table data'
  '\bdocker[[:space:]]+rm\b'                   'docker rm (removes containers)'
  '\bdocker[[:space:]]+volume[[:space:]]+rm\b' 'docker volume rm (removes volumes — data loss)'
  '\bdocker[[:space:]]+system[[:space:]]+prune' 'docker system prune (removes everything)'
)

i=0
while [[ $i -lt ${#ask_patterns[@]} ]]; do
  pat="${ask_patterns[$i]}"
  reason="${ask_patterns[$((i + 1))]}"
  if echo "$norm" | grep -Eqi -- "$pat"; then
    send_decision "ask" "Confirm destructive action: ${reason}."
  fi
  i=$((i + 2))
done

exit 0
