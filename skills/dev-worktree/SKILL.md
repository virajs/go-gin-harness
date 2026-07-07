---
name: dev-worktree
description: Create and manage isolated per-worktree dev environments — a git worktree + branch per feature/bug/improvement, each with its own Docker Compose Postgres, deterministic collision-free ports, and generated .env. Use when starting parallel work, or when /exec-plan --isolate is requested. Runtime-aware — worktree-only in repos without compose.dev.yaml (e.g. the plugin repo itself).
argument-hint: <new|ls|env|up|down|rm|doctor> [slug] [--type feature|bugfix|improvement] [--delete-branch] [--yes] [--force]
allowed-tools: Bash, Read, Glob, Grep
---

# Dev worktree — isolated per-task environments

Give every feature/bug/improvement its own git worktree + isolated runtime so several can
be developed in parallel without colliding on the working dir, branch, database, or ports.

All mechanism lives in **`scripts/worktree.sh`** (registry-based port allocation, git
worktree lifecycle, Docker Compose provisioning). This skill is a thin, safety-enforcing
wrapper: pick the script, run the subcommand, interpret the result, surface next steps.

## Locate the script

Prefer the repo-local copy: `"$(git rev-parse --show-toplevel)/scripts/worktree.sh"` — or,
from a linked worktree, the main repo's copy (resolve via `git rev-parse --git-common-dir`).
If it's missing (a repo bootstrapped before this shipped), tell the owner to re-run
`/bootstrap-go-gin-harness` (or copy the script from the plugin template) and stop.

## Runtime-aware behavior

The script auto-detects capability via `has_db()` = (`compose.dev.yaml` present **and** a
`migrate-up` Makefile target exists):

- **Full mode** (bootstrapped Go/Gin repo): `new`/`up` also provision a per-worktree Postgres
  container and run migrations; `rm`/`down` tear it down and drop the volume.
- **Worktree-only mode** (this plugin repo, or a not-yet-scaffolded clone): `new` creates the
  worktree + branch + a minimal `.env` (no DB vars) and skips all Docker steps. The script
  says so — relay that; don't imply a DB was started.

## Subcommands (map `$ARGUMENTS` straight through)

| Command | Effect |
|---|---|
| `new <slug> [--type feature\|bugfix\|improvement]` | Create worktree `../<repo>-worktrees/<slug>` + branch (`feat/`·`fix/`·`chore/`), allocate the lowest-free port index, write `.env`, and (full mode) bring up + migrate the DB. |
| `ls` | List active worktrees with their allocated API/PG/OTEL ports. |
| `env [slug] [--force]` | (Re)generate a worktree's `.env`. Refuses to overwrite a hand-edited `.env` without `--force`. |
| `up [slug]` / `down [slug]` | Start (compose up + wait healthy + migrate) / tear down (compose down **-v**, drops the volume) the worktree's Postgres. No-op in worktree-only mode. |
| `rm <slug> [--delete-branch] [--yes]` | Tear down DB, remove the worktree, free the port index, optionally delete the branch. |
| `doctor` | Read-only: report registry/worktree/volume drift, stale locks, orphaned rows. |

## Safety — mirror the `push` skill's per-action approval

- **`rm` and `down` are destructive.** `rm` drops the worktree's DB **volume** (data is gone)
  and can delete a branch. Before running `rm`, state exactly what will be destroyed
  (worktree path, branch, volume) and get explicit go-ahead — approval to remove one worktree
  is not approval to remove others.
- The script already **refuses** to remove a dirty worktree (`git status --porcelain`) or
  delete an unmerged branch without `--yes`. Do **not** reach for `--yes` to silence that —
  surface the dirty files / unmerged state to the owner and let them decide. Only pass
  `--yes` on explicit instruction.
- Never `--delete-branch` unless asked; a kept branch is recoverable, a deleted one may not be.

## After a command

- `new`: print the `cd <path>`, the allocated ports, and (full mode) the `DATABASE_URL`. The
  server reads `PORT` + `DATABASE_URL` from `.env` (see `.claude/rules/gin-conventions.md`),
  so `make run` / `make dev` in the worktree just work.
- `rm`/`down`: confirm the volume was dropped (the script verifies) so no data lingers.
- Suggest `worktree.sh doctor` if anything looks inconsistent (a hand-deleted worktree dir,
  a leftover volume).
