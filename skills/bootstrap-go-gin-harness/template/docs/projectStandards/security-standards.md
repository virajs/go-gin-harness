# {{ProductName}} — Security standards

> The security baseline. Maps OWASP API Top 10 to Go / Gin / pgx and our specific
> conventions. The rules are in `.claude/rules/security.md` (auto-loaded on `*.go`); this
> doc is the *why* and the program-wide stance.

## The non-negotiable list

1. **Tenant context is server-derived.** Always from JWT claims / session, never from
   request body / header. (See `.claude/rules/backend/tenancy.md`.)
2. **Every object loaded by client-supplied id is tenant-checked** (BOLA defense).
3. **Bind request bodies to DTOs, never to domain entities** (BOPLA / overposting defense).
4. **Parameterized SQL only.** sqlc enforces it; raw pgx uses `$1`/`$2`/... not Sprintf.
5. **`crypto/rand` for security purposes**, never `math/rand`.
6. **Constant-time compare for secrets** (`subtle.ConstantTimeCompare`).
7. **No TLS skip-verify** outside a documented dev tool.
8. **Per-request deadlines + body size limits** on every endpoint.
9. **No secrets in logs / errors / spans.** Implement `slog.LogValuer` on credential
   structs.
10. **`govulncheck` clean** on every CI run.

## OWASP API Top 10 — Go/Gin/pgx mapping

| OWASP | Go specifics | Where it lives in the harness |
|---|---|---|
| **A01 BOLA** | Loading by client-supplied id without tenant check | sqlc query requires `tenant_id` param; repository tested for tenant isolation |
| **A02 Broken Authentication** | JWT verification (exp / iss / aud); session cookie flags (HttpOnly, Secure, SameSite) | `internal/api/middleware/auth.go` |
| **A03 BOPLA** | Binding request body onto a domain entity | DTO request struct in `internal/api/features/<feature>/<usecase>.go`; never `c.ShouldBindJSON(&entity)` |
| **A04 Resource Consumption** | Missing rate limit / timeout / body limit | Middleware: `Timeout`, `MaxBytesReader`; rate limit at gateway or middleware |
| **A05 Function-Level Authz** | Admin endpoints without role check | Per-route middleware (e.g. `RequireRole("admin")`) |
| **A06 Sensitive Flow Abuse** | Asymmetric-cost endpoints without rate limit | Per-endpoint rate-limit middleware |
| **A07 SSRF** | Outbound HTTP to user-supplied URLs | Allow-list of hosts; private-IP rejection; per-request timeout |
| **A08 Misconfiguration** | Permissive CORS, missing security headers | CORS middleware with explicit origin list; security headers middleware |
| **A09 Improper Inventory** | Stale routes, debug endpoints in prod | Route enumeration matches `docs/api/openapi.yaml`; no `pprof.Register` in prod |
| **A10 Unsafe Consumption** | Blindly trusting downstream JSON | Schema validation of upstream responses; explicit timeouts; circuit breaker |

## Cross-cutting concerns

### Tenancy

The most important security boundary in a multi-tenant product. See
`.claude/rules/backend/tenancy.md`. Highlights:

