---
description: Scaffold the go-gin-harness per-repo governance into the current directory.
allowed-tools: Skill
---

Invoke the `bootstrap-go-gin-harness` skill to install the per-repo half of the harness
(rules, hooks, settings.json, Makefile, .golangci.yml, sqlc.yaml, .editorconfig,
.gitignore, .air.toml, .mcp.json, go.mod, CLAUDE.md, docs/, scripts/, migrations/,
evals/, test/) into the target directory.

Default target: the current directory. Pass a different target as `$ARGUMENTS` if the
user supplied one.

Ask the user for:
- Go module path (e.g. `github.com/acme/orders-api`)
- Product display name (e.g. `OrdersAPI`)
- Multi-tenant? (default Yes)
- Uses LLMs / needs evals? (default Yes)

Then follow the skill's procedure precisely. Refuse to clobber existing harness files.
Print the next-steps block at the end.
