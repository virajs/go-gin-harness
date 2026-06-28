---
description: Goroutines, channels, contexts, mutexes — when to use which and how not to leak. Auto-loads on any .go file.
paths:
  - "**/*.go"
---

# Concurrency

Authoritative refs: [Go memory model](https://go.dev/ref/mem),
[Effective Go](https://go.dev/doc/effective_go#concurrency).

The single hardest class of bugs in Go is concurrency. The rules below are absolute.

## The first rule — every goroutine has an owner

A goroutine without a clear lifetime is a leak waiting to happen. **Before spawning a
goroutine, answer: who waits for it? what cancels it? what reports its errors?**

Acceptable owners (in descending order of preference):

1. **`errgroup.Group`** — the default for parallel I/O. `g.Go(...)` + `g.Wait()`. Errors
   propagate; context cancels siblings:
   ```go
   g, gctx := errgroup.WithContext(ctx)
   for _, id := range ids {
       id := id // Go 1.22+ no longer needs this, but defensive
       g.Go(func() error { return fetch(gctx, id) })
   }
   if err := g.Wait(); err != nil { return err }
   ```
2. **`sync.WaitGroup`** — when you don't need error propagation. Always `wg.Add(n)` BEFORE
   the loop (race-free), `defer wg.Done()` first thing in the goroutine.
3. **Channel close** — for producer/consumer patterns. The producer closes the channel;
   consumers see EOF via `for v := range ch`. **Only the sender closes; receivers never do.**
4. **Context cancellation + done channel** — for long-running background workers that
   shouldn't return on completion (e.g. a queue poller). Cancel the context to stop them;
   wait on a `doneCh` to confirm exit.

**Unacceptable**: bare `go func() { … }()` in a request handler. If the request is cancelled
or the server is shutting down, the goroutine outlives them. This is the #1 source of memory
leaks under load.

## Context propagation

- **`ctx` is always the first parameter of an I/O function.** Position matters; the
  `contextcheck` and `noctx` linters check it.
- **Never `context.Background()` inside a request path.** Use `c.Request.Context()` (Gin),
  `r.Context()` (stdlib HTTP), or the parent context passed in. `context.TODO()` is OK only
  in code that's being migrated — file an issue.
- **Cancellation cascades.** Cancelling a context cancels everything derived from it. pgx's
  pool respects context cancellation in `Acquire` and `Query`; the stdlib `http.Client`
  respects it; channel `select { case <-ctx.Done(): … }` respects it.
- **Never store a context in a struct.** It belongs in the call chain. `govet` warns.
  Exception: a struct that *represents* an in-flight operation (e.g. a streaming session)
  may hold the request context as a private field with a clear lifetime — document it.
- **`context.WithTimeout`** for per-operation deadlines:
  ```go
  ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
  defer cancel()
  // …
  ```
  Always `defer cancel()` — even on timeout, calling it releases the timer.
- **`context.WithCancel`** when the operation can complete or be aborted. Same `defer cancel()`.
- **`context.WithValue`** for cross-cutting per-request data (request id, tenant id, user
  claims, slog logger). Use a typed key (`type ctxKey int`); never `string`.

## Channels

- **Default to unbuffered.** A buffer is a hint that the producer is faster than the
  consumer — make sure that's actually true and justified.
- **`buffer == 1`** for "signal at most once" semantics.
- **Closing a closed channel panics; sending on a closed channel panics.** Always the sender
  closes. If two goroutines might race to close, you have an ownership bug.
- **`select` with `ctx.Done()` on every blocking channel op in a long-running goroutine**:
  ```go
  select {
  case ch <- v:
  case <-ctx.Done():
      return ctx.Err()
  }
  ```
- **`time.After(...)` leaks the timer** if the channel isn't read. In a `select` it's fine;
  in a hot loop, use `time.NewTimer` + explicit `Stop()`.

## Mutexes

- **`sync.Mutex` for write-heavy / mixed**; **`sync.RWMutex` for read-heavy** with cheap
  reads.
- **Lock for as short as possible.** Read into local vars, release the lock, then process.
- **Embed via pointer or value depending on copyability.** If `T` has a mutex, do NOT pass
  `T` by value (the lock is copied; `govet copylocks` catches it).
- **Document lock order** when a function holds two. Acquire in the documented order
  everywhere; deadlock prevention is by convention.
- **`sync.Once`** for one-time init. Avoid lazy init in request paths if it can run at
  startup.
- **`sync/atomic`** for simple counters / flags; faster than a mutex, surprisingly easy to
  misuse (especially `atomic.Value` with a struct that has a mutex). When in doubt, mutex.

## Maps and slices

- **`map` is not safe for concurrent read+write.** `sync.Map` is for *append-then-rarely-update*
  workloads (specific access patterns the docs spell out). Most of the time, a plain map +
  `RWMutex` is right.
- **Slices** are reference types; copying the header doesn't copy the backing array. Two
  goroutines writing to a slice they both share must synchronize.
- **`append` may reallocate.** A goroutine holding the old backing array sees a stale view;
  another goroutine doing `append` may write past the visible end. Don't share appendable
  slices without sync.

## Race detector — non-negotiable

- `make test` runs with `-race`. `make ci` runs with `-race`. CI runs with `-race`.
- A race detected at any point is a bug — fix it, don't suppress.
- `-race` is slower (~2-5×) and uses more memory; that's the cost. Worth every cycle.

## Goroutine leak detection

- `runtime/pprof` goroutine profile is the diagnostic. The `pprof-profiling` skill walks it.
- **Smoke test for leaks**: at the end of a test, the goroutine count should be the same as
  at the start. `goleak.VerifyNone(t)` is the conventional helper if/when approved as a dep.
- Common leak patterns:
  - `go func() { <- doneCh }()` where `doneCh` is never closed.
  - `select { case <- ch: … case <- ctx.Done(): … }` — but the `ctx` is `context.Background()`.
  - `time.After` in a hot loop without a `case <-ctx.Done()`.
  - HTTP body not closed → connection-pool exhaustion → next goroutine blocks forever.

## `select` patterns

```go
// Fan-in: collect from N channels until ctx cancels.
for {
    select {
    case v := <-chA: handleA(v)
    case v := <-chB: handleB(v)
    case <-ctx.Done(): return ctx.Err()
    }
}

// Send with cancellation.
select {
case out <- v:
case <-ctx.Done():
    return ctx.Err()
}

// Receive with timeout.
select {
case v := <-ch:
    return v, nil
case <-time.After(timeout):
    return zero, ErrTimeout
}
```

## What's NOT in this rule (yet)

- `testing/synctest` (Go 1.24+) for deterministic concurrent tests. Worth adopting when the
  test surface stabilizes — see Go release notes.
