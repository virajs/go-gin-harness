# FAQ — go-gin-harness

A plain-English walk through the questions people actually ask about this harness. No jargon
where a normal word will do. If something here goes stale, the code wins — check the file
paths cited and trust those.

---

## Can I work on several features (or bugs) at the same time without them tripping over each other?

Yes — that's exactly what the **isolated dev environments** feature is for.

Out of the box, a single repo has one working directory, one branch, one local database, and
one `:8080` port. The moment you try to juggle two things at once, they collide. So the harness
gives each piece of work its own little world: a **git worktree** (its own folder + branch), its
own **Docker Postgres**, its own **ports**, and a generated `.env` — all wired up for you.

```bash
/worktree new add-projects        # feature branch feat/add-projects, DB + ports + .env, ready to go
/worktree new fix-tax --type bugfix   # a second one, on different ports — no collision
/worktree ls                      # see what's running
/worktree rm fix-tax              # tidy up when you're done
```

Two servers, two databases, running side by side, no cross-talk. (There's a fuller walkthrough
below.) Requires Docker for the per-worktree database.

> Historical note: earlier versions of the harness did **not** do this — the parallelism was
> only "many sub-agents reading in parallel," not isolated runtimes. Isolated dev environments
> landed in **v0.5.0**.

---

## How do I spin up one of those isolated environments? Walk me through it.

Picture this: you're halfway through a feature and an urgent bug lands. You want both in flight.

**1. Start the feature's environment** (in a bootstrapped repo, with Docker running):

```bash
cd ~/code/orders-api
/worktree new add-projects
```

You'll get a new folder `../orders-api-worktrees/add-projects` on branch `feat/add-projects`,
with Postgres up on `:55432`, migrations applied, and a `.env` written. Then just:

```bash
cd ../orders-api-worktrees/add-projects
make run        # binds :8080, talks to its own DB — it reads PORT + DATABASE_URL from .env
```

**2. The bug comes in — start a second one.** Ports auto-shift so nothing clashes:

```bash
/worktree new fix-tax --type bugfix    # lands on :8081 / DB :55433
```

The `--type` flag just picks the branch prefix: `feature` → `feat/`, `bugfix` → `fix/`,
`improvement` → `chore/`.

**3. Finish the bug, then clean up:**

```bash
/worktree rm fix-tax --delete-branch   # tears down its DB (drops the volume), removes the worktree, frees the ports
```

It won't let you delete a worktree with uncommitted changes or an unmerged branch unless you
really mean it (`--yes`) — it'll show you what you'd lose first. And if things ever look off,
`/worktree doctor` gives you a read-only health report with the exact fix commands.

**Bonus:** `/exec-plan "add projects" --isolate` sets the whole environment up *and* writes the
plan onto that branch — one step.

---

## How do I add a new HTTP endpoint?

Use `/add-endpoint` with a `Feature/UseCase` argument:

```bash
/add-endpoint Projects/CreateProject
```

It expects the *use case* to already exist in the app layer (the endpoint is a thin wrapper) —
if it doesn't, it'll point you at `/add-command` to write it first. From there it:

- creates the feature file (`internal/api/features/projects/create_project.go`) with the request
  struct, response struct, and handler — REPR style, one file per use case;
- registers the route, wiring it into the router if the feature is new;
- picks the right verb + status from the use-case name (`Create*` → `POST` + `201`, `List*` →
  `GET`, and so on);