- `tenant_id` on every persisted row.
- Server-derived; never trust the client.
- sqlc query parameter (you can't forget).
- PostgreSQL RLS as backstop.
- **Mandatory tenant isolation test** for every tenant-scoped feature (two tenants,
  assert isolation).

### Secrets

- `.env` / `secrets/**` / `*.pem` / `*.key` blocked at the permission layer
  (`.claude/settings.json` `permissions.deny`).
- `.gitignore` covers env files; `gitleaks` scans on demand.
- **`slog.LogValuer` to redact** sensitive fields:
  ```go
  func (c Credentials) LogValue() slog.Value {
      return slog.GroupValue(
          slog.String("user", c.User),
          slog.String("password", "***"),
      )
  }
  ```
- Errors that contain secrets in messages are bugs; strip at the wrap site.

### Cryptography

- **Random**: `crypto/rand` for tokens, ids, nonces. `math/rand` only for non-security
  purposes (jitter, sampling).
- **Hash**:
  - Passwords → `bcrypt` (cost ≥ 12) or `argon2id`.
  - Integrity → `sha256` / `sha512`.
  - **NEVER `md5` / `sha1`** for security.
- **Constant-time compare**: `subtle.ConstantTimeCompare(a, b)` for secrets. Plain `==`
  leaks timing.
- **TLS**: never `InsecureSkipVerify: true` outside a documented dev tool.

### Resource limits

| Limit | Where |
|---|---|
| `http.Server.ReadHeaderTimeout` | `cmd/api/main.go` — mandatory; `gosec` warns if missing |
| `http.MaxBytesReader` (request body) | Per-handler or middleware-applied |
| `context.WithTimeout` per handler | `internal/api/middleware/timeout.go` |
| pgx pool `MaxConns` | `cmd/api/main.go`; sized to DB + replicas |
| Rate limit (per endpoint or global) | Edge / gateway preferred; in-app middleware for cost-asymmetric endpoints |

### Logging & audit

- Every privileged action logs: actor + tenant + action + target + result. Structured
  slog fields; queryable in the log store.
- Auth failures + 4xx on admin + 5xx critical = page-able / alertable.
- **Audit log != request log.** A separate audit-event table records security-relevant
  events; the request log is for diagnosis.

### Dependency hygiene

- `govulncheck ./...` in CI; findings fail build.
- `go mod tidy` keeps `go.sum` honest.
- **Every new module requires per-module owner approval.**
- Re-run `govulncheck` after `go mod tidy` — even a transitive bump may add findings.

### Data residency (if product requires)

- All outbound calls in-region (model providers, storage, identity).
- No third-party analytics / edge functions out-of-region.
- The security audit explicitly checks the diff for new outbound endpoints.
- `cmd/api/main.go` reads the region from env + asserts at startup.

## What `golangci-lint` already enforces

- `gosec` — most automated patterns (md5/sha1 for security, math/rand for tokens,
  hard-coded creds, weak ciphers, bad file perms, insecure HTTP, `unsafe.Pointer`).
- `bodyclose`, `sqlclosecheck`, `rowserrcheck` — resource leaks (correlated with DoS
  resistance).
- `noctx` — outbound HTTP without context (no timeout possible).
- `errcheck` — silently ignored errors hide security bugs.
- `contextcheck` — context propagation.

If the linter is green and you still suspect an issue, the issue is in a category the
linter doesn't cover — manual review needed (the `security-auditor-backend` agent
handles those).

## Incident response

If a vulnerability ships:

1. **Stop the bleed** — feature-flag off, block at gateway.
2. **Confirm scope** — query logs / DB for evidence of exploitation; record exact times.
3. **Fix the root cause**, never the symptom.
4. **Regression test** — add the test that would have caught it.
5. **Audit related code** — if you found one IDOR, grep for the pattern elsewhere.
6. **Post-mortem** — doc what + why + fix + structural change (new linter, new rule, new
   agent check).

## What's NOT in this doc

- CSRF / XSS specifics — out of scope for a pure JSON API. (If the API ever serves
  HTML, add a frontend security doc.)
- WAF / DDoS — edge concern; the API trusts the gateway to absorb the worst.
- Compliance frameworks (SOC2, ISO 27001) — separate document if applicable.

## See also

- `.claude/rules/security.md` — auto-loaded distillation.
- `.claude/skills/security-backend/SKILL.md` — audit procedure.
- `.claude/skills/security-backend/reference/owasp-go-checks.md` — grep catalog.
- `.claude/skills/govulncheck/SKILL.md` — dependency scanning.
- `.claude/agents/security-auditor-backend.md` — the auditor agent.
