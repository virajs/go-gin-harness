---
name: pprof-profiling
description: Profile a Go binary with pprof — CPU, heap, goroutine, mutex, block profiles; reading flame graphs; finding leaks. Use when diagnosing a performance or memory issue. Read-only diagnostic skill.
allowed-tools: Bash, Read, Glob, Grep
---

# pprof profiling

`pprof` is Go's profiling toolchain. It produces five kinds of profile, each answering a
different question.

| Profile | Answers | When to use |
|---|---|---|
| **CPU** | "Where is the program spending CPU time?" | Slow request, high CPU usage |
| **Heap** | "What is allocated / live in memory?" | High RSS, OOM, suspected leak |
| **Goroutine** | "What goroutines exist and where are they parked?" | Suspected leak, deadlock |
| **Mutex** | "What locks are contended?" | High latency under load |
| **Block** | "What blocks are goroutines waiting on?" | Throughput cliff |
| **Allocs** | "What allocation sites contribute over the run?" | GC pressure |

## Two ways to collect

### 1. From the binary at runtime (production / staging)

Mount `net/http/pprof` on a private/admin port:

```go
// Only in non-production OR behind strict auth. Never on a public port.
import _ "net/http/pprof"
go func() {
    if err := http.ListenAndServe("localhost:6060", nil); err != nil {
        slog.Error("pprof listen failed", "err", err)
    }
}()
```

Fetch:
```bash
# CPU — 30-second profile of the running process
curl -s -o cpu.prof http://localhost:6060/debug/pprof/profile?seconds=30

# Heap — snapshot of in-use memory
curl -s -o heap.prof http://localhost:6060/debug/pprof/heap

# Goroutines — list + stacks
curl -s -o goroutines.prof http://localhost:6060/debug/pprof/goroutine

# Mutex / Block — require runtime.SetMutexProfileFraction / SetBlockProfileRate first
curl -s -o mutex.prof http://localhost:6060/debug/pprof/mutex
curl -s -o block.prof http://localhost:6060/debug/pprof/block

# Plain-text goroutine dump (for incident analysis without pprof tools)
curl -s http://localhost:6060/debug/pprof/goroutine?debug=2 > goroutines.txt
```

**Hard rule**: the pprof endpoints are NEVER on the public API port in production. Either
disable them or bind to localhost / a separate admin port behind auth.

### 2. From a benchmark

```bash
go test -run=^$ -bench=BenchmarkFoo -benchmem \
    -cpuprofile=cpu.prof -memprofile=mem.prof -mutexprofile=mutex.prof \
    ./internal/...
```

## Reading

```bash
# Interactive
go tool pprof cpu.prof
# (pprof) top      — top hottest functions
# (pprof) list X   — annotated source around function X
# (pprof) web      — opens a SVG call graph in browser
# (pprof) tree     — top-down call tree

# Web UI (flame graph + tree + source)
go tool pprof -http=:8080 cpu.prof

# PNG flame graph (one-shot)
go tool pprof -png cpu.prof > cpu.png

# Diff two profiles (before vs after a fix)
go tool pprof -base=before.prof after.prof
go tool pprof -http=:8080 -base=before.prof after.prof
```

## CPU profile — interpreting

- **`top`** lists functions by **flat** (self) time and **cum** (cumulative, including
  callees) time. High `flat` = the work is here; high `cum` with low `flat` = the
  caller's choice of work is the cost.
- **Flame graph** — wider = more time. Find the widest function not in stdlib / runtime;
  that's where to optimize.
- Common culprits: JSON marshaling/unmarshaling, regex compilation in a hot path, slice
  re-growth.

## Heap profile — interpreting

```bash
go tool pprof -http=:8080 heap.prof
```

- **In-use space** (default) — what's currently live. Big numbers = current memory cost.
- **Alloc space** — total allocated over the run. Big numbers = GC pressure (lots of
  short-lived garbage).
- A function with high `alloc_space` and low `inuse_space` is allocating a lot but
  releasing quickly — GC pressure, not a leak. Reduce with reuse / pooling / preallocation.
- A function with growing `inuse_space` over time → leak. Compare two heap profiles
  taken minutes apart; the diff is what's not being released.

## Goroutine profile — leak diagnosis

```bash
# Plain-text dump
curl -s http://localhost:6060/debug/pprof/goroutine?debug=2 > g.txt
sort g.txt | uniq -c | sort -rn | head
```

The most common stacks indicate where goroutines are parked. A goroutine count that
grows over time → leak.

Typical leak stacks:
- `select` blocked on `<-ch` where the channel will never be sent on
- HTTP handler blocked on a closed-but-not-released connection
- `time.Sleep` in a worker that no longer needs to wake

### `goleak` for tests
If the `go.uber.org/goleak` module is approved as a dep, add to test files:
```go
func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}
```
Fails the test if extra goroutines remain at exit.

## Mutex / Block profile — contention

Enable in `cmd/api/main.go` (small overhead — keep off by default; enable when diagnosing):
```go
runtime.SetMutexProfileFraction(5)  // sample 1-in-5 events
runtime.SetBlockProfileRate(1)       // sample every blocking event
```

- **Mutex**: top contended mutexes; flame graph shows where the contention happens.
- **Block**: where goroutines wait (channels, mutexes, GC). Identifies the bottleneck.

Common fixes: shorter critical sections, RWMutex for read-heavy workloads, sharding the
lock (multiple maps + a hash mod).

## Diff a fix

Before / after pprof comparisons are the gold standard for "did this optimization help":

```bash
# Before — capture baseline
curl -s -o before.prof http://localhost:6060/debug/pprof/profile?seconds=30

# Apply fix, deploy

# After — capture with the fix
curl -s -o after.prof http://localhost:6060/debug/pprof/profile?seconds=30

# Diff
go tool pprof -http=:8080 -base=before.prof after.prof
```

The graph shows the delta — green = reduced, red = increased.

## Hard rules

- **Never expose pprof on a public port in production.** localhost + admin port + auth.
- **Don't enable mutex/block profiling at full rate** in prod — sampling at 1/N is fine.
- **Mutate nothing during diagnosis.** Profiling is read-only.
- **Cite the profile** in any optimization report (paste the pprof top output verbatim).
- **Always profile BEFORE optimizing.** Don't optimize what you haven't measured.

## What this skill does NOT do

- Trace level diagnostics (`runtime/trace`) — separate concern, useful for goroutine
  scheduling visibility but rarely the right tool.
- Continuous profiling (Pyroscope, Parca, Datadog Profiler) — add when you actually need
  longitudinal trends.
- Apply the fix — see `go-performance-review` for the audit + `benchmarking` for the
  proof loop.
