---
description: Backend security baseline — OWASP API Top 10 mapped to Go/Gin/pgx, secrets, crypto, residency. Auto-loads on Go files.
paths:
  - "**/*.go"
---

# Security baseline

Authoritative refs: `docs/projectStandards/security-standards.md`, `security-backend` skill +
`reference/owasp-go-checks.md`, OWASP API Security Top 10.

## The non-negotiable list

**Authn / Authz (A01/A05)**:
- Tenant derived from server-validated session (JWT claims or session cookie). NEVER trust
  client-supplied `X-Tenant-Id` headers or request body fields.
- Every protected route has explicit auth middleware. No "auth by default" assumption.
- Every object loaded by client-supplied id verifies the caller's tenant owns it (the canon
  IDOR fix).
- Role checks (admin endpoints) are explicit. Default deny on missing role.

**Input validation (A03, A04, A08)**:
- Bind to a DTO, never onto a domain entity (overposting protection).
- Shape validation via `binding:"..."` tags; business via use-case validator; invariants in
  domain.
- Reject unknown JSON fields where the contract is closed: `decoder.DisallowUnknownFields()`
  (stdlib) or configure Gin's binder accordingly.

**Injection (A03)**:
- **SQL**: parameterized queries (pgx `$1`/`$2`/...), via sqlc. NEVER `fmt.Sprintf` into a
  SQL string. Where dynamic SQL is unavoidable (e.g. column whitelist for sorting), validate
  against a hard-coded allow-list:
  ```go
  var allowedSorts = map[string]string{"name": "name", "created": "created_at"}
  col, ok := allowedSorts[req.SortBy]
  if !ok { return ErrInvalidSort }
  ```
- **Command**: `os/exec` with user input only when the args are split (not concatenated into
  a shell string) and the executable is a constant.
- **Template injection**: `text/template` with user-supplied templates is RCE. `html/template`
  for user data in HTML output (auto-escapes).
- **LDAP / NoSQL**: parameterized only, even though we're on Postgres.

**Server-Side Request Forgery (A07)**:
- Outbound HTTP to user-supplied URLs requires an allow-list (or at minimum a deny-list of
  RFC 1918 / link-local / cloud metadata).
- `net.LookupHost` after parsing, validate the resolved IP isn't private — TOCTOU is real
  but better than nothing.
- `http.Client` with a per-request `context.WithTimeout` always; never default.

**Crypto**:
- `crypto/rand` for any security-purpose randomness (tokens, ids, nonces). Never `math/rand`.
- Constant-time compare for secrets: `subtle.ConstantTimeCompare(a, b)`. Plain `==` leaks
  timing.
- Hash algorithms: `bcrypt` / `argon2id` for passwords; `sha256` / `sha512` for integrity
  (NEVER `md5` / `sha1` for security).
- TLS: never `InsecureSkipVerify: true` outside an explicitly-scoped dev tool.
- Encryption keys / secrets in env vars or a secrets manager — never in source / config files.

**Secrets**:
- `.env` and `secrets/**` are read-denied at the permission layer; the `.gitignore` excludes
  them; the security audit greps for hardcoded keys / passwords.
- **Never log secrets, tokens, or PII.** Implement `slog.LogValuer` on credential structs
  to redact. Errors that include secrets in messages are a bug — strip in the error chain.
- Rotate any secret committed in git history; assume it's leaked.

**Resource exhaustion (A04 — Unrestricted Resource Consumption)**:
- Every endpoint has a deadline (`ReadHeaderTimeout`, per-request `context.WithTimeout`).
- Body size limits: `http.MaxBytesReader` or Gin's `MaxMultipartMemory`. Never trust
  `Content-Length`.
- Rate limiting at the edge (load balancer / API gateway) OR a middleware (token bucket)
  on cost-asymmetric endpoints (auth, expensive queries).
- Connection pool sized so a flood doesn't queue requests indefinitely; `pgx` pool
  `MaxConns` set; reject when pool is saturated.

**Logging / audit (A09)**:
- Every privileged action logs: actor + tenant + action + target + result. (Structured slog
  fields; queryable in the log store.)
- Auth failures + 4xx admin endpoints + 5xx critical endpoints page-able / alertable.
- Audit logs include enough context to reproduce, but no secrets / PII.

**Dependency hygiene (A06)**:
- `govulncheck ./...` on every CI run. Findings fail the build.
- `go mod tidy` keeps `go.sum` honest; never edit by hand.
- Every new module requires per-module owner approval (the harness's hard rule).

**Residency** (only if the product requires it):
- All outbound calls (LLM provider, storage, identity) verified to be in-region.
- No third-party analytics / edge functions out-of-region.
- The security audit explicitly checks the diff for new outbound endpoints.

## What `golangci-lint` already enforces

- `gosec`: catches insecure functions (`md5`, `sha1` for security; `math/rand` for tokens;
  hard-coded creds; weak ciphers; bad file perms; insecure HTTP; `unsafe.Pointer`).
- `bodyclose` / `sqlclosecheck` / `rowserrcheck`: prevents resource leaks.
- `noctx`: outbound HTTP without a context (no timeout possible).
- `errcheck`: every error checked (silent failures are a security hole).
- `contextcheck`: context propagation.

## What's review-only

- The tenant_id correctness (it requires understanding the data model; the linter can't see
  it).
- The overposting / DTO binding pattern (the linter sees a struct, not the semantic).
- The "is this URL trusted" SSRF question.
- The "what's the right rate limit for this endpoint" question.

## Incident response

If a vulnerability ships:
1. **Stop the bleed** — feature-flag the affected endpoint off (or block at the gateway).
2. **Confirm scope** — query logs / DB for evidence of exploitation; record exact times.
3. **Fix the root cause**, never the symptom. Add the regression test that would have caught
   it.
4. **Audit related code** — if you found one IDOR, grep for the pattern across other
   endpoints.
5. **Post-mortem**: doc what happened, why, the fix, and the structural change so it doesn't
   recur (e.g. a new linter rule, a new rule file, a new agent check).
