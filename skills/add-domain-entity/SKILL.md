---
name: add-domain-entity
description: Add a domain entity / aggregate / value object — exported struct with unexported fields, NewX constructor minting UUIDv7, invariant-enforcing methods, identity equality, tenant_id immutable. Use when modeling new domain state under internal/domain/.
argument-hint: <Feature>/<Entity> (e.g. Projects/Project)
allowed-tools: Read, Glob, Grep, Edit, Write, MultiEdit, Bash, Skill
---

# Add a domain entity

Source of truth (read first): `.claude/rules/backend/domain-model.md`,
`.claude/rules/backend/tenancy.md`.

## Steps

1. **Decide: entity, value object, or both?**
   - **Entity** — has an identity that persists across mutations (`Project`, `Document`,
     `User`). Identity-equality. Goes in `internal/domain/<feature>/<entity>.go`.
   - **Value object** — defined by its fields; immutable; value-equality (`Money`,
     `EmailAddress`). Plain comparable struct or newtype. Same package as the entity that
     uses it, OR `internal/domain/_shared/` if cross-feature.

2. **Sketch the invariants.** Before writing code, list:
   - What must always be true at construction?  (e.g. `Name != ""`, `Name <= 128 chars`)
   - What must always be true after every mutation? (e.g. `!Archived || ArchivedAt != nil`)
   - What state transitions are valid? (e.g. `Active → Archived` yes, `Archived → Active`
     only by an explicit `Restore` method)
   - What identifies this entity? (UUIDv7? composite key?)
   - Is it tenant-scoped? (almost always yes)

3. **Create the package** `internal/domain/<feature>/`:

   ```go
   // internal/domain/<feature>/<entity>.go
   package <feature>

   import (
       "errors"
       "time"
       "github.com/google/uuid"
   )

   // ID — newtype around uuid string. Allows the type system to distinguish IDs of
   // different entities.
   type ID string

   func newID() ID { return ID(uuid.Must(uuid.NewV7()).String()) }

   type TenantID string

   type <Entity> struct {
       id        ID
       tenantID  TenantID
       // ... unexported fields
       createdAt time.Time
       updatedAt time.Time
       version   uint32  // for optimistic concurrency (matches pgx xmin)
   }

   // New<Entity> — constructor; enforces every invariant.
   func New<Entity>(tenant TenantID, /* args */, now time.Time) (*<Entity>, error) {
       if tenant == "" { return nil, ErrTenantRequired }
       // ... validate every invariant
       return &<Entity>{
           id: newID(), tenantID: tenant,
           // ... fields
           createdAt: now, updatedAt: now,
       }, nil
   }

   // Restore — used by the repository to rehydrate from a DB row. Skips invariant checks
   // because the row was valid when persisted. PACKAGE-PRIVATE intent (lowercase first
   // letter would prevent the persistence package from calling it; instead we keep it
   // exported but document its restricted use).
   func Restore(id ID, tenant TenantID, /* fields */, createdAt, updatedAt time.Time, version uint32) *<Entity> {
       return &<Entity>{ id: id, tenantID: tenant, /* ... */ createdAt: createdAt, updatedAt: updatedAt, version: version }
   }

   // --- accessors ---
   func (e *<Entity>) ID() ID { return e.id }
   func (e *<Entity>) TenantID() TenantID { return e.tenantID }
   // ... one per field

   // --- behaviour ---
   func (e *<Entity>) <Mutation>(arg <T>, now time.Time) error {
       // enforce invariants
       if /* invariant violated */ { return ErrXxx }
       e.field = arg
       e.updatedAt = now
       return nil
   }

   // --- identity equality ---
   func (e *<Entity>) Equal(other *<Entity>) bool { return other != nil && e.id == other.id }

   // --- typed errors ---
   var (
       ErrTenantRequired = errors.New("tenant required")
       ErrInvalidXxx     = errors.New("invalid xxx")
       ErrNotFound       = errors.New("not found")  // sentinel for "no such entity"
   )
   ```

4. **Value objects** (if any) go in the same package or `_shared/`:

   ```go
   type Email string
   func ParseEmail(s string) (Email, error) {
       // validate
       return Email(s), nil
   }
   func (e Email) String() string { return string(e) }
   ```

5. **The repository interface** lives in `internal/app/<feature>/repository.go` — declared
   by the consumer (app layer), implemented by the producer (infra). See the `add-command`
   skill for the interface; this skill is just about the domain.

6. **Write tests** in the same package (`<entity>_test.go`):
   - Constructor: happy path + every invariant violation returns the right typed error.
   - Each behaviour method: happy path + boundary conditions + invalid transitions.
   - Identity equality: same id → equal; different id → not equal.
   - Table-driven where the matrix is big.

7. **Build + lint**:
   ```bash
   gofumpt -w .
   go vet ./internal/domain/...
   go build ./...
   golangci-lint run ./internal/domain/...
   go test -race -count=1 ./internal/domain/<feature>/...
   ```

## Conventions (restated from the rule)

- **Unexported fields.** No public mutable state.
- **Constructor + invariant checks**, returns `(*T, error)`.
- **UUIDv7 minted in the constructor** — not in the DB.
- **`time.Time` is UTC**; constructors take `now time.Time` from a clock.
- **Tenant immutable** — methods don't change `tenantID`.
- **`Restore(...)`** for repository rehydration; skips invariant checks.
- **Typed errors** (`ErrXxx` sentinels) — never `errors.New` at the call site for the same
  failure twice.
- **No imports** from `internal/api`, `internal/infra`, or third-party drivers (except
  `uuid`).

## Value object vs newtype

- `type ProjectID string` (newtype) — when you just want type safety on a string id.
- `type Money struct { Amount int64; Currency string }` (struct) — when there's structure
  + behaviour. Make it comparable (no slices/maps); methods return new values.

## Hard rules

- **`tenant_id` is mandatory.** Constructor takes it; constructor rejects empty.
- **Domain doesn't know about the API or the database.** Pure Go + stdlib (+ uuid).
- **No `panic` for expected failures.** Constructors and methods return `error`.
- **No persistence-only fields on the domain struct** (no `XMin` exposed as a public field,
  no JSON tags, no `gorm:` tags). Persistence concerns live in `internal/infra/persistence/`.
