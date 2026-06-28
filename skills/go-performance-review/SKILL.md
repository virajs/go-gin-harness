---
name: go-performance-review
description: Scan Go code for performance anti-patterns — allocations, escape analysis, string/byte misuse, slice/map preallocation, regex, serialization, I/O. Tiered severity, reports findings without editing. Use when auditing hot paths or reviewing allocation-heavy code.
allowed-tools: Read, Glob, Grep, Bash, Skill
---

# Go performance review

Static (audit) skill — reports findings, does not edit. Pair with the `benchmarking` skill
to prove fixes.

## How to audit

1. **Scope to the hot path.** Don't optimize cold paths; the cost (complexity, readability)
   exceeds the benefit. Identify hot paths via traces or a known-hot endpoint.
2. **Walk the categories below.** Each entry has a grep / inspection pattern, a typical
   severity, and a remedy.
3. **For each finding**, report:
   - `file:line` · severity (critical | high | medium | low) · category · anti-pattern · remedy
4. **Don't optimize without measuring.** Recommend a benchmark (the `benchmarking` skill)
   before applying the fix.

## Category 1: Allocations & escapes (highest impact)

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `var s []T; s = append(s, ...)` in a loop | Reallocates; allocates intermediate backing arrays | Preallocate: `s := make([]T, 0, n)` |
| `fmt.Sprintf("%d", x)` in hot path | Allocates + reflection | `strconv.Itoa(x)` (or AppendInt for buffer reuse) |
| `[]byte(s)` / `string(b)` conversions in a loop | Allocates per call | Cache the conversion, or use `unsafe.String` / `unsafe.SliceData` (Go 1.20+) with a justification |
| `map[K]V` returned from a hot function | Escapes to heap | Accept a `map[K]V` argument and fill it |
| Returning `*T` of a stack-allocated struct | Escape to heap | Return `T` by value if small; profile to confirm |
| `errors.New("...")` in a hot path | Allocates on every call | Package-level sentinel: `var ErrFoo = errors.New("foo")` |

How to detect escapes: `go build -gcflags='-m -m' ./... 2>&1 | grep 'escapes to heap'`.

## Category 2: Strings & bytes

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `s + "x" + t` repeated | Allocates a new string each `+` | `strings.Builder` (with `Grow(n)` if size known) or `bytes.Buffer` |
| `strings.Split` then iterate first N | Splits the whole string | `strings.SplitN(s, sep, n)` or a manual `IndexByte` loop |
| `bytes.NewReader(s)` then `io.ReadAll` | Allocates twice | Just `strings.NewReader` |
| `s = strings.Replace(s, "a", "b", -1)` | Allocates each call | Replace once outside the loop, or precompute the mapping |
| `regexp.MustCompile(...)` inside the function | Recompiles per call | Move to a package-level `var` |
| `unicode.IsLetter` in tight loops | Slow per-rune | Specialize for ASCII first if domain allows |

## Category 3: Slices & maps

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `m := map[K]V{}; for ... m[k] = v` | Resizes log(N) times | `m := make(map[K]V, n)` |
| `s = append(s, item)` in a loop with known N | Resize cost | `s = make([]T, 0, n)` then append |
| `slices.Sort` on a slice you control | Slower than `sort.Slice` for tiny n? Negligible — use `slices` |
| Map iteration order matters | Map order is randomized | Sort keys explicitly if order matters |
| `m[k]` returns the zero value on miss | Silent bug | `_, ok := m[k]` when presence matters |

## Category 4: I/O

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `io.ReadAll(body)` of an unknown-size response | Could be huge | `http.MaxBytesReader(...)` before reading |
| Reading line-by-line with `bufio.NewScanner` on a > 64KB line | Scanner default buffer too small | `Scanner.Buffer(buf, max)` |
| `f, _ := os.Open(...)` without `defer f.Close()` | Leaks fd | Defer-close immediately |
| Copying bytes via `io.Copy(w, r)` | Already optimal — uses `io.ReaderFrom` / `WriterTo` if available | (often *not* an anti-pattern; just verify) |
| `os.ReadFile` of a large file in a request | Allocates the whole file | Stream with `bufio.NewReader` |

## Category 5: JSON

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `json.Marshal(map[string]any{...})` | Reflection-heavy + allocates | Marshal a typed struct |
| `json.Unmarshal(body, &m)` into `map[string]interface{}` | Reflection + boxing | Unmarshal into a typed struct |
| Repeating `json.Marshal` of the same value | Allocates per call | Marshal once, reuse the bytes |
| Streaming large JSON with `json.Marshal` | Buffers the whole payload | `json.NewEncoder(w).Encode(...)` |
| `json.Decoder` without `DisallowUnknownFields()` on closed contracts | Silently ignores typos | Use `DisallowUnknownFields()` for strict contracts |

## Category 6: Concurrency

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `go func() { ... }()` without owner | Leak; resource exhaustion under load | `errgroup` or a worker pool |
| `sync.Mutex` held during I/O | Serializes throughput | Capture data, release the lock, then I/O |
| `chan T` with a huge buffer | Hides backpressure | Unbuffered or buffer=1; let the producer back off |
| `time.After` in a hot select loop | Leaks the timer | `time.NewTimer` + `Stop()` |
| `sync.Pool` for small structs | May not pay off | Benchmark first; sometimes the GC handles it cheaper |

## Category 7: Reflection

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `reflect.ValueOf(x).Field(i)` in a hot path | Order-of-magnitude slower than direct access | Codegen (`sqlc`, hand-rolled marshaller) |
| `fmt.Sprintf("%+v", struct)` in a hot path | Reflection-driven | Custom `String()` or a sized buffer |

## Category 8: Hidden costs

| Pattern | Anti-pattern | Remedy |
|---|---|---|
| `deferred` calls in a tight loop | Defer has ~50ns overhead — usually fine, but in a million-iteration loop it adds up | Restructure to one defer at the function level |
| Boxing into `any` for logging in hot paths | Allocates | Type-specific log helpers, or batch-log |
| Large struct copies | `passing T (1KB+) by value` | Pass `*T` |

## Reporting format

```
HIGH  internal/app/projects/list_projects.go:42  allocations  `for _, p := range projs { result = append(result, ToResponse(p)) }` allocates a fresh slice; preallocate with `make([]Response, 0, len(projs))`.
MEDIUM internal/api/middleware/log.go:18         strings      `fmt.Sprintf("%s %s", method, path)` per request; switch to `strings.Builder` (or just `method + " " + path` — Go's compiler optimizes 2-arg `+`).
```

## Severity rubric

- **Critical** — observable production impact (DB / API SLO at risk). Fix immediately.
- **High** — hot-path inefficiency; measurable in benchmarks. Fix this sprint.
- **Medium** — cold-path inefficiency or readability tradeoff. Address opportunistically.
- **Low** — style / idiom. Note, don't urgent.

## When NOT to optimize

- The function is called once per startup. Don't micro-optimize.
- The function is in a test. Tests should be readable; performance is bonus.
- The "optimization" makes the code significantly less readable for < 2x gain. Pass.
- You haven't benchmarked. **Don't optimize what you haven't measured.**

## What this skill DOES NOT do

- Apply fixes (use `benchmarking` to prove, then apply manually or via a separate impl skill).
- Profile (use `pprof-profiling` for that).
- Review correctness (that's `architect-backend`).
