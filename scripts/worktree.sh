#!/usr/bin/env bash
# worktree.sh — dynamic isolated dev environments.
#
# Each feature/bug/improvement gets its own git worktree + isolated runtime:
# a per-worktree Docker Compose Postgres, deterministic collision-free ports, and a
# generated .env. Lets you develop several things in parallel without colliding on the
# working dir, branch, DB, or ports.
#
#   worktree.sh new <slug> [--type feature|bugfix|improvement]  create worktree + branch + env (+ DB if available)
#   worktree.sh ls                                              list active worktrees + their ports
#   worktree.sh env [slug] [--force]                            (re)generate a worktree's .env
#   worktree.sh up [slug]                                       bring up the worktree's Postgres, migrate
#   worktree.sh down [slug]                                     tear down the worktree's Postgres (drops volume)
#   worktree.sh rm <slug> [--delete-branch] [--yes]             remove worktree (+ optional branch)
#   worktree.sh doctor                                          report registry / worktree / volume drift
#
# Runtime-aware: in a repo WITHOUT compose.dev.yaml + a migrate-up target (e.g. the plugin
# repo itself, or a not-yet-scaffolded clone), new/up/down/rm operate WORKTREE-ONLY —
# they create the worktree/branch/.env but skip all Docker/DB steps.
#
# Safety: `rm` refuses a dirty worktree or an unmerged branch unless --yes; it never
# force-removes or hard-deletes a branch without explicit --yes. Destructive steps announce
# themselves first. (Mirrors the `push` skill's per-action-approval philosophy.)
#
# Portable to macOS bash 3.2 + Linux: no associative arrays, no ${var,,}, no flock.

set -euo pipefail

# ---- port bases (index i → these + i) --------------------------------------------------
API_BASE=8080
PG_BASE=55432
OTEL_BASE=44317

