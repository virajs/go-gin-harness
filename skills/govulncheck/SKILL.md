---
name: govulncheck
description: Scan for known vulnerabilities in the Go binary (stdlib + dependencies). Use as part of CI / before pushing / when adding a dependency.
allowed-tools: Bash, Read, Grep
---

# govulncheck

`govulncheck` reports known CVEs that affect the **reachable code paths** in your binary
— not just "this dep has a CVE", but "this CVE's vulnerable function is called from your
code". The reachability analysis dramatically reduces noise compared to a plain dependency
audit.

## Install

```bash
go install golang.org/x/vuln/cmd/govulncheck@latest
```

## Run

```bash
# Scan everything (stdlib + deps) in the module
govulncheck ./...

# Scan a built binary (for what actually ships)
govulncheck -mode=binary ./bin/api

# JSON output for CI / tooling integration
govulncheck -json ./...
```

## Interpreting

Each finding is `Vulnerability #N: <CVE-ID>`:

```
Vulnerability #1: GO-2024-1234
  Improper handling of HTTP/2 request headers can cause panic.
  More info: https://pkg.go.dev/vuln/GO-2024-1234

  Standard library
    Found in: net/http@go1.24.0
    Fixed in: net/http@go1.24.3
    Example traces found:
      #1: cmd/api/main.go:42:5: main.main calls http.ListenAndServe, which eventually calls net/http.Server.Serve
```

What it tells you:
- **The vulnerability** — what's wrong.
- **The fix** — the version that resolves it (here: upgrade Go to 1.24.3).
- **The reachability trace** — your code at `cmd/api/main.go:42:5` calls the vulnerable
  function.

## Triage

- **Vulnerable + reachable + critical** → fix immediately. Upgrade the dep / Go version
  / patch the code path.
- **Vulnerable + reachable + medium** → fix this sprint. Schedule the upgrade.
- **Vulnerable + reachable + low** → triage. Often the fix is easy (minor version bump);
  do it unless there's a real reason not to.
- **Vulnerable but NOT reachable** (`govulncheck` shows the dep but no traces) → still
  worth noting, but lower priority. Upgrade opportunistically.

## In CI

`make ci` runs `govulncheck ./...`. Findings fail the build. The harness defaults to
"fail on any finding" — adjust in CI config if needed (e.g. allow lows for a transition
window), but document the allow-list in `.golangci.yml` or a separate config.

## Suppression

govulncheck doesn't have a per-finding suppression mechanism. If you can't fix
immediately:
- **Open an issue** with the CVE, the deadline, and the mitigation plan.
- **Document the exception** in `docs/security/known-vulnerabilities.md` with
  expiration date.
- **Re-run on every PR** — when a fix lands, you find out.

## When `govulncheck` says no findings

That's the goal. The check confirms:
- No CVEs in the stdlib version you're building against (Go version is current).
- No CVEs in any third-party module in your dependency graph that touches your code.

It doesn't replace:
- `gosec` / `golangci-lint` — those find code-level security issues (e.g. using `md5` for
  passwords), not dependency CVEs.
- `gitleaks` — finds hardcoded secrets.
- Manual security review of the design — `security-auditor-backend` agent.

## Common scenarios

### Adding a new dependency

Before approving the dep:
1. Read the module's vulnerability history (pkg.go.dev shows vuln tab).
2. After `go get`, run `govulncheck ./...` — any new findings?
3. If yes, justify (or pin a fixed version) before committing.

### Go version upgrade

When the Go release adds a CVE fix, `govulncheck` will surface it (it knows your `go.mod`
go version). Upgrade by editing `go.mod`'s `go 1.X` directive and the toolchain in CI.

### Pre-push check

```bash
make vuln
```

`make vuln` runs `govulncheck ./...`. If clean, you're safe to push.

## Hard rules

- **Run on every CI build.** Failure = blocked merge.
- **Run before every push.** `make vuln` is in the pre-push checklist.
- **Run after every dependency change.** Even a minor bump may pull in transitive deps.
- **Never disable** without an issue + an exception entry.

## What this skill does NOT do

- Apply the fix automatically (you may need a code change as well as a version bump).
- Replace `gosec` / `gitleaks` / SAST tools.
- Provide protection from supply-chain attacks (use `GONOSUMCHECK=off`, signed modules,
  and reviewed deps for that).
