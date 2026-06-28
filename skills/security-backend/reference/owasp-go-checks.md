# OWASP API Top 10 — Go/Gin/pgx checklist

A condensed grep / inspection catalog. Pair with the parent `security-backend` SKILL.md.

## A01 — Broken Object Level Authorization (BOLA)

**Pattern**: client supplies an id (`/v1/projects/:id`); the server loads the object
without verifying the caller's tenant owns it.

**Detect:**
```bash
grep -rn 'repo\.\(Load\|Get\|Find\)' internal/ | grep -v _test\.go
```
For each hit, confirm `tenant_id` is in the call — either explicit (`repo.Load(ctx,
tenant, id)`) or via a context propagation that the repo enforces.

**Fix:** always include `tenant_id` in the WHERE clause; the sqlc method's `Params` struct
should require it.

## A02 — Broken Authentication

**Patterns**:
- JWT verification without checking `exp`, `iss`, `aud`.
- Weak signing keys (HMAC with a short secret).
- Session cookies missing `HttpOnly`, `Secure`, `SameSite`.
- `InsecureSkipVerify: true` on a TLS config.

**Detect:**
```bash
grep -rn 'jwt\.Parse' .                        # check it validates claims
grep -rn 'InsecureSkipVerify.*true' .
grep -rn 'SetCookie\|http\.Cookie{' .          # check HttpOnly/Secure/SameSite
```

## A03 — Broken Object Property Level Authorization (overposting + sensitive fields)

**Patterns**:
- `c.ShouldBindJSON(&entity)` binds onto a domain entity directly — request can set
  `tenant_id`, `role`, `is_admin`.
- Response includes fields the client shouldn't see (password hash, internal flags).

**Detect:**
```bash
grep -rn 'ShouldBindJSON' internal/api/        # confirm targets are DTO request structs, not entities
grep -rn '"password\|"hash\|"secret' internal/  # response struct fields
```

## A04 — Unrestricted Resource Consumption

**Patterns**:
- `http.Server` without `ReadHeaderTimeout` / `ReadTimeout` (slowloris).
- Request body without `MaxBytesReader` (memory DoS).
- No per-handler `context.WithTimeout` (slow upstream → request hangs).
- No rate limit on expensive endpoints.

**Detect:**
```bash
grep -rn 'http\.Server{' . | grep -v ReadHeaderTimeout
grep -rn 'io\.ReadAll' . | grep -v MaxBytesReader
grep -rn 'context\.WithTimeout' internal/api/
```

## A05 — Broken Function Level Authorization

**Pattern**: admin endpoints without an explicit role check.

**Detect:**
```bash
grep -rn 'admin\b' internal/api/features/      # confirm role-check middleware applied to the group
```

## A06 — Unrestricted Access to Sensitive Business Flows

**Pattern**: an endpoint with asymmetric cost (login, password reset, mail send, expensive
query) has no rate-limit / CAPTCHA / per-IP throttle.

**Detect:**
```bash
grep -rn '/login\|/reset\|/forgot\|/mail\|/invite\|/export' internal/api/features/
```
For each hit, confirm rate-limit middleware applied.

## A07 — Server-Side Request Forgery (SSRF)

**Pattern**: outbound HTTP / TCP / file URL constructed from user input.

**Detect:**
```bash
grep -rn 'http\.Get\|http\.Post\|http\.NewRequest' internal/    # check the URL source
grep -rn 'net\.Dial\b'                                          # ditto
grep -rn 'os\.Open\b' internal/                                  # path traversal cousin
```

**Fix:**
- Allow-list of hosts; resolve and verify the IP isn't RFC 1918 / link-local / cloud
  metadata (169.254.169.254 specifically — every cloud's metadata endpoint).
- Per-request timeout always.
- Disable redirect to private IPs.

## A08 — Security Misconfiguration

**Patterns**:
- CORS wildcard (`*` origin) with credentials.
- Missing security headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Strict-Transport-Security`).
- Verbose error responses (stack traces, internal paths) leaking in production.
- Debug routes (`/debug/pprof`) exposed in production.

**Detect:**
```bash
grep -rn 'AllowOrigins.*\*\|AllowAllOrigins.*true' .
grep -rn 'pprof\.Register\|pprof\.Handler' .
grep -rn 'panic\(.*\)\|debug\.PrintStack' .     # check error responses
```

## A09 — Improper Inventory Management

**Patterns**: routes that exist but aren't documented; old endpoints kept "just in case";
endpoints that bypass the standard auth middleware.

**Detect:**
```bash
# Compare router registration to OpenAPI / docs
grep -rn 'router\.\(GET\|POST\|PUT\|PATCH\|DELETE\)' internal/api/
# Each registered route should appear in docs/api/openapi.yaml.
```

## A10 — Unsafe Consumption of APIs

**Patterns**: blindly trusting downstream responses; unmarshaling into `interface{}` and
forwarding to the client.

**Detect:**
```bash
grep -rn 'json\.Unmarshal.*interface{}\|map\[string\]any' internal/
```

**Fix**: validate every downstream response against a schema; sanitize before forwarding;
explicit timeout / retry / circuit breaker.

## Cross-cut: Secrets

**Patterns**:
- Hard-coded credentials in source.
- Secrets in logs / errors / spans.
- Secrets in env files committed to git.

**Detect:**
```bash
grep -rnE '(password|secret|api[_-]?key|token)\s*[:=]\s*"[A-Za-z0-9_\-]{16,}"' .
grep -rn '\.env\b' .                            # check .gitignore covers all .env files
git log --all -p | grep -i 'BEGIN .* PRIVATE KEY'  # leaked keys in history
```

## Cross-cut: Tenancy (this product, if multi-tenant)

**Patterns:** see `tenancy.md`. The big ones:
- A query without `WHERE tenant_id = ...`.
- A handler trusting `X-Tenant-Id` header from the request.
- An endpoint without the `Tenancy` middleware.

**Detect:**
```bash
grep -rL ENABLE\ ROW\ LEVEL\ SECURITY migrations/
grep -rn 'c\.GetHeader.*Tenant\|req\.TenantID' internal/api/
grep -rn 'middleware\.Tenancy' internal/api/router\.go    # confirm applied to every protected group
```

## Tools

- `golangci-lint run` (configured with `gosec`)
- `govulncheck ./...`
- (Optional) `gosec -severity high -confidence high ./...`
- (Optional) `gitleaks detect --source=. --no-banner`

## References

- OWASP API Security Top 10: https://owasp.org/API-Security/editions/2023/en/0x00-header/
- Go security docs: https://go.dev/security/
- gosec rules: https://github.com/securego/gosec#available-rules
- govulncheck: https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck
