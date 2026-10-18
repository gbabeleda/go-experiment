# Dev Tooling: Go vs Python

**Status:** Exploratory — `gofmt`/compiler/`go vet` are trivially in use, but the load-bearing
claims (sqlc + `golang-migrate` as the database-layer toolchain, `pre-commit` scoped to non-Go
files) have no setup behind them yet.

## The Problem

**Code quality** — catching mistakes before they ship, and keeping the codebase consistent
enough that nobody has to think about formatting. That goal shows up in two places, one
obvious and one less so:

- **The application code itself** — formatting, linting, type-checking. The familiar part.
- **The database layer** — less obviously, "code quality" also has to reach wherever the
  "source of truth" for your schema and queries lives, and whatever tooling keeps it in
  sync with the rest of the codebase. If that source of truth sits outside the host
  language, it's outside the host language's quality tooling too — and needs its own.

---

## How Python Decomposes It

**Code quality** is handled by a stack of tools, increasingly consolidated under `ruff`
(which replaced the old `black` + `isort` + `flake8` combination with one fast Rust-based
tool), plus `mypy` for type checking. `pre-commit` wires these into git hooks so they run
before every commit.

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    hooks:
      - id: ruff
      - id: ruff-format
  - repo: https://github.com/pre-commit/mirrors-mypy
    hooks:
      - id: mypy