# ---- locate the MAIN repo (shared across all worktrees) --------------------------------
# --git-common-dir points at the primary .git for any linked worktree, so the registry is
# shared no matter which worktree we're invoked from.
_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$_common" ]; then echo "worktree.sh: not inside a git repo" >&2; exit 1; fi
case "$_common" in /*) ;; *) _common="$(pwd)/$_common" ;; esac
MAIN_REPO="$(cd "$(dirname "$_common")" && pwd)"
REPO_NAME="$(basename "$MAIN_REPO")"
WT_ROOT="$(dirname "$MAIN_REPO")/${REPO_NAME}-worktrees"
REG_DIR="$MAIN_REPO/.worktrees"
REG="$REG_DIR/registry.tsv"
LOCK="$REG_DIR/.lock"

# ---- small helpers ---------------------------------------------------------------------
die()  { echo "worktree.sh: $*" >&2; exit 1; }
info() { echo "  $*"; }
lc()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'; }

has_db() {
  [ -f "$MAIN_REPO/compose.dev.yaml" ] && grep -qE '^migrate-up:' "$MAIN_REPO/Makefile" 2>/dev/null
}

project_name() {
  local mod
  if [ -f "$MAIN_REPO/go.mod" ]; then
    mod="$(awk '/^module /{print $2; exit}' "$MAIN_REPO/go.mod")"
    [ -n "$mod" ] && { sanitize "$(basename "$mod")"; return; }
  fi
  sanitize "$REPO_NAME"
}

# ---- registry (locked) -----------------------------------------------------------------
_lock() {
  mkdir -p "$REG_DIR"
  local tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 100 ] && die "registry locked >10s (stale lock? inspect $LOCK, remove if the pid in $LOCK/pid is dead)"
    sleep 0.1
  done
  echo $$ > "$LOCK/pid"
}
_unlock() { rm -rf "$LOCK" 2>/dev/null || true; }

_ensure_registry() {
  [ -f "$REG" ] || printf '# index\tslug\tbranch\tworktree_path\tcreated_at\n' > "$REG"
}

index_of() { # slug -> index (empty if absent)
  [ -f "$REG" ] || return 0
  awk -F'\t' -v s="$1" '$1 !~ /^#/ && $2 == s { print $1; exit }' "$REG"
}
row_of() { # slug -> full row
  [ -f "$REG" ] || return 0
  awk -F'\t' -v s="$1" '$1 !~ /^#/ && $2 == s { print; exit }' "$REG"
}

alloc_index() { # slug branch wt_path -> index (allocates lowest free)
  local slug="$1" branch="$2" wt="$3" i=0 used
  _lock; trap '_unlock' EXIT INT TERM
  _ensure_registry
  used="$(awk -F'\t' '$1 !~ /^#/ && NF { print $1 }' "$REG" | sort -n)"
  while printf '%s\n' "$used" | grep -qx "$i"; do i=$((i + 1)); done
  printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$slug" "$branch" "$wt" "$(date -u +%FT%TZ)" >> "$REG"
  _unlock; trap - EXIT INT TERM
  echo "$i"
}
free_index() { # slug
  _lock; trap '_unlock' EXIT INT TERM
  if [ -f "$REG" ]; then
    local tmp="$REG.tmp.$$"
    awk -F'\t' -v s="$1" '$1 ~ /^#/ || $2 != s' "$REG" > "$tmp" && mv "$tmp" "$REG"
  fi
  _unlock; trap - EXIT INT TERM
}

# ---- .env generation -------------------------------------------------------------------
write_env() { # slug index wt_path [--force]
  local slug="$1" idx="$2" wt="$3" force="${4:-}"
  local api=$((API_BASE + idx)) pg=$((PG_BASE + idx)) otel=$((OTEL_BASE + idx))
  local proj cpn envfile
  proj="$(project_name)"
  cpn="${proj}-${slug}"
  envfile="$wt/.env"

  if [ -f "$envfile" ] && [ "$force" != "--force" ]; then
    if ! grep -q 'GENERATED by scripts/worktree.sh' "$envfile" 2>/dev/null; then
      echo "worktree.sh: $envfile exists and looks hand-edited; refusing to overwrite." >&2
      echo "  Re-run with --force to replace it (its current contents are above)." >&2
      return 1
    fi
  fi

  local tmp="$envfile.tmp.$$"
  {
    echo "# GENERATED by scripts/worktree.sh — do not edit; regenerate via 'make env' / worktree.sh env <slug> --force"
    echo "APP_ENV=dev"
    echo "COMPOSE_PROJECT_NAME=${cpn}"
    echo "API_PORT=${api}"
    echo "PORT=${api}"
    echo "OTEL_PORT=${otel}"
    if has_db; then
      echo "PG_HOST_PORT=${pg}"
      echo "POSTGRES_USER=postgres"
      echo "POSTGRES_PASSWORD=postgres"
      echo "POSTGRES_DB=${proj}"
      echo "DATABASE_URL=postgres://postgres:postgres@localhost:${pg}/${proj}?sslmode=disable"
    fi
  } > "$tmp"
  mv "$tmp" "$envfile"
  echo "$envfile"
}

# resolve slug from cwd if omitted (matches the worktree you're standing in)
resolve_slug() {
  local given="${1:-}"
  if [ -n "$given" ]; then echo "$given"; return; fi
  local here; here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$here" ] || die "cannot determine current worktree; pass a slug"
  local slug; slug="$(awk -F'\t' -v p="$here" '$1 !~ /^#/ && $4 == p { print $2; exit }' "$REG" 2>/dev/null || true)"
  [ -n "$slug" ] || die "current dir is not a registered worktree; pass a slug"
  echo "$slug"
}

# ---- docker compose wrapper ------------------------------------------------------------
_compose() { # runs in the worktree dir; args passed through
  ( cd "$1"; shift; docker compose -f compose.dev.yaml --env-file .env "$@" )
}

wait_healthy() { # wt_path
  local cid status i
  cid="$(_compose "$1" ps -q postgres 2>/dev/null || true)"
  [ -n "$cid" ] || { echo "worktree.sh: postgres container not found" >&2; return 1; }
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo starting)"
    [ "$status" = healthy ] && return 0
    sleep 1
  done
  echo "worktree.sh: postgres did not become healthy within 60s" >&2
  return 1
}

# ---- subcommands -----------------------------------------------------------------------
cmd_new() {
  local slug="" type="feature"
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) type="$2"; shift 2 ;;
      -*) die "unknown flag: $1" ;;
      *) [ -z "$slug" ] && slug="$1" || die "unexpected arg: $1"; shift ;;
    esac
  done
  [ -n "$slug" ] || die "usage: worktree.sh new <slug> [--type feature|bugfix|improvement]"
  slug="$(sanitize "$slug")"
  printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9-]*$' || die "invalid slug (use lowercase alnum + hyphen)"

  local prefix
  case "$type" in
    feature) prefix="feat/" ;;
    bugfix)  prefix="fix/" ;;
    improvement) prefix="chore/" ;;
    *) die "invalid --type (feature|bugfix|improvement)" ;;
  esac
  local branch="${prefix}${slug}" wt="$WT_ROOT/$slug"

  [ -n "$(index_of "$slug")" ] && die "slug '$slug' already registered (see: worktree.sh ls)"
  [ -e "$wt" ] && die "worktree path already exists: $wt"
  git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch" && die "branch already exists: $branch"

  mkdir -p "$WT_ROOT"
  echo "Creating worktree '$slug' → $wt (branch $branch)"
  git -C "$MAIN_REPO" worktree add "$wt" -b "$branch" >/dev/null
  local idx; idx="$(alloc_index "$slug" "$branch" "$wt")"
  info "index $idx → API :$((API_BASE + idx))  PG :$((PG_BASE + idx))  OTEL :$((OTEL_BASE + idx))"
  write_env "$slug" "$idx" "$wt" >/dev/null
  info ".env written"

  if has_db; then
    cmd_up "$slug"
  else
    info "worktree-only (no compose.dev.yaml / migrate-up target) — skipping Docker/DB"
  fi
  echo "Done.  cd $wt"
}

cmd_ls() {
  _ensure_registry
  printf '%-4s  %-20s  %-22s  %-6s %-6s %-6s  %s\n' IDX SLUG BRANCH API PG OTEL PATH
  awk -F'\t' '$1 !~ /^#/ && NF' "$REG" | while IFS=$'\t' read -r i slug branch wt _; do
    printf '%-4s  %-20s  %-22s  %-6s %-6s %-6s  %s\n' \
      "$i" "$slug" "$branch" "$((API_BASE + i))" "$((PG_BASE + i))" "$((OTEL_BASE + i))" "$wt"
  done
}

cmd_env() {
  local slug="" force=""
  while [ $# -gt 0 ]; do
    case "$1" in --force) force="--force"; shift ;; *) slug="$1"; shift ;; esac
  done
  slug="$(resolve_slug "$slug")"
  local idx wt; idx="$(index_of "$slug")"; [ -n "$idx" ] || die "unknown slug: $slug"
  wt="$(awk -F'\t' -v s="$slug" '$2 == s {print $4; exit}' "$REG")"
  write_env "$slug" "$idx" "$wt" "$force"
}

cmd_up() {
  local slug; slug="$(resolve_slug "${1:-}")"
  has_db || { info "worktree-only repo — nothing to bring up"; return 0; }
  local wt; wt="$(awk -F'\t' -v s="$slug" '$2 == s {print $4; exit}' "$REG")"
  [ -n "$wt" ] || die "unknown slug: $slug"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  echo "Bringing up Postgres for '$slug'…"
  _compose "$wt" up -d
  wait_healthy "$wt"
  info "postgres healthy; applying migrations"
  ( cd "$wt" && make migrate-up )
  info "up. DATABASE_URL + PORT are in $wt/.env"
}

cmd_down() {
  local slug; slug="$(resolve_slug "${1:-}")"
  has_db || { info "worktree-only repo — nothing to tear down"; return 0; }
  local wt; wt="$(awk -F'\t' -v s="$slug" '$2 == s {print $4; exit}' "$REG")"
  [ -n "$wt" ] || die "unknown slug: $slug"
  echo "Tearing down Postgres for '$slug' (drops its data volume)…"
  _compose "$wt" down -v --remove-orphans
  info "down; volume dropped"
}

cmd_rm() {
  local slug="" del_branch="" yes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete-branch) del_branch=1; shift ;;
      --yes) yes=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [ -z "$slug" ] && slug="$1" || die "unexpected arg: $1"; shift ;;
    esac
  done
  [ -n "$slug" ] || die "usage: worktree.sh rm <slug> [--delete-branch] [--yes]"
  local row; row="$(row_of "$slug")"; [ -n "$row" ] || die "unknown slug: $slug"
  local branch wt
  branch="$(printf '%s' "$row" | cut -f3)"
  wt="$(printf '%s' "$row" | cut -f4)"

  # Safety gate 1 — uncommitted changes
  if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "worktree '$slug' has UNCOMMITTED changes:" >&2
    git -C "$wt" status --short >&2
    [ -n "$yes" ] || die "refusing to remove a dirty worktree; commit/stash first, or pass --yes"
  fi
  # Safety gate 2 — unmerged branch (only relevant if deleting the branch)
  if [ -n "$del_branch" ] && [ -z "$yes" ]; then
    if ! git -C "$MAIN_REPO" branch --merged 2>/dev/null | sed 's/^[+* ]*//' | grep -qx "$branch"; then
      die "branch '$branch' is not merged; refusing --delete-branch without --yes"
    fi
  fi

  echo "Removing worktree '$slug' ($wt)…"
  if has_db && [ -f "$wt/compose.dev.yaml" ]; then
    _compose "$wt" down -v --remove-orphans 2>/dev/null || true
    info "Postgres torn down"
  fi
  if [ -n "$yes" ]; then
    git -C "$MAIN_REPO" worktree remove --force "$wt" 2>/dev/null || true
  else
    git -C "$MAIN_REPO" worktree remove "$wt"
  fi
  free_index "$slug"
  info "worktree removed; index freed"
  if [ -n "$del_branch" ]; then
    if [ -n "$yes" ]; then git -C "$MAIN_REPO" branch -D "$branch" || true
    else git -C "$MAIN_REPO" branch -d "$branch"; fi
    info "branch $branch deleted"
  else
    info "branch $branch kept (pass --delete-branch to remove it)"
  fi
}

