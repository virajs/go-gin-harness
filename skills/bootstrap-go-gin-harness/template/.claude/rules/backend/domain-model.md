---
description: Rich, mutable domain entities — exported struct, unexported fields, constructor + invariants, identity equality, UUIDv7 in constructor. Auto-loads on internal/domain/**.
paths:
  - "internal/domain/**/*.go"
---

# Domain model (Go)

## The pattern

**Entities are exported structs with unexported fields.** Mutation only via methods that
enforce invariants.

```go
package projects

import (
    "errors"
    "time"
    "github.com/google/uuid"
)

type ID string

func newID() ID { return ID(uuid.Must(uuid.NewV7()).String()) }

type Project struct {
    id        ID
    tenantID  TenantID
    name      string
    archived  bool
    createdAt time.Time
    updatedAt time.Time
    version   uint32      // optimistic concurrency token; matches pgx xmin
}

// Constructor — only way to build a valid Project.
func New(tenant TenantID, name string, now time.Time) (*Project, error) {
    if tenant == "" { return nil, ErrTenantRequired }
    if err := validateName(name); err != nil { return nil, err }
    return &Project{
        id:        newID(),
        tenantID:  tenant,
        name:      name,
        createdAt: now,
        updatedAt: now,
    }, nil
}

// Behaviour — invariants enforced inside.
func (p *Project) Rename(name string, now time.Time) error {
    if p.archived { return ErrProjectArchived }
    if err := validateName(name); err != nil { return err }
    p.name = name
    p.updatedAt = now
    return nil
}

func (p *Project) Archive(now time.Time) {
    p.archived  = true
    p.updatedAt = now
}

// Read-only accessors.
func (p *Project) ID() ID            { return p.id }
func (p *Project) TenantID() TenantID { return p.tenantID }
func (p *Project) Name() string      { return p.name }
func (p *Project) Archived() bool    { return p.archived }
func (p *Project) CreatedAt() time.Time { return p.createdAt }
func (p *Project) UpdatedAt() time.Time { return p.updatedAt }
func (p *Project) Version() uint32   { return p.version }

// Identity equality (compare by id, not struct value).
func (p *Project) Equal(other *Project) bool {
    return other != nil && p.id == other.id
}

// Sentinels — typed errors callers can `errors.Is`.
var (
    ErrTenantRequired   = errors.New("tenant required")
    ErrProjectArchived  = errors.New("project archived")
    ErrInvalidName      = errors.New("invalid project name")
)

func validateName(name string) error {
    if len(name) == 0 || len(name) > 128 { return ErrInvalidName }
    return nil
}
```

## Hard rules

- **Unexported fields.** No `Name string` exported field — only methods.
- **Constructor enforces invariants.** Every invariant rule is checked in `New(...)`. The
  zero value of `Project` is **not** a valid instance.
- **Methods enforce invariants on mutation.** A `Rename` that ignores `Archived` is a bug.
- **UUIDv7 minted in the constructor** (`uuid.NewV7()` — pgx supports UUIDv7 natively; the
  database is not the source of ids).
- **`tenant_id` is mandatory.** Constructors take it; methods don't change it (tenancy is
  immutable per entity).
- **`time.Time` is UTC.** Constructors take `now time.Time` from a clock, never call
  `time.Now()` directly (testability + replayability).
- **Optimistic concurrency token (`Version uint32`)** matches pgx `xmin`-based row versioning.
  Loaded from the row, asserted on update, the DB driver bumps on commit.
- **Identity equality**: an `Equal(*T) bool` method compares ids, not field-by-field.
- **No `panic`** for expected failures. Return typed errors. (`panic` is reserved for
  conditions the code should make impossible.)
- **No imports from `internal/api`, `internal/infra`, third-party drivers.** Domain depends
  only on stdlib + `internal/shared` + the UUID library (if approved).

## Value objects

Plain comparable structs / newtypes:

```go
type TenantID  string
type ProjectID string

// Comparable + immutable money:
type Money struct {
    Amount   int64  // minor units, e.g. cents
    Currency string // ISO 4217, e.g. "USD"
}

func (m Money) Add(other Money) (Money, error) {
    if m.Currency != other.Currency { return Money{}, ErrCurrencyMismatch }
    return Money{Amount: m.Amount + other.Amount, Currency: m.Currency}, nil
}
```

Value objects:
- Are immutable (return new values; don't mutate).
- Implement `Equal` only if Go's `==` doesn't already do the right thing.
- Live in the same domain package as the entity that uses them, OR in `internal/domain/_shared`
  if used across features.

## What we don't do

- **No anemic models.** A struct with public fields and no methods is a DTO, not a domain
  entity. If you find yourself reaching into the entity to mutate, the missing method goes
  on the entity.
- **No base entity types** (`type AggregateRoot struct { ... }`). Each entity declares its
  own `id` / `tenantID` / equality. Domain events are deferred until they're needed.
- **No primary constructors / builders for trivial entities.** A constructor function is
  enough. Add a builder when the parameter count exceeds 5 OR when partial construction is
  legitimate (rare in domain modeling).
- **No `panic` for expected failures.** Tests should never need `require.NotPanics`.
- **No GORM tags / EF-style annotations.** The persistence mapping lives in
  `internal/infra/persistence/<feature>/`, not on the domain struct.
- **No JSON tags on domain structs.** They serialize differently than the API contract;
  use DTOs in the API layer. (A pragmatic exception: a value object that *is* the wire
  format may have JSON tags, but it then lives in `internal/shared`.)

## Loading from the repository

The repository reconstructs the entity using a package-private "rehydrate" constructor that
skips invariant checks (the row was valid when it was persisted):

```go
// Restore — package-private to projects, used only by the repository.
func Restore(id ID, tenant TenantID, name string, archived bool, createdAt, updatedAt time.Time, version uint32) *Project {
    return &Project{
        id: id, tenantID: tenant, name: name, archived: archived,
        createdAt: createdAt, updatedAt: updatedAt, version: version,
    }
}
```

The repository sits in `internal/infra/persistence/projects/` and is the only consumer of
`Restore` — `internal/app/projects` uses `New`.

## Testing the domain

- White-box tests in `package projects` to assert invariant violations return the right
  sentinel error.
- Table-driven tests for every invariant ("empty name", "too-long name", "archived
  project can't rename", etc.).
- Property-based tests (via `testing/quick` or `gopter` if approved) for stateful
  invariants — overkill for early entities, valuable for complex value objects.
