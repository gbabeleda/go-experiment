# Containerization: Go vs Python

**Status:** Validated — the Dockerfile matches the multi-stage / static-binary / non-root
shape described here, and the size claims have been measured against this repo's built
images plus comparable Python services (see *What Building It Validated*). The "10x
smaller" framing turned out to be conservative: this repo's images measure ~17MB, against
~360-400MB for an equivalently empty Python service on the same multi-stage pattern — and
the gap widens further once real dependencies enter the picture.

## The Problem

Packaging an application and its runtime so it behaves identically wherever it runs —
in a way that's small, fast to build, and doesn't carry more attack surface than
necessary.

---

## How Python Decomposes It

A Python container has to ship more than the application code: it needs the Python
interpreter, the installed dependency tree (`site-packages` or a virtualenv), and often
build tools to compile native extensions (wheels with C dependencies need `gcc` and
headers at install time).

Multi-stage builds exist here mainly to **separate build-time dependencies from
runtime dependencies** — compile wheels in one stage, copy only the installed packages
and interpreter into a slim final stage. That separation alone isn't the production-grade
version, though. The naive version still does:

```dockerfile
RUN uv sync --frozen --no-dev          # editable install — .pth pointer back to src/
COPY --from=builder /app /app          # whole repo: .venv AND the source tree it points at
```