cmd_doctor() {
  _ensure_registry
  local issues=0
  echo "worktree.sh doctor — read-only report"
  echo "main repo: $MAIN_REPO"
  echo "registry:  $REG"
  # stale lock
  if [ -d "$LOCK" ]; then
    local pid; pid="$(cat "$LOCK/pid" 2>/dev/null || echo '?')"
    if [ "$pid" != '?' ] && kill -0 "$pid" 2>/dev/null; then
      echo "  lock held by live pid $pid"
    else
      echo "  STALE lock (pid $pid dead) — remove with: rm -rf $LOCK"; issues=$((issues+1))
    fi
  fi
  # registry rows whose worktree path is gone
  awk -F'\t' '$1 !~ /^#/ && NF' "$REG" | while IFS=$'\t' read -r i slug branch wt _; do
    [ -d "$wt" ] || echo "  ORPHAN registry row: '$slug' → $wt missing (free with: worktree.sh rm $slug --yes)"
  done
  # orphaned compose volumes (best-effort)
  if command -v docker >/dev/null 2>&1; then
    local proj; proj="$(project_name)"
    docker volume ls -q 2>/dev/null | grep -E "^${proj}-.*_pgdata$" | while read -r v; do
      echo "  docker volume present: $v (drop stray ones with: docker volume rm $v)"
    done
  fi
  echo "doctor: $issues hard issue(s) flagged above (plus any informational lines)."
}

# ---- dispatch --------------------------------------------------------------------------
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
sub="${1:-}"; shift || true
case "$sub" in
  new)    cmd_new "$@" ;;
  ls)     cmd_ls "$@" ;;
  env)    cmd_env "$@" ;;
  up)     cmd_up "$@" ;;
  down)   cmd_down "$@" ;;
  rm)     cmd_rm "$@" ;;
  doctor) cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand: $sub (try --help)" ;;
esac
