# go-experiment

A production-grade full-stack project, built to learn — not by following tutorials.

Three focuses, in order of weight:

- **Go** — the main line. A backend written by hand, anchored against a production Python stack
  (FastAPI, Celery, SQLAlchemy, Pydantic, uv monorepo): what maps to what, what Go does
  differently, and why.
- **Next.js** — a secondary line. A frontend beside the backend, mirroring a production Next.js +
  pnpm setup elsewhere, so the two can be compared and the open questions from there tested here.
- **Everything around the code** — containers, compose, CI, tooling. The undercurrent that makes
  it production-grade rather than a toy: each of these is built the way a real service would
  need it, not skipped because the app is small.

---

## What This Is

A small HTTP service backed by Postgres and Redis, with a Next.js frontend, built with the same
architectural patterns used in production: hexagonal architecture, layered
domain/application/delivery separation, config from environment, tests alongside code, one
container image per concern.

The point is not the service itself — it is the muscle memory of doing each layer properly. So
the code is written by hand, not generated. External libraries are introduced only when the
standard library (or the framework) genuinely cannot do the job.

---

## Structure

```
backend/              ← the Go module — everything Go lives here
  go.mod, go.sum
  cmd/
    api/
      main.go         ← package main: wires dependencies, starts the HTTP server
    worker/
      main.go         ← package main: the background worker
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
  playground/         ← scratch code for trying things out, not part of the service
  Dockerfile          ← multi-stage build; one file, one target per binary
  Dockerfile.dockerignore
frontend/             ← the JS apps, one folder per app
  nxt-app/            ← Next.js (App Router, TypeScript, Tailwind, src/ layout), port 3002
  Dockerfile          ← pnpm multi-stage build; one runtime target per app
  Dockerfile.dockerignore
package.json          ← pnpm workspace root: pins pnpm and Node via devEngines
pnpm-workspace.yaml   ← declares frontend/* as workspace packages
pnpm-lock.yaml        ← one lockfile for every JS app
docs/                 ← design notes behind the decisions in this repo
docker-compose.yml           ← production shape — prebuilt images, no backing services
docker-compose.override.yml  ← local dev — adds build: + Postgres/Redis, merged in automatically
```

**Why `backend/` and `frontend/`.** The repo root holds what spans the whole project (compose,
docs, the pnpm workspace files); each side of the stack gets its own top-level folder.
`backend/` is a complete Go module on its own — the directory holding `go.mod` is the module
root, so nothing inside it knows or cares where it sits.

The two sides build differently, and it shows in their Docker build contexts. Go needs nothing
outside its own module, so the backend's context is exactly `./backend`. The pnpm workspace's
lockfile lives at the repo root, so the frontend's context has to be the root — the same as a
Python uv workspace would need.

**Ignore files are named after their Dockerfile.** Docker reads a plain `.dockerignore` only from
the context root, which would put the frontend's at the repo root, applying to every build.
BuildKit also accepts `<Dockerfile>.dockerignore` beside the Dockerfile, used in place of the
root one — so each Dockerfile carries its own, and both sides follow one rule. The patterns
still match from the context root. The frontend's is an allowlist: everything is excluded except
the four paths its build reads, so `backend/`, `.git` and the root `.env` can't leak in.

`cmd/` contains `package main` entrypoints — one per runnable process: `cmd/api` and
`cmd/worker`. Each binary only pulls in what it actually imports, so the API image never carries
worker code even though both share `internal/`.

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

Go commands run from `backend/` — `cd backend` first, or stay at the root and pass `-C`
(`go -C backend run ./cmd/api`), which changes directory for that one command. pnpm and Docker
commands run from the repo root, where the workspace and compose files are.

```bash
# --- From backend/ ---

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

# --- From the repo root ---

# Frontend
pnpm install                          # install every JS app from the root lockfile
pnpm --filter=nxt-app run dev         # dev server on :3002
pnpm --filter=nxt-app run build
pnpm --filter=nxt-app add <package>   # add a dependency — use the CLI, don't hand-edit package.json

# Docker
docker compose build          # build all service images
docker compose up             # start all services
docker compose down           # stop and remove containers
docker compose down -v        # also deletes named volumes (wipes DB/Redis data)
docker compose logs           #
```

---

## Reference

- [go-zero-to-hero.md](../engineering-notes/reference/backend/go-zero-to-hero.md) — translation guide from FastAPI + Celery to Go
- [hexagonal-architecture-reference.md](../engineering-notes/reference/named-principles/hexagonal-architecture-reference.md) — the architectural pattern the structure follows
- [Tour of Go](https://go.dev/tour) — do the whole thing before writing much code here
- [Effective Go](https://go.dev/doc/effective_go) — idioms and why they exist
- [Go module layout](https://go.dev/doc/modules/layout) — official reference for `cmd/` + `internal/` layout
