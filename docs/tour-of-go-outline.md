# Tour of Go — Syntax Syllabus

**This is not a decompose/compare/synthesize doc.** It is a different track. The decompose docs
in this folder ask *"what does production-grade software require?"*; this one asks *"where do I
deliberately practice Go syntax?"* It does not follow the four-part framework in
[README.md](README.md) — it is a syllabus, kept here for visibility.

---

## Outline

- [The principle](#the-principle) — how topics below are tagged
- [Part 1 — Basics](#part-1--basics) — packages, flow control, `defer`
- [Part 2 — More types](#part-2--more-types) — pointers, structs, slices, maps, closures
- [Part 3 — Methods and interfaces](#part-3--methods-and-interfaces) — receivers, interfaces, errors
- [Part 4 — Generics](#part-4--generics) — type parameters
- [Part 5 — Concurrency](#part-5--concurrency) — goroutines, channels, select
- [Insights From Practice](#insights-from-practice) — cross-cutting threads that surfaced while
  working through the above; added as they come up, not written in advance
- [What the playground covers](#what-the-playground-covers)

---

## The principle

A declarative, wiring-and-queries backend drills some constructs constantly and barely touches
others. You write error handling on every call and almost never write a loop. So this syllabus
tags each Tour of Go topic by *where it actually gets practiced*:

- **[Build]** — you will write this constantly just building the service. No kata needed. Where
  Go has a non-obvious best practice it is noted — though often there is little to add, because
  the compiler or the type system forces the idiom rather than leaving it to discipline.
- **[Playground]** — the build under-exercises this. Drill it deliberately in `playground/`.
- **[Skip]** — the Tour teaches it, but it is off-path for this repo. Revisit only if a real
  need shows up.

`playground/` holds only the **[Playground]** items. The full list lives here so the gaps are
visible against the *whole* language surface, not just the parts the build happens to hit.

---

## Part 1 — Basics

**Packages, variables, functions** — **[Build]**
Exported-vs-unexported names, multiple return values, short variable declaration. *Best practice:*
return `(T, error)` with the error last; capitalization is the *only* visibility control — there
is no `private` keyword to forget, and nothing the linter has to enforce.

**Flow control**
- `for` — Go's only loop keyword (plain, as-while, infinite) — **[Playground]**. The single
  biggest everyday gap: wiring code routes almost nothing through an explicit loop.
- `if`, including the short-statement form `if err := f(); err != nil` — **[Build]**. This *is*
  the idiomatic error check; you will write it hundreds of times.
- `switch`, including the no-condition switch and explicit `fallthrough` — **[Playground]**.
  Rarely shows up in wiring.
- `defer` (and LIFO stacking) — **[Build]**. `defer conn.Release()`, `defer rows.Close()`.
  *Best practice:* defer the cleanup on the line right after you acquire the resource.

---

## Part 2 — More types

- **Pointers** — **[Build] + drill once.** `*Config` from `Load()`, pointer receivers on service
  structs. Covered by the build, but worth one deliberate kata because the value-vs-pointer
  distinction is subtle and load-bearing (see the receivers note in Part 3).
- **Structs** — fields, pointers to structs, struct literals — **[Build]**.
- **Arrays & slices** — length/capacity, `append`, the `s[:0]` in-place reuse trick, slices of
  slices — **[Playground]** for the deeper mechanics, **[Build]** for basic use. (The `s[:0]`
  trick already appears in [query-patterns.md](query-patterns.md)'s in-memory filtering.)
- **`range`** — over slices and maps; the index/value pattern — **[Playground]**.
- **Maps** — literals, mutation, the comma-ok `v, ok := m[k]`, *building a map inside a loop* —
  **[Playground]**. Grouping/indexing query results is the real backend use, and it is a loop.
- **Function values & closures** — **[Playground]**. Light in wiring; the cache fetch-function
  (`Cached(ctx, ..., fetchFn)`) is the one natural case.

---

## Part 3 — Methods and interfaces

- **Methods; pointer vs value receivers** — **[Build], but drill in playground.** This is the
  one you flagged: a value receiver gets a *copy* and cannot mutate the original; a pointer
  receiver can. The kata is to *feel* that difference, not just read it. *Best practice:* be
  consistent — if any method needs a pointer receiver, give them all pointer receivers.
- **Interfaces** — implicit satisfaction, interface values, nil interface — **[Build]**. The
  domain/infrastructure seam is interfaces. *Best practice:* define the interface in the
  *consumer* package and keep it small; "accept interfaces, return structs."
- **Type assertions & type switches** — **[Playground]** (small).
- **Errors** — the `error` interface, custom error types, `errors.Is` / `errors.As`, `%w`
  wrapping — **[Build]**. The #1 build idiom. *Best practice:* wrap with `%w`, compare with
  `errors.Is`, never `==` against an error's string.
- **Stringers** — **[Playground]** (small; pairs naturally with the `iota` enum kata).
- **Readers, images** — **[Skip]** for now.

---

## Part 4 — Generics

- **Type parameters; generic types** — **[Playground]**. The `Cached[T any]` helper is the one
  place the build genuinely needs them; everything else (a generic `Map`/`Filter`/`Reduce`) is
  practice the stdlib mostly leaves to you.

---

## Part 5 — Concurrency

**All [Playground].** The worker binary is the only natural home and it is easy to avoid, so this
is the largest deliberate-drill cluster:

- goroutines
- channels; buffered channels; range-and-close
- `select`; the `default` case
- `sync.Mutex`, `sync.WaitGroup`
- `context` cancellation as the *production* concurrency control — this is the bridge back to
  **[Build]**, where `context.Context` is already in every I/O signature.

---

## Insights From Practice

Threads that connect across Parts 2–4, surfaced while working through pointers. Outline-depth
only — a map of how the pieces relate, not deeper coverage of any one of them.

**Pointers are an explicit mutation signal.** Go's default is pass-by-value — a plain `T`
parameter is a *guarantee* the function can't change your variable. `*T` is the visible,
checkable exception. Python has no equivalent: any function can mutate a mutable argument's
contents with zero signature signal. *(Part 2 — Pointers)*

**Three shapes for "validate this struct," and two of them are the same shape:**
1. Pure — `func F(c Config) (Config, error)` — copy in, new value + error out, no mutation.
2. In-place free function — `func F(c *Config) error` — pointer in, mutates through it.
3. In-place method — `func (c *Config) F() error` — identical to #2, different call syntax.

A method is just a function with the receiver as its first parameter; `cfg.F()` is sugar over
`F(&cfg)`. *(Part 3 — Methods)*

**Function types name a callable's *shape*, not its types.** `type ValidatorFunc func(*Config)
error` is a type the same way a `struct{...}` is — it describes "anything callable like this."
This is what lets functions be stored in slices/maps and swapped out (a validator pipeline),
the same mechanism that lets `http.HandlerFunc` make a plain function satisfy the `Handler`
interface. *(Part 3 → bridges to Part 4)*

**Generics and function types are two different axes of abstraction.** Function types vary
*behavior* while holding types fixed (different validators, same `(*Config) error` shape).
Generics vary *types* while holding behavior fixed (`Map` does the same thing for `[]int` and
`[]Institution`). They combine: `func Map[T, U any](s []T, f func(T) U) []U` is generic *and*
takes a function-typed argument — both axes in one signature. *(Part 4 — Generics)*

---

## What the playground covers

Only the **[Playground]** rows above. See [../playground/README.md](../playground/README.md) for
the kata list and the table-driven-test format used to drill them.
