# playground/

Deliberate syntax practice for the constructs the production-grade build under-exercises —
the loops, maps, and concurrency that wiring-and-queries code never makes you write.

**Not shipped.** Not under `cmd/` (no binary) and not under `internal/` (the app never imports
it). It exists only to be written and tested. See
[../docs/tour-of-go-outline.md](../docs/tour-of-go-outline.md) for the full syllabus and why
*these* topics are here and not others.

---

## Format: table-driven tests

Each kata is a function plus a `_test.go` that exercises it with a table of cases:

```go
func TestThing(t *testing.T) {
    tests := []struct {
        name string
        in   []int
        want int
    }{
        {name: "empty", in: nil, want: 0},
        // ...
    }
    for _, tt := range tests {          // <- the most idiomatic Go loop — written on every kata
        t.Run(tt.name, func(t *testing.T) {
            got := Thing(tt.in)
            if got != tt.want {
                t.Errorf("Thing(%v) = %v, want %v", tt.in, got, tt.want)
            }
        })
    }
}
```

Two birds: implementing the kata drills its target construct, and the test harness *itself* is a
`range` loop — so you practice loops on every kata regardless of topic. Run with
`go test ./playground/...`.

**The implementations are yours to write.** The list below is problem statements only — that is
the point of the muscle-memory track.

---

## The katas (gap-first)

### Loops & range
1. **wordcount** — given `[]string`, return `map[string]int` of occurrences. *Drills:* `range`
   over a slice, building a map in a loop, comma-ok.
2. **transpose** — given a `[][]int`, return its transpose. *Drills:* nested loops, slices of
   slices, index arithmetic.
3. **runningmax** — given `[]int`, return `[]int` where each element is the max seen so far.
   *Drills:* index use, accumulation.

### Maps
4. **groupby** — given `[]Institution`, return `map[string][]Institution` keyed by country code.
   *Drills:* the real backend grouping pattern (the thing in-memory filtering becomes once you
   need buckets, not just a filter).
5. **setops** — union and intersection of two `[]string`, using a `map[string]struct{}` as a set.
   *Drills:* map-as-set, the zero-byte `struct{}` value idiom.
6. **invert** — given `map[string]int`, return `map[int][]string`. *Drills:* iterating a map,
   appending into map values.

### Slices (deeper mechanics)
7. **filter-in-place** — filter a `[]T` using the `s[:0]` reuse trick (the one in
   [../docs/query-patterns.md](../docs/query-patterns.md)). *Drills:* length vs capacity, why
   the trick is allocation-free.
8. **chunk** — split `[]T` into chunks of size `n`. *Drills:* `append`, slicing bounds, the
   final short chunk.
9. **dedup** — remove *adjacent* duplicates from a sorted slice, in place. *Drills:* two-index
   walk, in-place mutation.

### Pointer vs value receivers *(the one you flagged)*
10. **counter** — a `Counter` struct with an `Inc()` method. Write it first with a **value**
    receiver and watch the original not change; then switch to a **pointer** receiver and watch
    it work. *Drills:* the whole point — feeling why mutation needs `*T`.
11. **ledger** — a struct that accumulates entries into a slice field via `Add(entry)`. *Drills:*
    pointer receiver for mutation, slice field growth.

### Switch / type switch
12. **classify** — bucket an `int` score into a grade using a no-condition `switch`. *Drills:*
    the `switch { case x < 60: }` form as the clean if/else-if replacement.
13. **describe** — given `any`, return a string describing its dynamic type via a type switch.
    *Drills:* `switch v := x.(type)`.

### Closures & function values
14. **memoize** — wrap a `func(int) int` so repeated calls with the same arg hit a cache.
    *Drills:* closures over a captured map (the kernel of the `Cached` pattern).
15. **middleware** — a `func(HandlerFunc) HandlerFunc` that logs before/after calling the inner
    handler. *Drills:* functions as values, the decorator shape Go uses for HTTP middleware.

### Generics
16. **Map / Filter / Reduce** — generic over `[]T`. *Drills:* type parameters, the functional
    trio the stdlib mostly leaves to you.
17. **Keys / Values** — generic over `map[K]V`. *Drills:* multiple type parameters, `comparable`
    constraint.

### iota / enums
18. **status enum** — a `Status` type with `iota` constants and a `String()` method. *Drills:*
    `iota`, typed constants, Stringer (ties to syllabus Part 3).

### Concurrency *(the largest cluster — the build barely touches it)*
19. **safe-counter** — N goroutines incrementing a shared counter, guarded by `sync.Mutex`.
    *Drills:* goroutines, `sync.Mutex`, `sync.WaitGroup`. (The Tour's classic.)
20. **fan-out** — a pool of worker goroutines consuming jobs from a channel, results collected on
    another. *Drills:* channels, worker pool, `WaitGroup` close coordination.
21. **timeout** — return whichever comes first: a result channel or `time.After(d)`. *Drills:*
    `select`, channels as timeouts.
22. **pipeline** — stage 1 emits on a channel, stage 2 transforms and emits on the next.
    *Drills:* range-and-close, channel-as-stream.
23. **ctx-cancel** — a worker loop that exits cleanly when its `context.Context` is cancelled.
    *Drills:* `select` on `ctx.Done()` — the bridge from build-style `context` plumbing to real
    concurrency control.
