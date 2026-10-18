# Project Structure: Go vs Python

**Status:** Partially validated — the `cmd/` + `internal/` scaffold exists, and "multiple
binaries from one `go.mod`" is demonstrably built (the Dockerfile compiles both `api` and
`worker`). The deeper claim — that `internal/`'s compiler-enforced boundary holds under
refactoring — is untested, because no cross-layer imports exist yet to violate it.

## The Problem

As a codebase grows, you need a way to organize it so that boundaries are clear,
dependencies flow in one direction, and the parts that shouldn't be touched from outside
actually can't be. The question isn't just "where do files go" — it's "what stops someone
from reaching into a part of the codebase they shouldn't, and how confidently can you
refactor knowing that boundary holds."

**The practical trigger is simpler than it sounds.** The moment you're setting up a repo
that you already know isn't going to stay a loose pile of scripts — something that might
actually grow, ship, or outlive the afternoon you started it in — default to scaffolding
it as a **modular monolith**, even as a near-empty stub. Not because you've worked out the
full shape yet, but because:

1. **The stub costs almost nothing.** A `cmd/` entrypoint and a couple of `internal/`
   directories add essentially zero complexity to a project that's still mostly empty.
   You're not fighting an abstraction — you're choosing where things go before there's
   much to put anywhere.
2. **It gives you somewhere to plug things in as you go.** Every new piece of
   functionality lands somewhere that already makes sense, instead of forcing a
   "where does this even go" decision from scratch — under pressure, while you're also
   trying to ship the feature that needed it.

This is the same point `production-grade-software.md` makes about timing in general:
*"decisions made early set the trajectory, and some properties are significantly cheaper
to build in from the start than to retrofit later."* Internal structure is exactly that
kind of decision — cheap as a stub, expensive as a retrofit. Doing it while the codebase
is small costs almost nothing. Doing it after a hundred files have already settled into
whatever shape was convenient at the time is expensive, risky, and the kind of thing teams
keep deferring until it becomes a real problem.

A related — but genuinely separate — question sits alongside this one: when do you split
a single codebase into multiple *deployable services*? That's a question about deployment
topology, not internal structure, and it has a different, more deferrable answer: **start
as a single deployable unit, and split into separate services later, only when you have a
concrete reason to** (team ownership boundaries, independent scaling needs, different
release cadences). Don't conflate the two — "start with one deployable" is a topology
decision you can comfortably defer; "organize it into clear internal modules from day one"
is the structure decision you can't defer cheaply. A modular monolith is what you get when
you make the right call on both: one deployable, internally shaped like the multiple
modules it might someday become.

The interesting differences from here show up one level down: *how* each language lets you
express and enforce those internal module boundaries.

---

## How Python Decomposes It

A Python monorepo is typically organized as a workspace of packages — each with its own
`pyproject.toml`, wired together by a workspace tool (`uv` workspaces, Poetry's monorepo
support, or heavier tools like Pants/Bazel for larger setups):

```
myapp/
├── packages/
│   ├── myapp-core/
│   │   ├── pyproject.toml
│   │   └── src/myapp_core/
│   ├── myapp-api/
│   │   ├── pyproject.toml
│   │   └── src/myapp_api/
│   └── myapp-worker/
│       ├── pyproject.toml
│       └── src/myapp_worker/
└── pyproject.toml   # workspace root
```

Boundaries between packages — "the API package shouldn't import worker internals," "the
core package shouldn't depend on the API layer" — are expressed as **conventions backed
by tooling that checks after the fact**: `import-linter` rules, `ruff`'s import-related
lint rules (e.g. banned imports, `TID` checks), or simply code review discipline. Nothing
in the language itself stops `myapp_api` from doing `from myapp_worker.internal import
something`. The boundary is real in intent, but enforced externally — and only as strictly
as your linting setup catches violations.

---

## How Go Decomposes It

Go's structure conventions are baked into the toolchain rather than layered on top of it:

```
myapp/
├── go.mod                      # single module for the whole repo
├── cmd/
│   ├── api/main.go             # package main — one binary
│   └── worker/main.go          # package main — another binary
└── internal/
    ├── domain/
    ├── application/
    └── infrastructure/
        ├── db/
        └── cache/
```

