---
description: Create/list/teardown isolated per-worktree dev environments — a git worktree + branch per feature/bug/improvement, each with its own Docker Compose Postgres, deterministic ports, and generated .env. Runtime-aware (worktree-only in repos without compose.dev.yaml).
allowed-tools: Skill, Bash, Read, Glob, Grep
argument-hint: <new|ls|env|up|down|rm|doctor> [slug] [--type feature|bugfix|improvement] [--delete-branch] [--yes]
---

Invoke the `dev-worktree` skill with **$ARGUMENTS** to manage isolated per-task dev
environments (git worktree + per-worktree Docker Postgres + ports + `.env`).

The skill delegates to `scripts/worktree.sh`. Common flows:

- `/worktree new add-projects` — new feature worktree + env (branch `feat/add-projects`)
- `/worktree new fix-race --type bugfix` — bug worktree (branch `fix/fix-race`)
- `/worktree ls` — show active worktrees + their ports
- `/worktree rm add-projects` — tear down + remove (see safety below)

**For `rm`/`down`: these are destructive** — `rm` drops the worktree's database volume and
can delete a branch. Restate exactly what will be destroyed and get explicit confirmation
before running. The script refuses a dirty worktree or an unmerged branch unless `--yes` is
passed — never add `--yes` to bypass that without the owner's say-so.

If `scripts/worktree.sh` is absent (a repo bootstrapped before this shipped), tell the owner
to re-run `/bootstrap-go-gin-harness` and stop.