— which means the runtime stage carries the interpreter, the full dependency tree, *and*
a duplicate copy of application source, because an editable install needs that source
tree to still exist on disk to import from. The production-grade fix is `--no-editable`
(bakes the package into `.venv`'s `site-packages` as a real wheel, no `.pth` pointer) plus
copying only `.venv` into the runtime stage. Once the package lives inside the venv, there's no source tree left to
duplicate.

Even with that fix, a floor remains, and it's a structural one: image size is driven by
the interpreter plus the dependency tree, and *what base image you're even allowed to
use* is more constrained for Python than for Go. Compiled dependencies — `numpy`,
`pandas`, `pillow`, `lxml`, `psycopg2-binary` — generally only ship prebuilt wheels for
glibc (`manylinux`), not musl (`musllinux`). That caps Python's minimal-base option at
Debian-slim, not Alpine; reaching for Alpine instead forces compiling those from source,
or failing outright. Go has no equivalent floor — see *Choice for This Repo* on why
`CGO_ENABLED=0` lets this repo use Alpine freely, an option Python's own dependency tree
would generally block.

Build time is driven by dependency installation — `uv sync` is the expensive, cacheable
layer, which is why `pyproject.toml`/`uv.lock` get copied and installed before the rest
of the source.

In practice this floor is real: an essentially empty FastAPI service built on this exact
multi-stage shape (slim Python base, `uv`-managed venv, non-root user, `--no-editable`,
venv-only copy) lands around **360-400MB** before a single application-specific
dependency is added. The `--no-editable` fix barely moves this number — an empty service
has almost no source tree to deduplicate in the first place. Where the fix actually pays
off is once a real dependency tree and a real source tree both exist — see *What
Building It Validated*.

---

## How Go Decomposes It

Go compiles to a **single static binary** — but that claim has a footnote: it's only
fully true when `CGO_ENABLED=0`. CGO is the mechanism that lets a Go program call into C
code (`import "C"`), and a handful of standard-library and third-party packages use it by
default — the most common cases being the system DNS resolver on some platforms and
database drivers that wrap a C library directly (e.g. `mattn/go-sqlite3` wraps SQLite's
own C implementation rather than reimplementing it in Go). When CGO is enabled, the
compiled binary dynamically links against the host's libc at runtime, so it's no longer
fully self-contained — it now depends on the target having a *compatible* libc, and
glibc (Debian) and musl (Alpine) are not interchangeable at the binary level.

`CGO_ENABLED=0` (set in this repo's Dockerfile) forces Go's pure-Go fallbacks instead —
e.g. its own DNS resolver — and produces a binary with zero dynamic linking and zero libc
dependency, full stop. That's what makes the binary portable across *any* base image
regardless of libc family — Alpine today, Debian tomorrow, `scratch` if you wanted,
without recompiling. The day this repo adds a dependency that genuinely needs CGO (a C
library with no pure-Go equivalent), that portability goes away, and Alpine's musl
becomes a real compatibility question instead of a non-issue — see the trigger condition
noted in *Choice for This Repo*.

The multi-stage build exists for a different reason than in Python: not "separate build
deps from runtime deps," but "the final artifact needs *nothing* from the build stage
except the binary itself."

```dockerfile
FROM golang:1.25.4 AS builder
# ... compile ...
RUN CGO_ENABLED=0 go build -o /bin/api ./cmd/api

FROM alpine:3.24.1 AS api
COPY --from=builder --chown=appuser:appuser /bin/api /bin/api
ENTRYPOINT ["/bin/api"]
```

The final stage carries: the binary, a minimal base (Alpine, or even `scratch`), and
whatever the binary needs at runtime (CA certs for TLS, a non-root user). No interpreter,
no dependency tree, no package manager.

In practice, this repo's `api` and `worker` images — also essentially empty — land at
**~17.2MB each**, with most of that being the Alpine base itself rather than the binary.

---

## The Binary-Without-a-Container Question

Because Go produces a single static binary, you could, in principle, skip containers
entirely: `scp` the binary to a server with a matching OS/architecture and run it
directly. No interpreter to install, no dependency tree to reconcile, no virtualenv to
activate.

This isn't realistically an option for Python — shipping a `.py` file to a server assumes
the right interpreter version and every dependency are already present and compatible,
which is precisely the reproducibility problem containers exist to solve.

We containerize the Go binary anyway, but for a different reason than Python does:

- deployment infrastructure (Kubernetes, ECS, etc.) is built around images, not raw
  binaries
- consistency across dev/staging/production environments — the container is the unit of
  "this runs the same everywhere," regardless of what's inside it
- not having to reason about "does the target machine have the right OS/architecture"

---

## What This Reveals

### The Concrete Outcomes

**Size** — Go images commonly land in the 10–30MB range; equivalent Python images are
often 10x that or more (see *What Building It Validated* for just how much more). The gap
is the interpreter and dependency tree, not the application code.

**Build time** — Go has a compile step Python doesn't (Python just copies source), but
the compiler is fast and the output is a single cacheable artifact. Once `go.mod`/`go.sum`
are cached (`go mod download` as its own layer, same caching principle as `uv sync`),
rebuilds that only touch source are quick.

**Attack surface** — fewer things in the image means fewer things to patch. There's no
interpreter version to track, no transitive dependency tree to scan for CVEs in the
runtime image — just the base OS layer (if any) and the binary.

### What Still Needs Doing — and What's the Same

Containerization doesn't make security concerns disappear; it just changes *what's left*
to worry about. The remaining work is the same regardless of language:

- **Non-root user** — exactly the work already done in this repo's Dockerfile
  (`addgroup -S` / `adduser -S`, `USER appuser`, `--chown` on `COPY`). Running as root in
  a container is a bad idea whether the binary inside is Go, Python, or anything else.
- **Minimal base image** — Alpine here, slim/distroless equivalents in Python. Smaller
  base, smaller surface, in both ecosystems.
- **Layering strategy is conceptually identical** — put what changes rarely (dependencies)
  in earlier layers, what changes often (source code) later, so Docker's build cache does
  its job. `go mod download` before `COPY . .` is the same idea as `uv sync` before
  copying source.

What's *not* the same: how much is left to secure. Python's final image still has an
interpreter and a dependency tree to keep patched. Go's final image is close to "binary +
base OS" — there's structurally less surface to maintain.

### Necessity vs. Convenience

For Python, containerization is close to a *necessity* — it's the thing that makes
"works on my machine" into "works anywhere," because the interpreter and dependency tree
are otherwise a moving target.

For Go, containerization is more of a *deployment convenience* layered on top of an
artifact (the static binary) that was already portable and reproducible on its own. The
container isn't solving Go's reproducibility problem — Go didn't really have one at the
binary level. It's solving the orchestration problem: how do you deploy *anything*
predictably at scale, regardless of what language produced it.

Same tool, same Dockerfile shape, different leverage. Seeing where Go's container "does
less work" is what makes visible how much of Python's container is actually compensating
for the interpreter.

---

## Choice for This Repo

- Multi-stage build: one `golang:1.25.4` builder stage, two separate runtime stages
  (`api`, `worker`) — one `go.mod`, multiple binaries, multiple final images
- `CGO_ENABLED=0` for fully static binaries — no libc dependency, no dynamic linking at
  runtime
- Non-root user (`appuser`, uid/gid 1000) created in each runtime stage, `--chown` on the
  binary `COPY`
- `alpine:3.24.1` as the runtime base, version-pinned — bare `alpine` floats to whatever
  `latest` resolves to at build time, the same reproducibility problem an unpinned
  `golang:1.25` or `python:3.11` base would have. Smallest option that still has a shell
  and package manager for `docker exec` debugging.

Two axes of this choice have room to be wrong, both pre-registered:

**Alpine vs. `scratch`** — `scratch` would shrink the image further (~10-12MB, just the
binary) but removes the shell entirely. Worth being precise about what that actually
costs: `docker exec <container> /bin/migrate up` doesn't need a shell at all — `exec`
just needs the named binary to exist in the container's filesystem, and that works the
same on `scratch` as it does on Alpine. What `scratch` actually removes is *interactive*
debugging — `docker exec -it container sh` to poke around with `ls`, `cat`, `ps` when
something's wrong and you don't yet know which binary you'd want to run. That's the real
argument for keeping Alpine's shell, not "so we can exec known commands like
migrations" — known commands exec fine without one.

(This came up while comparing notes against invested-api, which ships its Alembic
migration scripts inside the API image and runs them through the venv's `alembic` entry
point — a file on disk that has to exist there to be invoked, same constraint as the
shell case. A Go equivalent would look structurally different: a dedicated `migrate`
binary — e.g. via `golang-migrate/migrate` — compiled as its own build target the same
way `api` and `worker` already are, with the migration SQL baked directly into the
binary via `go:embed` instead of copied in as separate files. No shell needed either
way to run it — exec the binary directly, whether that's `docker exec` into a running
container or a one-off `docker run` against the `migrate` target.)

Revisit Alpine vs. `scratch` if Alpine's shell/package-manager surface ever turns up in
a CVE scan, or if interactive `docker exec` debugging of these containers turns out to
never get used in practice. Until then, the few extra MB for that interactive escape
hatch is worth it.

**Alpine vs. Debian-family** — tested. Alpine's musl libc is a different family from the
Python images (Debian-based — see *How Python Decomposes It* for why that's not a free
choice for Python, given what its compiled dependencies need), invisible today only
because `CGO_ENABLED=0` means the binary doesn't link against any libc. A
`debian:trixie-slim` final stage was built and measured for comparison:

| Base | Size |
|---|---|
| `alpine` (current) | **17.2MB** |
| `debian:trixie-slim` (tested) | **143MB** |

The swap alone — no other changes — took the image from ~17MB to ~143MB (~8x), and
immediately introduced 2 high-severity CVEs flagged by the IDE's scanner, from the base
image's larger package set. Against the Python floor (~360-400MB), Alpine's ~20x
advantage would shrink to ~2.5x. **Decision: stay on Alpine.**

The only trigger that justifies revisiting this: **a future dependency that requires
`CGO_ENABLED=1` and doesn't have solid musl/Alpine support.** (musl's other known
quirks — DNS resolver edge cases under specific `resolv.conf` shapes — are more of a
Kubernetes pattern than this repo's docker-compose setup, so they're not a practical
trigger on their own.) Distroless variants were also considered and set aside for now:
`static-debian12` has no shell at all, and `base-debian12:debug` is pinned to Debian 12,
not 13.

If that trigger fires, the replacement doesn't have to be `debian:trixie-slim`
specifically, or even trixie at all — "same release as the Python images" was this
exploration's framing, not a requirement. The right call at that point is *some*
glibc/Debian-family slim image, chosen based on whatever the actual CGO dependency needs.
Picking the exact variant now, for a dependency that doesn't exist yet, isn't worth doing.

---

## Remaining Hardening — Not Yet Applied

The shape above is right: multi-stage, static binary, one target per binary, pinned bases,
non-root, exec-form `ENTRYPOINT` (so the binary is PID 1 and receives `SIGTERM` directly),
and a `.dockerignore` scoped to the `backend/` context. What's left is refinement, in order
of payoff. The runtime base is **not** on this list — Alpine vs. `scratch`/distroless is
decided above.

**1. Build cache mounts — the one you feel on every build.** Today `go mod download` is
cached as a layer, but `COPY . .` invalidates the compile, so any source edit recompiles
from nothing. Go keeps two caches — downloaded modules (`/go/pkg/mod`) and compiled
packages (`/root/.cache/go-build`) — and mounting them makes rebuilds incremental, the
same idea as the `uv` cache mount on the Python side:

```dockerfile
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=bind,source=go.mod,target=go.mod \
    --mount=type=bind,source=go.sum,target=go.sum \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build ... ./cmd/api
```

Cache mounts persist on the machine doing the build, not in the image — they help local
builds and a persistent CI builder, and do nothing on an ephemeral CI runner.
For the CI branch, the layer cache is what carries over between runs:
`docker/setup-buildx-action` plus `cache-from: type=gha` / `cache-to: type=gha,mode=max`.
Cache mounts are **not** exported with it. Rehearsed on a client pipeline; the details are
in engineering-notes `reference/devops/cicd-github-actions.md` → Part 11.

**2. `-trimpath -ldflags="-s -w"`.** `-trimpath` strips build-machine paths from the
binary, so it doesn't leak the builder's filesystem and two builds of the same source
produce the same bytes. `-s -w` drops the symbol table and DWARF debug info, typically a
third or so off the binary. Panic stack traces still work — they come from Go's own
runtime tables, not DWARF. What you lose is attaching a debugger (`dlv`) to the production
binary, which nobody does.

**3. Time zone data.** Alpine ships no `tzdata`, so `time.LoadLocation("Asia/Manila")`
works on a laptop and fails in the container. `import _ "time/tzdata"` in `main` embeds
the database in the binary (~450KB) — base-independent, so it survives any future move to
`scratch`. `apk add tzdata` also works but ties the fix to Alpine.

**4. Native cross-compilation.** Local builds are arm64 (Apple Silicon), servers amd64.
A multi-platform build would otherwise run the whole Go toolchain under QEMU emulation.
Go cross-compiles natively, so the builder can run on the build machine's own platform and
just be told the target:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.25.4 AS builder
ARG TARGETOS TARGETARCH
RUN ... GOOS=$TARGETOS GOARCH=$TARGETARCH go build ...
```

Few languages get this for free; Python can't (its wheels are per-platform) and Node only
partly (native addons).

**5. Root-owned binary.** `--chown=appuser:appuser` makes the runtime user the *owner* of
its binary, so a compromised process could overwrite its own code on disk. Execution only
needs read + execute, which a root-owned file with default permissions (`755`) already
gives every user. Drop the `--chown` on the binary copy; keep `USER appuser`. (The same
argument applies to the invested-api / invested-staff images, which chown their `.venv` and
app folder to `appuser`.)

**Owed by the code, not the Dockerfile** — due once `cmd/api` is a real server rather than a
placeholder that prints and exits (which is why both containers currently sit in
`Restarting (0)`: a clean exit, restarted forever by `restart: always`):

- **Graceful shutdown.** `signal.NotifyContext(ctx, syscall.SIGTERM, os.Interrupt)` plus
  `server.Shutdown(ctx)`, so in-flight requests finish inside compose's 60s
  `stop_grace_period` instead of being cut at the kill.
- **A health endpoint and compose healthcheck.** Alpine's busybox has `wget`, so
  `wget -qO- http://localhost:8080/healthz` works as the compose `test:` without adding
  anything to the image. (On `scratch` there'd be no `wget` either — the usual answer there
  is a `healthcheck` subcommand in the binary itself.)

---

## What Building It Validated

Measured against this repo's actual built images, plus two comparable Python services
built on the equivalent multi-stage pattern (slim Python base, `uv`-managed venv,
non-root user):

| | Image size |
|---|---|
| This repo's `api` / `worker` (Go, Alpine) | **~17.2MB** each |
| An essentially empty FastAPI service (Python) | **~360-400MB** |
| Heavy-dataframe-dependency FastAPI service — editable install + whole-repo copy | ~1.15-1.22GB |
| Same service — after the `--no-editable` / venv-only-copy fix | **~600MB** |

**Outcome: Confirmed — and the "10x" framing was conservative.** At the empty-service end,
Go comes out **~20x smaller** than Python (17MB vs ~360MB), not 10x. Layer-by-layer
inspection of the two Python images also showed *why* the gap has so much variance: the
dependency-installation layer alone was ~4x larger for the heavier service (656MB vs
151MB), and a single compiled dataframe library accounted for roughly a third of that
difference on its own — one library choice moved the image by ~200MB. (That layer
breakdown is from the pre-fix build — the dependency-install layer itself doesn't change
when you remove the editable install; the source duplication on top of it does.)

This sharpens the original decomposition claim. It's not just "Python's size is
interpreter + dependencies, Go's is neither" — it's that the *interpreter* side of
Python's equation is a relatively stable floor (~360-400MB for this shape), while the
*dependency tree* side has much higher variance and is where most of the size difference
between "two Python services" actually lives. Go has no equivalent variance: every
dependency compiles into the one binary, so there's no single library that can quietly
add hundreds of MB to the image.

**Update — retested after applying the production-grade fix:** rebuilding the
heavy-dataframe service with `--no-editable` plus a venv-only runtime copy (the same fix
described in *How Python Decomposes It*, applied for real to invested-api) brought it
from ~1.15-1.22GB down to **~600MB** — no other change. That's the whole-repo-copy waste
this fix targets: the editable install was forcing a duplicate copy of the source tree
(and whatever else `COPY --from=builder /app /app` was pulling in) on top of the
dependency-installation layer, which itself didn't get any smaller. No fresh
layer-by-layer breakdown for the optimized build yet — just the total.

This doesn't change the structural conclusion, it sharpens it further: some of Python's
size was self-inflicted (the editable-install / whole-repo-copy habit), and some is the
irreducible floor (interpreter + compiled-dependency wheels, and the glibc-only base
image that floor requires). Fixing the self-inflicted part narrows the gap at the
heavy-dependency end from **~70x to ~35x** (1.2GB vs 17MB → 600MB vs 17MB) — still nowhere
close, because the floor was never the source tree's fault.