**`cmd/`** holds binary entrypoints — each subdirectory is its own `package main`,
compiling to its own binary. This is how one module produces multiple deployables (the
`api` and `worker` binaries in this repo's Dockerfile both come from one `go.mod`).

**`internal/`** is where Go genuinely departs from "convention." Any package rooted under
a directory named `internal/` can **only** be imported by code that lives in the tree
rooted at `internal/`'s parent. This isn't a linter rule or a style guide entry — it's
enforced by the `go` compiler itself. Attempting to import `myapp/internal/domain` from
outside `myapp/` is a compile error, full stop. The boundary is not aspirational; it is
load-bearing in the most literal sense — the code will not build if it's violated.

**`pkg/`** (not used in this repo) is the conventional home for code explicitly intended
for external consumption — the opposite signal from `internal/`. It's a more contested
convention; plenty of well-regarded Go projects skip it entirely and keep everything
either in `internal/` or at the module root.

A single `go.mod` at the repo root means the whole tree is one module — one dependency
set, one version, compiled together. (Multiple `go.mod` files in subdirectories are
possible for genuine multi-module setups, but that's a heavier structure than most
monorepos need.)

---

## `internal/` vs Exported Names: Two Independent Gates

It's easy to conflate "is this package importable" with "is this identifier visible" —
they look similar (both are about what outsiders can reach) but they're enforced at
different levels and neither one substitutes for the other.

```
myapp/
├── go.mod
├── cmd/
│   └── api/main.go
└── internal/
    └── auth/
        └── token.go
```

```go
// internal/auth/token.go
package auth

func ValidateToken(t string) bool { ... } // exported: capital V
func hashSecret(s string) string { ... }  // unexported: lowercase h
```

**Gate 1 — `internal/`, checked at import time, based on directory location:**

```go
// cmd/api/main.go — inside myapp/, so this import is allowed
import "myapp/internal/auth"
```

```go
// some other module entirely — this import is a compile error,
// full stop, regardless of what auth exports
import "myapp/internal/auth"
```

**Gate 2 — exported/unexported, checked at identifier resolution, based on capitalization:**

```go
// cmd/api/main.go — the import succeeded (gate 1 passed), but:
auth.ValidateToken(tok) // OK — exported
auth.hashSecret(tok)    // compile error — unexported, invisible outside its own package
```

So `hashSecret` is unreachable from `cmd/api` for the *same reason* it would be
unreachable from a completely unrelated module: capitalization governs identifier
visibility everywhere, with no exception for "but I'm allowed to import this package."
`internal/` only ever makes a package's *exported* surface reachable to a wider or
narrower set of importers — it never reaches inside and changes what's exported.

Put differently: `internal/` answers "can you `import` this path at all?" Capitalization
answers "once imported, what's on the menu?" A package can be internal *and* still have
private helpers that nothing — not even its permitted importers — can touch.

---

## What This Reveals

Python bundles "organize the code into modules" and "enforce that modules don't reach into
each other's internals" as one *intended* outcome, but actually delivers it through two
separate mechanisms: the package/workspace structure (organization) and a linter
(enforcement) — and the second mechanism is optional, configurable, and only as strict as
someone bothered to set it up. You can have a perfectly organized Python monorepo with
zero enforced boundaries; the structure *suggests* the rules, but doesn't *hold* you to
them.

Go collapses these into one mechanism. The directory structure **is** the enforcement —
`internal/` doesn't suggest a boundary, it creates one that the compiler checks on every
build. There's no separate tool to configure, no lint rule to remember to add, no chance
of "we meant to enforce this but the linter config drifted." If the code compiles, the
boundary held.

The practical consequence shows up most clearly when refactoring. In a Python monorepo,
"is `myapp_core` only used where I think it's used?" requires grepping imports or trusting
your linter's coverage. In a Go monorepo, the same question is answered by the compiler:
if `internal/domain` isn't reachable from outside its parent tree, nothing outside that
tree could have imported it — that's not a property you have to verify, it's a guarantee
you already have. This is the same theme that shows up elsewhere in this repo's docs (see
[query-patterns.md](query-patterns.md)'s discussion of sqlc as a "forcing function"): Go
repeatedly turns things Python treats as conventions worth checking into things the
compiler simply won't let you get wrong.

---

## Choice for This Repo

- Single `go.mod` at the root — one module, multiple binaries via `cmd/`
- `internal/` for everything that isn't a binary entrypoint — domain, application, and
  infrastructure layers all live here, with the compiler enforcing that nothing outside
  `myapp/` can import them
- No `pkg/` — nothing in this repo is intended for external consumption, so there's
  nothing that needs the "this is public" signal
- Modular monolith first: one deployable shape (api + worker binaries from one codebase),
  split into separate services only if a concrete reason to do so emerges later