```

**The database layer** is also Python code. SQLAlchemy models declare the schema as Python
classes; Alembic generates migrations by diffing those models against the live database.
Queries are built with the ORM or Core expression language — also Python. The schema, the
migrations, and the queries all live inside the same language, and the same tooling
(`ruff`, `mypy`) that lints your application code also covers them, because they *are*
application code.

**IDE config** mirrors the `ruff`-centric stack. One extension (`charliermarsh.ruff`)
handles both linting and formatting for `.py` files, wired via
`editor.codeActionsOnSave` to organize imports and fix-all-fixable issues on save. Pylance
sits alongside it for type-checking/IntelliSense — the `mypy` story from the command line,
surfaced inline. Most of `.vscode/settings.json` exists to tell these extensions which file
types they own.

---

## How Go Decomposes It

**Code quality** needs less external tooling because more is handled by the toolchain
itself: `gofmt` (formatting — non-negotiable, part of the `go` command, not configurable),
the compiler (catches type errors that `mypy` has to bolt onto Python), and `go vet`
(catches suspicious constructs the compiler allows but are usually bugs). `golangci-lint`
exists as an optional meta-linter for the rest — style conventions, unused code, etc. —
but it's additive, not load-bearing the way `ruff` is for Python.

**The database layer is a genuine departure.** This repo uses raw `.sql` files as the
source of truth for schema (migrations via `golang-migrate`/`goose`) and queries (`sqlc`
generates type-safe Go functions from `.sql` query files — see
[query-patterns.md](query-patterns.md) and
[backing-services.md](backing-services.md)). Nothing about the schema or the queries is
expressed as Go structs or Go expressions — it's SQL, and SQL has its own correctness
model: the database engine itself, or `sqlc`'s compile-time check against a live schema.
Go's tooling (`gofmt`, the compiler, `golangci-lint`) has nothing to say about `.sql`
files; they're a different language entirely.

**`pre-commit` still has a role** — not for Go code, but for everything else in the repo
that isn't Go: YAML (`docker-compose.yml`), Markdown, Dockerfiles, `.sql` files. A
polyglot repo benefits from a hook framework even when the primary language doesn't need
one for itself.

**IDE config** is correspondingly thin. One extension (`golang.go`) covers it: `gofmt` as
the formatter, `goimports`-style import organization via `editor.codeActionsOnSave`, and
`gopls` (the language server) supplying type info, navigation, and inline `go vet`
diagnostics. There's no separate "type checker" extension the way Pylance sits next to
`ruff` — `gopls` already does that job, because the compiler's type information *is* the
type checker.

---

## What This Reveals

Python's tooling stack mirrors its "everything is Python" philosophy. Models, migrations,
and queries are Python, so Python's quality tools (`ruff`, `mypy`) cover the database layer
for free, as a side effect of covering application code.

Go's stack looks sparse for the application code itself — and it genuinely is, because the
compiler and `gofmt` absorb what Python needs external tools for. But the more interesting
difference isn't "Go needs fewer linters." It's that a meaningful slice of the system —
schema and queries — isn't expressed in the host language *at all*. That slice has its own
tooling (`sqlc`, migration tools) operating on its own artifacts (`.sql` files), entirely
outside Go's quality-tooling domain.

Going back to Python with this lens: when SQLAlchemy models live in `.py` files, "the
schema is part of the codebase" feels obvious — it's just more Python. The Go approach
makes visible a choice that Python's bundling obscures: the schema *could* be a separate
artifact, owned by separate tooling, with its own lifecycle. That's not a worse design —
it's a different one, and seeing it in Go makes it possible to recognize it as a design
choice rather than a given.

### What Doesn't Change

Not everything here is "Go does X, Python does Y." A chunk of the tooling surface is the
same artifact, in the same format, regardless of which language sits at the center:

- **YAML** — `docker-compose.yml`, CI workflows, and any future `pre-commit` config are
  YAML whether the app is Go or Python. Same formatter (`redhat.vscode-yaml`), same
  indentation footguns, same schema-validation concerns.
- **Dockerfiles** — same `docker.docker` extension/formatter either way. The *shape* of
  the Dockerfile differs (see [containerization.md](containerization.md)), but the tooling
  that edits it doesn't care what's inside.
- **Raw SQL** — this repo's schema and queries live in `.sql` files (see *Choice for This
  Repo*). SQL has its own syntax, formatting conventions, and linting concerns, independent
  of the host language. A Python repo that also chose raw SQL over an ORM would face the
  exact same "what formats my `.sql` files" question — this isn't a Go-specific tradeoff,
  it's a consequence of the schema-as-SQL choice itself.
- **Editor-hygiene baseline** — `editor.rulers`, `files.trimTrailingWhitespace`,
  `files.insertFinalNewline`, `editor.formatOnSave`, autosave settings. These lines are
  identical, verbatim, between this repo's `.vscode/settings.json` and a Python
  equivalent — project hygiene defaults, not language features.

Most of `.vscode/settings.json` isn't "Go config" — it's polyglot-repo config that any
project needs, with one small per-language block (`[go]` here, `[python]` there) plugged
in. The same is true of `pre-commit`'s scope in this repo: it exists for the files that
don't change based on which language owns the application code.

---

## Choice for This Repo

- `gofmt` + compiler + `go vet` for Go code — no extra config, just the toolchain
- `golangci-lint` as an optional addition — pre-registered trigger: add it the first time a
  class of bug the compiler *doesn't* catch (an unchecked error, a shadowed variable, an
  ineffectual assignment) actually bites in review or at runtime. Not "once the codebase is
  large enough" — that's a vibe; "the first unchecked-error bug" is an event.
- `sqlc` + `golang-migrate`/`goose` for the database layer — SQL as source of truth,
  generated Go as the consumption layer
- `pre-commit` scoped to non-Go files (YAML, Markdown, Dockerfiles) — pre-registered trigger:
  add it when a non-Go file (a malformed `docker-compose.yml`, an unformatted migration) breaks
  something a hook would have caught. Until then it is ceremony.
- **Frontend dependency versions live in a pnpm catalog** (`pnpm-workspace.yaml` → `catalog:`),
  framework and tooling alike; apps reference them as `"catalog:"`. Adopted with one app on
  purpose — the drift it prevents needs a second app to occur, but the practice run here is the
  rehearsal for a repo that already has two. New dependencies go in with `pnpm add --save-catalog`.
  With a second app, `--save-catalog` only **creates** entries. The second app references an
  existing entry with `pnpm add "<pkg>@catalog:"`, because `--save-catalog` against an existing
  entry wrote literal versions instead in a two-app migration.
- **ESLint held at 9.** npm flags 9.x deprecated, but `eslint-config-next` pulls in
  `eslint-plugin-import`, `-jsx-a11y` and `-react`, which declare support only through 9 —
  10 installs but leaves unmet peers (`pnpm peers check`). Pre-registered trigger: all three
  declare `^10`, or `create-next-app` generates `^10`. A deprecation notice alone is not the
  trigger.
- `.vscode/settings.json` + `extensions.json` committed to the repo — `golang.go` for Go
  (gofmt + organize imports + `gopls`), `redhat.vscode-yaml` and `docker.docker` for the
  non-Go files, plus the shared editor-hygiene baseline (100-col ruler, trim whitespace,
  final newline, format-on-save) that's identical to a Python repo's equivalent
