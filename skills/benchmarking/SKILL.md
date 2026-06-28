---
name: benchmarking
description: Write, run, configure, and interpret Go benchmarks with stdlib testing.B + benchstat. Use when proving a performance change, comparing implementations, or validating a hot-path optimization. NOT for profiling (use pprof-profiling) or load testing.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash
---

# Benchmarking

Use `testing.B` from the stdlib + `benchstat` to compare runs. The Makefile already has a
`make bench` target that runs with `-benchmem`, `-count=5`, and writes timestamped output
to `bench/`.

## Writing a benchmark

In a `_test.go` file (same package as the code under test):

```go
package projects

import (
    "testing"
)

func BenchmarkProject_Rename(b *testing.B) {
    // Setup — NOT counted (anything before b.ResetTimer is excluded from N).
    p, _ := New("tenant-x", "initial", time.Now())
    b.ResetTimer()

    for i := 0; i < b.N; i++ {
        _ = p.Rename("new-name", time.Now())
    }
}

// Table-driven benchmark — vary input size / shape.
func BenchmarkProjectList_Build(b *testing.B) {
    sizes := []int{10, 100, 1000, 10_000}
    for _, n := range sizes {
        b.Run(fmt.Sprintf("n=%d", n), func(b *testing.B) {
            input := buildInput(n)
            b.ResetTimer()
            for i := 0; i < b.N; i++ {
                _ = BuildResponse(input)
            }
        })
    }
}
```

**Rules:**
- **`b.ResetTimer()`** after expensive setup. Otherwise the setup time skews per-op.
- **`b.ReportAllocs()`** is implicit when running with `-benchmem`; explicit if you want
  it always on. Allocations are the single most actionable signal.
- **`b.StopTimer()` / `b.StartTimer()`** around inner-loop setup (re-initializing state
  between iterations).
- **Don't compare `b.N` to a fixed number.** `b.N` is iteration count, decided by the
  framework. Loops run for ~1s of wall time.
- **Outputs**: `BenchmarkX-8     1234567   985 ns/op   128 B/op   2 allocs/op`. Latency,
  bytes per op, allocations per op.

## Running

```bash
# All benches, 5 runs of 3s each, with memory stats; tee to a timestamped file.
make bench
# Equivalent:
go test -run=^$ -bench=. -benchmem -benchtime=3s -count=5 ./... | tee bench/$(date +%Y%m%dT%H%M%S).txt

# Filter to one bench:
go test -run=^$ -bench=BenchmarkProject_Rename -benchmem -count=5 ./internal/domain/projects/...
```

## Comparing runs (benchstat)

```bash
go install golang.org/x/perf/cmd/benchstat@latest

# Take baseline:
make bench   # writes bench/<ts1>.txt

# Apply your change, take comparison:
make bench   # writes bench/<ts2>.txt

# Compare:
benchstat bench/<ts1>.txt bench/<ts2>.txt
```

`benchstat` output highlights statistical significance (≥ 95% confidence by default):

```
                       │ baseline.txt │              optimized.txt              │
                       │    sec/op    │   sec/op     vs base                    │
Project_Rename-8         985.0n ± 2%   612.0n ± 1%  -37.87% (p=0.000 n=10)
```

If you see `~` instead of `vs base`, the change is **noise** — the runs are statistically
indistinguishable.

## Interpreting

- **Latency (`ns/op`)** — most important for hot paths.
- **Allocations (`B/op`, `allocs/op`)** — most important for GC pressure (long-tail
  latency).
- **Variance (`± X%`)** — `±0.5%` is excellent; `±5%` is noisy (probably background process
  interference). Run with `-count=10` for noisier benchmarks.

A 10% latency improvement with 2× allocations is rarely worth it (the allocs hit you on
the GC sweep later). Look at the whole picture.

## Microbenchmark traps

- **Benchmarks lie when the compiler optimizes away the work.** Always *use* the result:
  ```go
  var sink []byte
  func BenchmarkXxx(b *testing.B) {
      for i := 0; i < b.N; i++ {
          sink = doWork()
      }
  }
  ```
  The `sink` var prevents dead-code elimination.
- **CPU frequency scaling skews wall time.** On macOS / Linux laptops, plug in and use
  `cpufreq-set` to pin frequency. CI hosts are usually consistent enough.
- **Background load.** Close everything else (Chrome, Slack). Or run on a quiet machine.
- **Run more samples.** `-count=10` is more reliable than `-count=1`; `-count=20` is
  rarely worth the wall time.
- **`b.RunParallel`** for testing under load (pool contention, mutex stress) — different
  story; documents the API but use with intention.

## Profile-while-bench

```bash
go test -run=^$ -bench=BenchmarkProject_Rename -benchmem \
    -cpuprofile=cpu.prof -memprofile=mem.prof \
    ./internal/domain/projects/...

go tool pprof -http=:8080 cpu.prof   # or -png cpu.prof > cpu.png
```

See the `pprof-profiling` skill for what to do with the profile.

## When NOT to microbenchmark

- **The function is called once per startup.** Microbenchmarks lie to you about end-to-end
  cost.
- **The work is mostly I/O.** A benchmark of an I/O function is mostly measuring the
  fake / mock; integration latency under realistic load is what matters.
- **You haven't profiled.** Don't optimize what you haven't measured.

## Where benchmarks live

- **Same package** as the code under test (so they can use internal types).
- **File name**: same `_test.go` file as the unit tests when small; separate `_bench_test.go`
  when many.
- **Don't commit benchmark *output*** (`bench/` is in `.gitignore`); the benchmarks
  themselves yes.

## Reporting a perf result

Include in the PR description:
- The benchmark name(s)
- The baseline vs. optimized benchstat output (paste verbatim)
- The change in `ns/op`, `B/op`, and `allocs/op`, with `p` value
- What changed in the code
- Why it's faster (cite the reason; not "it's faster", but "removes the per-call allocation
  by reusing the buffer")
