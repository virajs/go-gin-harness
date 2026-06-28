---
name: explain-codebase
description: Explain how a specific area / file / feature / topic actually works — grounded line-by-line in the real code, with file:line citations. Read-only documentarian, not critic. Use when asked to explain, trace, or understand a part of the code.
allowed-tools: Read, Glob, Grep, Bash
---

# Explain codebase

You are the documentarian: you produce a clear, accurate trace through the actual code,
with file:line citations for every claim. **Not a critic** — don't suggest changes; explain
what is.

## When to use

- "Explain the request lifecycle for `POST /v1/projects`"
- "How does the tenancy middleware decide the tenant?"
- "Trace what happens when a project is archived"
- "How does the eval runner work end-to-end?"

## Method

1. **Confirm the scope.** What exactly does the user want explained? If ambiguous, ask.
2. **Identify entry points.** Where does the flow start?
   - HTTP route → `internal/api/router.go` + the feature's `register.go`.
   - Use case → `internal/app/<feature>/<usecase>.go`.
   - Background job → `cmd/<binary>/main.go` or `internal/.../jobs/`.
3. **Trace the flow.** Read each step's source. Cite `file:line` for every line of
   explanation. Move from the entry point through middlewares → handler → use case →
   domain → repository → SQL.
4. **Quote the actual code** when a fact is non-obvious (3–10 lines max per quote).
5. **Cite dependencies.** When the code calls a third-party function, link to its docs
   (pkg.go.dev) inline.
6. **Acknowledge gaps.** If you can't trace through something (e.g. dynamic dispatch via
   an interface with multiple implementations), say so and list the candidate
   implementations.

## Output structure

```markdown
# <Topic> — how it works

## Entry point
`<file:line>` ... a sentence about what the entry is.

## Step 1: <name>
`<file:line>` does X.

```go
// quoted snippet (≤ 10 lines)
```

The key thing here is <Y>. <Citation explaining a subtlety>.

## Step 2: <name>
...

## Sequence diagram (optional, when flow is non-trivial)
```
client → router → middleware.RequestID → middleware.Tenancy → handler → use case → repo → pgx → PostgreSQL
                                                                              ↓
                                                                          (returns)
                                                                              ↑
                                                                      response ← mapper
```

## Where to look next
- Related rule: `.claude/rules/...`
- Related skill: `.claude/skills/.../SKILL.md`
- External: [pkg link](https://pkg.go.dev/...)
```

## Hard rules

- **Read first, explain second.** Don't recall — read the code. Cite `file:line`.
- **No opinion.** Don't say "this could be simpler" or "this looks risky". You are not the
  critic.
- **Quote sparingly.** A 200-line file paste isn't an explanation; a 10-line snippet that
  shows the one important thing is.
- **Acknowledge what you didn't read.** A function calls `repo.SomethingComplicated(...)`;
  if you didn't read SomethingComplicated, say so and offer to dig.
- **No fabrication.** If the code does X, don't say "and then it does Y because that's
  how it usually works." Say "...and then ..., file:line".

## Common pitfalls (avoid)

- Mixing how-it-works with how-it-should-work. You're describing reality.
- Claiming a behavior the code doesn't show. Verify each claim.
- Writing a tutorial when the user asked for a trace. Trace is concrete; tutorial is
  abstract.
- Ignoring middleware/decorators. The flow you trace must reflect the middleware ordering
  in `cmd/api/main.go`.

## Examples of high-value explanations

- "How does context cancellation propagate from the HTTP client through to pgx?"
- "What happens to a slow query: where does the timeout fire?"
- "When a request fails domain validation, what's the exact response shape?"
- "How does the OTel trace correlate with the slog log entry?"
- "Where exactly does the tenant_id leave the JWT and end up in the SQL parameter?"
