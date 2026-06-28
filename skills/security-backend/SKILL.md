---
name: security-backend
description: Audit the Go/Gin backend for security issues against OWASP API Top 10 mapped to Go/Gin/pgx, plus tenant isolation, secret handling, and (optional) data residency. Use when reviewing backend changes for security, or running a backend security audit. Preloaded by the security-auditor-backend agent.
allowed-tools: Read, Glob, Grep, Bash
---

# Security audit (backend)

Source of truth: `.claude/rules/security.md`, `.claude/rules/backend/tenancy.md`,
`reference/owasp-go-checks.md` (in this skill folder).

## How to audit

1. **Scope to the diff** (or the specified files). Don't re-audit the whole codebase
   unless asked.
2. **Walk the OWASP API Top 10**, mapped to Go/Gin/pgx — see the reference catalog.
3. **Cross-cut every finding** with tenancy + secret handling + residency (if required).
4. **Ground every finding in real code.** `grep`-able evidence. No speculation.
5. **Per finding**: `file:line · severity · category · violation · fix · reference URL`.

## OWASP API Top 10 — Go/Gin/pgx mapping (shortlist)

| OWASP | Go/Gin specifics | Look for |
|---|---|---|
| **A01 BOLA** — Broken Object Level Authz | Loading by client-supplied id without verifying tenant ownership | `repo.Load(ctx, tenant, id)` patterns; if `tenant` doesn't come from context, that's the bug |
| **A02 Auth** | JWT verification, session validation | Weak signing keys, no exp check, no audience check; `tls.Config{InsecureSkipVerify: true}` |
| **A03 BOPLA** — Broken Object Property-Level Authz | Overposting — binding request body onto a domain entity | `c.ShouldBindJSON(&p)` where `p` is `*projects.Project` (NEVER); always bind to a DTO |
| **A04 Unrestricted Resource Consumption** | Missing rate limit / timeout / body limit | `http.MaxBytesReader` absent; `Server.ReadHeaderTimeout` absent; no per-handler `context.WithTimeout` |
| **A05 Broken Function-Level Authz** | Admin endpoints without role check | `router.POST("/admin/...")` with no role-check middleware |
| **A06 Unrestricted Access to Sensitive Business Flows** | Asymmetric-cost endpoints (auth, expensive query, mail send) without rate-limit | grep for endpoints lacking the rate-limit middleware |
| **A07 SSRF** | Outbound HTTP to user-supplied URLs | `http.Get(userURL)` / `http.NewRequest(... userURL)` without allow-list |
| **A08 Misconfig** | Permissive CORS, missing security headers | `r.Use(cors.Default())` with `*` origin; no `X-Frame-Options`, `X-Content-Type-Options` |
| **A09 Improper Inventory** | Stale routes, undocumented endpoints, debug handlers in prod | `pprof.Register(r)` in production; stale `/admin/debug/*` routes |
| **A10 Unsafe Consumption of APIs** | Blindly trusting downstream responses | Unmarshal into `interface{}`; no schema validation of upstream JSON |

## Go-specific security checks

### Injection (A03)
```bash
# SQL injection — Sprintf into raw SQL
grep -rn 'fmt\.Sprintf.*\(SELECT\|INSERT\|UPDATE\|DELETE\)' .

# Command injection — exec.Command with user input concatenated
grep -rn 'exec\.Command' . | grep -v '_test\.go'

# Path traversal — filepath.Join with user input without Clean+prefix check
grep -rn 'filepath\.Join.*req\.' .

# Template injection — text/template parsing user input
grep -rn 'text/template' .
```

### Crypto (A02)
```bash
# Weak hashing for security purposes
grep -rn 'crypto/md5\|crypto/sha1' . | grep -v _test\.go

# math/rand instead of crypto/rand for tokens/ids
grep -rn 'math/rand' . | grep -v _test\.go

# Insecure TLS
grep -rn 'InsecureSkipVerify.*true' .

# Hard-coded secrets
grep -rnE '(password|secret|api[_-]?key)\s*[:=]\s*"[A-Za-z0-9]{16,}"' .
```

### Resource limits (A04)
```bash
# Missing ReadHeaderTimeout
grep -rn 'http\.Server{' . | grep -v 'ReadHeaderTimeout'

# Missing body limit
grep -rn 'io\.ReadAll(req\.Body\|c\.Request\.Body)' . | grep -v MaxBytesReader

# Missing per-handler timeout
grep -rn 'context\.Background' internal/api/    # NEVER in a request path
```

### CORS / headers (A08)
```bash
# Wildcard CORS
grep -rn 'AllowOrigins.*\*\|AllowAllOrigins.*true' .

# Missing security headers middleware
grep -rn 'X-Content-Type-Options\|X-Frame-Options'
```

### Logging (A09)
```bash
# Raw fmt.Printf / log.Printf in production
grep -rn 'fmt\.Printf\|log\.Printf\|log\.Println' internal/

# slog calls that may log secrets
grep -rn 'slog\..*\(token\|password\|api[_-]?key\|secret\)' .
```

## Tenancy-specific checks

```bash
# Queries without tenant scoping (false positive prone; manual review needed)
grep -rn 'SELECT.*FROM.*WHERE' internal/infra/persistence/ | grep -v 'tenant_id'

# Tables without RLS enabled
grep -rL 'ENABLE ROW LEVEL SECURITY' migrations/

# Handlers reading tenant_id from request body
grep -rn 'req\.TenantID\|req\.Tenant\b' internal/api/features/
```

If a handler reads `req.TenantID` from the request, the tenant should still come from
context — the request field is a bug or unused.

## govulncheck

```bash
govulncheck ./...
```

The output lists every CVE that touches a code path in your binary. Findings fail CI; in
the diagnosis, classify:
- **Critical** — RCE / auth bypass / data leak in a reachable path.
- **High** — DoS / info disclosure in a reachable path.
- **Medium** — issue in a reachable but rarely-exercised path.
- **Informational** — issue in unreachable code (vet's "called by"); often suppress with
  a justification.

## Static analysis (already wired)

`golangci-lint` enables:
- `gosec` — most of the above patterns, automated.
- `bodyclose`, `sqlclosecheck`, `rowserrcheck` — resource leaks (not security per se,
  but reliability under load).
- `noctx` — missing context propagation (timeout = DoS resistance).
- `errcheck` — silently ignored errors hide security bugs.

If the linter is green and you still suspect an issue, the issue is in a category the
linter doesn't cover — manual review needed.

## Output

Per finding:
```
CRITICAL  internal/api/features/projects/get_project.go:24  A01-BOLA
  Loading project by id without verifying tenant ownership.
  > p, err := repo.Load(ctx, projectID)              // missing tenant arg
  Fix: pass tenant from context: repo.Load(ctx, tenantFromCtx, projectID).
  Ref:  https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
```

Order by severity (critical first), then by file.

## What this skill does NOT do

- Apply fixes (`security-auditor-backend` reports; impl-build implements).
- Replace `govulncheck` (run it separately).
- Cover frontend-specific concerns (CSRF, XSS) — those are out of scope for the Go API.
