# go-experiment

Learning Go by building a production-grade backend — not by following tutorials.

The premise: coming from a production Python stack (FastAPI, Celery, SQLAlchemy, Pydantic, uv
monorepo). Every Go concept here is anchored against its Python equivalent. The goal is not to
learn Go in isolation but to understand what maps to what, what the language does differently,
and why.

---

## What This Is

A small HTTP service backed by Postgres, built with the same architectural patterns used in
production Python: hexagonal architecture, layered domain/application/delivery separation, config
from environment, tests alongside code.

The point is not the service itself — it is the muscle memory of writing Go idiomatically. So the
code is written by hand, not generated. External libraries are introduced only when the standard
library genuinely cannot do the job.

---

## Structure

```
cmd/
  api/
    main.go         ← package main: wires dependencies, starts the HTTP server
internal/
  config/
    config.go       ← env vars loaded into a typed struct at startup
    config_test.go  ← tests live next to the code, not in a separate directory
  db/
    db.go           ← pgx pool setup, returned to cmd/api for injection
  handlers/
    handler.go      ← Handler struct holding deps; route methods hang off it
  services/         ← application logic; called by handlers, calls db queries
  models/           ← plain Go structs representing domain concepts
Dockerfile          ← multi-stage build; one file, one target per binary
docker-compose.yml  ← local Postgres + any other backing services
```

`cmd/` contains `package main` entrypoints — one per runnable process. If a worker is added
later, it gets its own `cmd/worker/main.go`. Each binary only pulls in what it actually imports,
so the API image never carries worker code even though both share `internal/`.

`internal/` is shared code that is compiler-enforced private to this module: nothing outside
`github.com/gbabeleda/go-experiment` can import it. Within the module, `cmd/api` imports
`internal/` freely. This is the Go equivalent of `myapp-core` in a Python uv workspace —
same boundary, enforced by the compiler rather than by convention.

Tests live next to the code they test (`config_test.go` alongside `config.go`). `go test ./...`
discovers them automatically. Two styles coexist: `package config` in the test file for
white-box tests (access to unexported identifiers), `package config_test` for black-box tests
(public API only).

---

## Philosophy

Some things are language-invariant. Every backend service needs to validate input, handle HTTP,
manage database connections, deal with errors, and be testable. These problems do not change —
only the mechanism does.

The mistake when learning a new language is one of two opposites: either forcing the new language
to look like the old one (making Go look like FastAPI), or treating everything as foreign and
discarding what you already know. Both are wrong.

The right approach: carry the **what** and the **why**, not the **how**. Layered architecture,
config from environment, dependency injection, small focused interfaces, tests that do not require
running infrastructure — these are language-invariant. The specific mechanism (FastAPI `Depends()`
vs a handler struct, Pydantic vs struct tags, `raise` vs `return err`) is Go's answer to the same
underlying problem.

When something feels unfamiliar, the question to ask is: *what problem is this solving, and how
did Python solve the same problem?* When something feels like it should work the Python way but
doesn't, that is usually Go making a deliberate trade-off worth understanding — not a gap to paper
over.

---

## Approach

**stdlib-first.** `net/http`, `encoding/json`, `log/slog`, `database/sql`, `context`, `sync` —
Go's standard library is production-grade. External dependencies are added only when there is a
concrete gap. Currently: `pgx` for Postgres and `go-redis` for Redis — both are drivers, the
layer between Go code and the backing service. The stdlib has no built-in drivers for either.

**Production structure from day one.** `cmd/` + `internal/` from the first commit. No flat
`main.go` phase that gets refactored later. The architectural decisions are the same ones that
would be made for a real service.

**Write it yourself.** The code in this repo is written by hand to build muscle memory. The
reference docs below explain the why; the repo is where the syntax becomes familiar.

---

## Key Differences From Python

| Python | Go |
|---|---|
| `pyproject.toml` + uv workspace | `go.mod` — one module, one dependency graph |
| `packages/myapp-core/` | `internal/` — compiler-enforced, no install step |
| FastAPI `Depends()` | Handler struct with method receivers, wired in `main.go` |
| Pydantic `BaseModel` | Plain struct with `json:"field"` tags |
| `raise Exception` | `return err` — no exceptions, every fallible function returns `(T, error)` |
| `async` / `await` | Goroutines — `go fn()` is the entire API, no async/sync boundary |
| `mypy` | The compiler — types enforced at build time, not check time |
| `ruff` / `black` | `gofmt` — universal, no config, no debates |
| `pytest` | `go test ./...` — built in, no external runner needed |
| `Optional[str]` | `*string` — nil pointer means absent |

---

## Nice to Know

**Unused imports are a compile error.** Not a warning. If you import a package and don't use it,
the code does not build. `goimports` (run on save via the Go extension) handles this automatically
— it adds missing imports and removes unused ones.

**`:=` vs `var`.** `:=` is short variable declaration — declares and assigns in one step, type
inferred. Only works inside functions. `var` works at package level and is more explicit. Prefer
`:=` inside functions.

**`defer` runs on function return, not block exit.** Unlike Python's `with`, a `defer` statement
runs when the enclosing function returns — not when the block ends. Used for cleanup:
`defer conn.Release()` placed right after acquiring a connection guarantees release regardless of
how the function exits.

**Interfaces are implicit.** A type satisfies an interface by implementing its methods — no
`implements` keyword. This is what makes testing clean: define a small interface for what your
code needs, inject it, swap a test double without any registration.

**`context.Context` is everywhere.** Almost every function that does I/O takes a `context.Context`
as its first argument. It carries deadlines, cancellation signals, and request-scoped values. Pass
it through; do not store it in a struct.

**`go test -race`.** The race detector is built into the test runner. Run it before shipping
anything concurrent.

---

## Common Commands

```bash
# Run without building (development)
go run ./cmd/api
go run ./cmd/worker

# Build binaries
go build ./cmd/api
go build ./cmd/worker

# Run all tests
go test ./...

# Run tests with the race detector — always use before shipping concurrent code
go test -race ./...

# Static analysis
go vet ./...

# Add a dependency
go get github.com/some/package

# Remove unused deps, add missing ones — run after adding/removing imports
go mod tidy

# Docker
docker compose build          # build all service images
docker compose up             # start all services
docker compose down           # stop and remove containers
docker compose down -v        # also deletes named volumes (wipes DB/Redis data)
docker compose logs           #
```

---

## Reference

- [go-zero-to-hero.md](../engineering-notes/backend/go-zero-to-hero.md) — translation guide from FastAPI + Celery to Go
- [hexagonal-architecture-reference.md](../engineering-notes/backend/hexagonal-architecture-reference.md) — the architectural pattern the structure follows
- [Tour of Go](https://go.dev/tour) — do the whole thing before writing much code here
- [Effective Go](https://go.dev/doc/effective_go) — idioms and why they exist
- [Go module layout](https://go.dev/doc/modules/layout) — official reference for `cmd/` + `internal/` layout