- **updates the OpenAPI spec in the same change** (that's non-negotiable in this harness);
- runs the build pipeline and writes the tests.

It also respects the project's decisions — if API versioning or the OpenAPI generation approach
haven't been locked yet (their ADRs are still "proposed"), it stops and asks you rather than
guessing.

---

## When I run `/exec-plan`, does it write ADRs for me? When do ADRs actually get created?

No — planning and ADRs are deliberately separate, and ADRs are **always** your call.

Here's the mental model:

- **Decisions you make while planning** go straight into the plan's **Locked Decisions** table
  (e.g. "use cursor pagination, not offset"). The plan is the only file `/exec-plan` writes.
- **ADRs are for a different kind of decision** — the cross-cutting or mid-flight ones that
  don't belong to any single plan: "we deferred rate-limiting until Q4", "we tried X and
  rejected it", "we accept this risk for now".

So when *do* ADRs happen?

1. **During the build** (`/run-impl-loop`), the harness scans what actually happened — the
   deviations the implementer made, the review findings you deferred or accepted-as-risk — and
   **suggests** a one-line `/record-adr "…"` for each thing worth remembering. It never writes
   them for you: *"the owner approves each title and content."*
2. **Any time**, you can just run `/record-adr "<title>"` yourself when a decision is made.

The reasoning is captured in the harness's own first ADR (`docs/decisions/0001-record-adrs.md`):
plans only capture what you knew at planning time; the interesting decisions often show up
mid-flight, and without an ADR they quietly evaporate after the session.

---

## I've got a repo built on an older version of the harness. What do I need to do to use isolated dev environments?

Two things — because this feature lives in both halves of the harness.

**1. Update the plugin** (this gets you the `/worktree` command and `/exec-plan --isolate`):

```bash
claude plugin update go-gin-harness
```

**2. Add the per-repo pieces** — with the upgrade script. These files live *inside your repo*
and were copied in when you first bootstrapped, so an older repo doesn't have them. Heads-up:
**don't** just re-run `/bootstrap-go-gin-harness` — it refuses to overwrite an existing repo,
and forcing it would clobber your customized `Makefile`, `CLAUDE.md`, and rules. Instead run the
idempotent, non-clobbering upgrade script from inside your repo:

```bash
bash ~/.claude/plugins/go-gin-harness/scripts/upgrade-repo.sh . --dry-run   # preview first
bash ~/.claude/plugins/go-gin-harness/scripts/upgrade-repo.sh .             # apply
```

It only touches what's missing — copies `compose.dev.yaml` + `scripts/worktree.sh`, adds the
`Makefile` lines (`-include .env` / `export`, the `DB_URL` fallback, the `env` targets) and the
`.gitignore` entries — and it **won't run on a dirty tree**, so the result is one reviewable
`git diff` you can undo. Run it twice and the second run does nothing.

The one thing it can't do for you is edit your Go code: **`cmd/api` must read `PORT` and
`DATABASE_URL` from the environment** rather than hardcoding `:8080` or a fixed connection
string. The script detects whether you've done this and prints a clear reminder if not — because
this is the bit that actually makes isolation work. If the Makefile doesn't load `.env` and the
app ignores `PORT`/`DATABASE_URL`, you'll get the per-worktree containers but they'll be quietly
ignored (the app still hits the old shared DB on the old port).

A brand-new repo bootstrapped from v0.5.0+ gets all of this automatically — nothing to do.

---

## Will all this flood my context window? Does the plugin stay lean?

It's built to stay lean — keeping the main conversation uncluttered is one of the harness's
design principles, not an afterthought. Four things do the heavy lifting:

1. **The hard work happens in sub-agents, out of your view.** The workflows (`/exec-plan`,
   `/run-impl-loop`, `/architect-review`, …) fan work out to helpers that each read files and run
   tools in *their own* context. Only their **conclusion** comes back — so a review that reads 40
   files doesn't dump 40 files into your chat, it returns a findings list.

2. **What comes back is a tidy summary, not a transcript.** Those helpers are made to return
   structured results (validated JSON), so what crosses back is distilled and bounded.

3. **Skills cost nothing until you use them.** All 30 skills are invisible until invoked — and
   even the little menu of skill names is capped at ~4% of the window
   (`skillListingBudgetFraction`).

4. **Rules load only when relevant.** Each coding rule is tagged with the files it applies to —
   the tenancy rule shows up only when you touch backend Go/SQL, the build rule only when you
   touch the `Makefile`, and so on. You're never carrying the whole rulebook at once.

**The honest caveats:** the plugin can only manage *its own* structure — it can't change how
Claude Code itself handles the transcript or compaction. And anything the main agent does
directly (reading the plan, running `make`, triaging) still lands in the main window; the tidy
isolation only applies to work handed off to sub-agents. So letting the workflows do the fan-out
is lighter than driving a big loop yourself.

---

## Does the harness use git worktrees to run jobs in parallel?

Two different kinds of "parallel" are worth separating:

- **Parallel *thinking*** — yes, and always has. Workflows spin up several sub-agents at once
  (parallel recon readers, parallel reviewers) to cover ground quickly. That's sub-agent
  concurrency in one repo, not worktrees.
- **Parallel *runtimes*** — yes, as of **v0.5.0**, via the isolated dev environments described
  above. Each feature/bug gets its own worktree + database + ports so you can build and run
  several at once.

So: sub-agents for breadth of analysis; worktrees for running multiple things independently.

---

*Questions this doesn't answer? The README has the full mental model, and every claim above is
grounded in the code — follow the file paths and trust those over this page if they ever
disagree.*
