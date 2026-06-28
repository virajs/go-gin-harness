---
description: Record an Architecture Decision Record (ADR) for a non-plan / cross-cutting / mid-flight decision. Writes a numbered file under docs/decisions/. Use when a decision is approved that doesn't belong in an exec-plan's Locked Decisions table.
allowed-tools: Skill, Read, Glob, Grep, Edit, Write, Bash
argument-hint: "<short imperative title>" (e.g. "use sqlc over GORM")
---

The user wants to record an ADR titled: **$ARGUMENTS**.

Invoke the `record-adr` skill. The procedure:

1. Locate `docs/decisions/`. If it doesn't exist in the repo, fall back to creating it
   plus a brief README (the bootstrap template normally ships these — surface a warning
   if absent so the user can investigate).
2. Find the next sequence number (`0001`, `0002`, …).
3. Copy `docs/decisions/0000-template.md` to the new file with a kebab-case slug derived
   from `$ARGUMENTS`.
4. Ask the user for: Status (default `accepted`), Deciders, Related plan/ADR/PRs,
   Context, Decision, Consequences, Alternatives considered. The skill body has the
   full template + style rules.
5. Write the ADR; cross-link from the related plan (if any) or supersede an older ADR
   (if any).
6. Print the new ADR path + a one-paragraph summary.

Do not skip Alternatives — an ADR without them can't answer "why not X" later.
