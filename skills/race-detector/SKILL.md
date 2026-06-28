---
name: race-detector
description: Use Go's race detector — what it catches, how to run it, how to interpret a report, how to fix detected races. Use when adding concurrency, debugging a race report, or onboarding to the harness's "race detector on every test" stance.
allowed-tools: Bash, Read, Glob, Grep
---

# Race detector

Go's race detector (`-race`) catches data races at runtime. It's the single most valuable
correctness tool the toolchain ships. **The harness runs it on every test invocation;
never skip it.**

## What it catches

A **data race** occurs when:
- Two goroutines access the same memory location
- At least one access is a write
- The accesses are not synchronized

The race detector instruments memory accesses at compile time and reports races detected
during execution. It catches the races that ACTUALLY happened during the run — it cannot
prove the *absence* of races.

## How to enable

```bash
# All tests
go test -race ./...

# A specific package
go test -race ./internal/app/projects/...

# A specific test
go test -race -run TestCreateProject_Concurrent ./internal/app/projects/

# A binary at runtime (for local debugging; do NOT use in prod — 2-5× slower)
go build -race -o ./bin/api-race ./cmd/api
./bin/api-race
```

The harness's Makefile bakes it in: `make test`, `make ci` run with `-race`.

## Reading a race report

```
WARNING: DATA RACE
Write at 0x00c000110000 by goroutine 7:
  internal/cache.(*Cache).Set()
      internal/cache/cache.go:42 +0x6b
  ...

Previous read at 0x00c000110000 by goroutine 6:
  internal/cache.(*Cache).Get()
      internal/cache/cache.go:30 +0x4c
  ...

Goroutine 7 (running) created at:
  internal/api/handler.(*Server).ProcessRequest()
      internal/api/handler.go:103 +0x12a
```

Read it as:
- **Write at X by goroutine 7** — one access (the write)
- **Previous read at X by goroutine 6** — the racing access (the read)
- **Goroutine 7 created at** — where the writer was spawned
- **Goroutine 6 created at** — where the reader was spawned

The fix is to either:
1. **Synchronize**: protect the access with a mutex / channel.
2. **Restructure**: make the access unnecessary (ownership transfer instead of shared
   state).

## Common race patterns and fixes

### Map without sync
```go
// BAD
var cache = map[string]int{}
func write(k string, v int) { cache[k] = v }
func read(k string) int     { return cache[k] }
// Two goroutines: write + read → DATA RACE on the map.

// GOOD — mutex
var (
    cache  = map[string]int{}
    cacheL sync.RWMutex
)
func write(k string, v int) { cacheL.Lock(); cache[k] = v; cacheL.Unlock() }
func read(k string) int     { cacheL.RLock(); defer cacheL.RUnlock(); return cache[k] }

// Or: sync.Map (specific access patterns; profile before adopting)
// Or: a channel-based actor pattern
```

### Loop variable captured by goroutine (Go < 1.22)
```go
// BAD (pre Go 1.22) — all goroutines see the same `i`, often the last value
for i := 0; i < 10; i++ {
    go func() { handle(i) }()
}

// GOOD — capture explicitly
for i := 0; i < 10; i++ {
    i := i // capture
    go func() { handle(i) }()
}

// OR (Go 1.22+) — the language change scopes the variable per iteration; the bug is fixed.
```

### Closure over a value modified by the caller
```go
// BAD
result := ""
go func() { result = doWork() }()
fmt.Println(result) // race + reads zero value most of the time

// GOOD — channels
ch := make(chan string)
go func() { ch <- doWork() }()
fmt.Println(<-ch)
```

### `sync.WaitGroup.Add` after the goroutine
```go
// BAD — Add races against Wait
wg := sync.WaitGroup{}
go func() {
    wg.Add(1)
    defer wg.Done()
    // ...
}()
wg.Wait()

// GOOD — Add before the goroutine starts
wg.Add(1)
go func() {
    defer wg.Done()
    // ...
}()
wg.Wait()
```

### Reading a slice / map while another goroutine appends
```go
// BAD — append may reallocate; reader sees stale array
var s []int
go func() { s = append(s, 1) }()
fmt.Println(len(s))

// GOOD — protect with mutex, or use a channel to send work
```

## What the race detector DOESN'T catch

- **Logical races** (TOCTOU bugs) — the two accesses are properly synchronized but the
  logic between them assumes invariants that don't hold.
  ```go
  if _, ok := m.Get(k); !ok {
      m.Set(k, v) // another goroutine may have inserted between Get and Set
  }
  ```
  Fix with `LoadOrStore`-style atomic operations.
- **Channel deadlocks** — separate concern; `goroutine` profile via pprof, or
  `goleak.VerifyNone(t)` in tests.
- **Races that didn't happen** during the run. The detector is reporting actual events,
  not a proof of safety.

## Performance

- `-race` slows execution 2–5× and uses ~5–10× more memory.
- Acceptable in tests; never in production.
- For benchmarks, choose: `-race` (correctness) or no flag (true performance). Run both
  separately.

## Hard rules

- **`-race` on every `go test`** in this repo. The Makefile bakes it in.
- **A race detected in CI is a bug**, not a "flaky test". Fix the race.
- **Don't ship `-race` to production.** The runtime overhead is too high.
- **Don't suppress races.** There's no suppression mechanism for `-race`; removing the
  test that exercises the race is forbidden.

## Diagnosing a flaky race

If `go test -race ./...` passes 9/10 times:
- The race happens at low probability; rerun with `-count=10` or `-count=100` to amplify.
- `-shuffle=on` randomizes test order; may expose order-dependent races.
- Add a `t.Parallel()` to the test to increase contention.
- If still flaky, the test is exercising a real race; fix it.

## What this skill does NOT do

- Replace `goroutine` profiles (use `pprof-profiling` for leak diagnosis).
- Cover `testing/synctest` (Go 1.24+) for fully deterministic concurrent tests — worth
  adopting when the API stabilizes.
- Diagnose deadlocks (separate concern; `pprof` goroutine profile + `go test -timeout`).
