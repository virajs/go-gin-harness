---
name: push
description: Push the current branch — verify build + tests + lint + vuln are clean and the branch is up to date with remote before pushing. Use when the owner explicitly asks to push.
allowed-tools: Bash, Read, Glob, Grep
---

# Push

The owner has asked you to push the current branch. Verify pre-conditions, surface any
blockers, and (with explicit go-ahead) run `git push`.

## Hard rules (from CLAUDE.md)

- **Per-action approval.** Approval to push this branch ≠ approval to push every future
  branch.
- **Never force-push** without an explicit force-push approval (and never to a shared /
  protected branch).
- **Never push from a dirty working tree** unless the owner says so. Surface uncommitted
  changes first.
- **Never bypass branch protection / hooks.** If the hook says no, ask why first.

## Preflight checks (every time)

Run each and surface the result. STOP and ask the owner if any are dirty / failing.

```bash
# 1. Confirm we're on a branch (not detached HEAD)
git rev-parse --abbrev-ref HEAD

# 2. Working tree clean? (uncommitted changes)
git status --porcelain

# 3. Local ahead of / behind the remote?
git fetch --quiet
git rev-list --left-right --count "@{u}...HEAD"   # behind  ahead

# 4. Build clean
go build ./...

# 5. Lint clean
golangci-lint run

# 6. Tests pass (race detector)
go test -race -count=1 ./...

# 7. Vulnerabilities
govulncheck ./...
```

If any of these fail, surface the failure with the exact command output and ask whether
to continue.

## Behind the remote?

If `git rev-list --left-right --count "@{u}...HEAD"` shows non-zero "behind":

```bash
# Surface to the owner — DO NOT silently pull/rebase
echo "Branch is N commits behind origin. Pull / rebase first?"
```

Don't run a silent rebase or merge — that's a multi-step decision the owner makes.

## Push

```bash
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
```

- `-u` sets the upstream on first push.
- Never use `--force` or `-f` without an explicit "force push" approval from the owner.
- The `protect-commands` hook will gate `git push`; respect the prompt.

## After push

- Report the result (success / hook output / remote URL).
- Surface any branch-protection warnings.
- If the remote has CI hooks, surface the URL where the build / tests run.

## What this skill DOES NOT do

- Create a PR (use `gh pr create` separately; same per-action approval rule).
- Rebase / merge (decision for the owner).
- Squash commits (decision for the owner).
- Bypass any hook or branch protection.
