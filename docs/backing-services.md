# Backing Services in Go

**Status:** Exploratory — no `internal/db` or cache code exists yet. The pool models and field
translations below are predictions, not measurements.

## The Problem

Every production service needs to connect to backing services — databases, caches, queues.
The challenge is not making the connection; it is managing connections efficiently and safely:
pooling them so you don't exhaust the server, recycling them so you don't hold stale ones,
timing out so a hung connection doesn't block a request forever.

This is the same problem in every language. The library choices and pool models differ.

---

## How Python Decomposes It

For Postgres, Python bundles the following concerns under SQLAlchemy:
- Connection pooling (pool_size, max_overflow, recycling, health checks)
- Schema definition (Python models describe table structure)
- Migration generation (Alembic reads models to produce migration files)
- Query execution (ORM or Core SQL expression language)

This doc covers only the first concern — connection pooling. Schema definition and migrations
are a separate decomposition and are covered in `schema-and-migrations.md`.

**Postgres — SQLAlchemy + asyncpg**

SQLAlchemy manages a connection pool with a two-tier model:

```python
engine = create_async_engine(
    DATABASE_URI,
    pool_size=5,        # persistent connections, always kept open
    max_overflow=10,    # burst connections, created under load, closed after use
    pool_recycle=3600,  # recycle connections after 1 hour
    pool_pre_ping=True, # test connection before handing it to the caller
    connect_args={
        "connect_timeout": 10,
        "application_name": "myapp",
        "ssl": ssl_context,
    },
)
```

Under normal load, SQLAlchemy keeps exactly `pool_size` connections open. Under burst load
it creates up to `max_overflow` extra connections, which are closed (not pooled) after use.
Total ceiling = `pool_size + max_overflow`.

**Redis — redis-py**

```python
redis.Redis(
    max_connections=20,
    socket_timeout=5,
    socket_connect_timeout=5,
)
```

A single pool, single ceiling, single timeout for both read and write.

---

## How Go Decomposes It

**Postgres**

### Option 1: `database/sql` (stdlib interface)

`database/sql` is Go's standard database abstraction layer — the equivalent of Python's
DB-API 2.0 (PEP 249). It defines standard interfaces (`*sql.DB`, `*sql.Rows`, `*sql.Tx`)
that any driver implements.

```go
import (
    "database/sql"
    _ "github.com/jackc/pgx/v5/stdlib"   // pgx as a database/sql driver
)

db, err := sql.Open("pgx", os.Getenv("DATABASE_URL"))
db.SetMaxOpenConns(15)
db.SetMaxIdleConns(5)
db.SetConnMaxLifetime(time.Hour)
```

What you get: portability — the same code works with any `database/sql`-compatible driver.
What you lose: anything Postgres-specific. pgx's native pool config, named types, COPY
protocol, and fine-grained connection options are all abstracted away.

**When to use:** if you genuinely need to swap database drivers, or if you're using a library
that requires a `*sql.DB`. For a Postgres-only service, this is the wrong choice.

---

### Option 2: pgx native (recommended)

pgx can bypass `database/sql` entirely and use its own pool — `pgxpool`. This is the
standard choice for Postgres-only Go services. You get the full pgx API and all pool knobs.

```go
import "github.com/jackc/pgx/v5/pgxpool"

config, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
config.MaxConns = 15
config.MinConns = 5
config.MaxConnLifetime = time.Hour

pool, err := pgxpool.NewWithConfig(ctx, config)
```

The pool lives for the lifetime of the service, shared across all handlers. Connections are
acquired per-request and released with `defer conn.Release()`.

---

### Option 3: sqlc (query generation)

`sqlc` is not a runtime library — it is a code generator. You write SQL queries in `.sql`
files, run `sqlc generate`, and get back type-safe Go functions. No ORM, no query builder.

```sql
-- name: GetInstitutions :many
SELECT id, name, country_code FROM institutions WHERE is_active = true;
```

Generates:

```go
func (q *Queries) GetInstitutions(ctx context.Context) ([]Institution, error)
```

You still use pgx (or `database/sql`) as the underlying driver — sqlc generates the query
functions on top of it. This is the recommended approach for domain queries once the pool
is set up.

---

### Option 4: GORM (ORM)

GORM is a full ORM in the SQLAlchemy mould — model declarations, relationships, migrations,
hooks. It uses `database/sql` under the hood.

For a service built on the layered architecture in this repo, GORM adds more abstraction
than it removes friction. SQL written explicitly is readable, debuggable, and exact. GORM
is worth knowing about; it is not the choice here.

---

### Postgres comparison

| | `database/sql` | pgx native | sqlc | GORM |
|---|---|---|---|---|
| External dep | Driver only | Yes | Yes (codegen) | Yes |
| Postgres-specific features | No | Yes | Yes (via pgx) | No |
| Pool control | Basic | Full | Via pgx | Basic |
| Query style | Manual SQL | Manual SQL | Generated from SQL | ORM |
| Type safety | Runtime | Runtime | Compile-time | Runtime |
| Closest Python equivalent | DB-API 2.0 | asyncpg | — | SQLAlchemy ORM |

**Choice for this repo:** pgx native for the pool, sqlc for queries once the foundation
is in place. The two rejected options get pre-registered triggers for revisiting, so the
choice doesn't get silently second-guessed later: reach for `database/sql` only if a dependency
genuinely requires a `*sql.DB` that can't come from pgx (e.g. a library that won't accept a
`pgxpool`); reach for GORM only if hand-written SQL + sqlc becomes a demonstrable drag on
*delivery speed* — a named, repeated cost, not "this feels like a lot of SQL." Neither is
expected to fire.

---

### Pool Model: SQLAlchemy vs pgx

This is the most important conceptual difference. Understanding it prevents misconfiguring
the pool.

**SQLAlchemy — two tiers:**

```
pool_size = 5       # persistent connections, always kept open
max_overflow = 10   # burst connections — created under load, closed after use
                    # total ceiling = pool_size + max_overflow = 15
```

**pgx — floor and ceiling:**

```
MinConns = 5        # floor — keep at least this many connections warm
MaxConns = 15       # ceiling — hard limit (equivalent to pool_size + max_overflow)
```

Translation:
- `pool_size` → `MinConns`
- `pool_size + max_overflow` → `MaxConns`

The gap between `MinConns` and `MaxConns` is your burst capacity. Setting them equal means
"keep all connections warm always" — only appropriate under consistently high load.

**Full field translation:**

| SQLAlchemy | pgx | Notes |
|---|---|---|
| `pool_size` | `MinConns` | Keep this many warm |
| `pool_size + max_overflow` | `MaxConns` | Hard ceiling |
| `pool_recycle` (seconds) | `MaxConnLifetime` (duration) | Recycle connections after this age |
| — | `MaxConnIdleTime` | No SQLAlchemy equivalent — close idle connections |
| — | `MaxConnLifetimeJitter` | Randomises expiry to prevent thundering herd |
| `pool_pre_ping = True` | `HealthCheckPeriod` | Different mechanism — see below |
| `connect_args: connect_timeout` | `ConnConfig.ConnectTimeout` | On inner ConnConfig, not pool level |
| `connect_args: application_name` | `ConnConfig.RuntimeParams["application_name"]` | Visible in pg_stat_activity |
| `echo = True` | pgx tracer interface | Bool in config, wired to tracer in pool setup |

**`pool_pre_ping` vs `HealthCheckPeriod`:**

SQLAlchemy's `pool_pre_ping=True` runs a `SELECT 1` immediately before handing a connection
to the caller — synchronous, on every acquire. Catches stale connections before they reach
application code.

pgx's `HealthCheckPeriod` runs a background goroutine that periodically checks idle
connections. The default `ShouldPing` behaviour pings connections idle for at least 1 second.
Same goal, asynchronous mechanism. Unhealthy connections are removed in the background rather
than detected at acquire time. For most services the outcome is equivalent.

---

**Redis**

### go-redis (standard choice)

`go-redis` is the community standard. No meaningful alternatives in active use.

```go
import "github.com/redis/go-redis/v9"

rdb := redis.NewClient(&redis.Options{
    Addr:         os.Getenv("REDIS_URL"),
    PoolSize:     20,
    DialTimeout:  5 * time.Second,
    ReadTimeout:  5 * time.Second,
    WriteTimeout: 5 * time.Second,
})
```

**Field translation from Python:**

| Python redis | go-redis | Notes |
|---|---|---|
| `max_connections = 20` | `PoolSize` | Pool ceiling |
| — | `MinIdleConns` | Keep this many idle connections warm; no Python equivalent |
| `socket_timeout = 5` | `ReadTimeout` + `WriteTimeout` | Python uses one value; go-redis separates them |
| `socket_connect_timeout = 5` | `DialTimeout` | Time to establish connection |
| — | `ConnMaxLifetime` | Recycle connections after this age |
| — | `ConnMaxIdleTime` | Close idle connections after this duration |

go-redis splits read and write timeouts where Python uses a single `socket_timeout`. In
practice set them to the same value unless you have blocking commands (`BLPOP`, `SUBSCRIBE`)
that need a longer read timeout.

---

### What Belongs in Config vs Pool Setup

Not every pool knob should be an env var. The rule: config holds values that legitimately
differ between environments; pool setup code hardcodes values that are fixed everywhere.

**In `internal/config/` (env vars):**
- `DBMaxConns` — production gets more connections than local dev
- `DBMinConns` — production keeps a warm floor; local dev doesn't need to
- `DBMaxConnLifetime` — production may have stricter recycling policies
- `DBConnectTimeout` — tighter in production, looser locally
- `DBSSL` — `true` in production, `false` for local Docker Postgres
- `DBApplicationName` — identifies the service in `pg_stat_activity`
- `DBEchoSQL` — `false` in production, optionally `true` in dev
- `RedisPoolSize`, `RedisDialTimeout`, `RedisReadTimeout`, `RedisWriteTimeout`

**Hardcoded in `internal/db/` (not env vars):**
- `MaxConnLifetimeJitter` — set to a fraction of `MaxConnLifetime`; no reason to vary
- `MaxConnIdleTime` — rarely needs per-env tuning; hardcode a sensible value
- Hooks (`BeforeConnect`, `AfterConnect`, etc.) — these are code, not config

---

## What This Reveals

In Python, SQLAlchemy presents connection pooling as one part of a larger unified abstraction
— you configure the pool the same place you define models and run queries. It is easy to
think of it as one thing.

Go separates them completely. The pool is in `internal/db/`. The query functions are
generated by sqlc from SQL files. The schema lives in migration files managed by
golang-migrate. Three separate tools, three separate concerns.

This separation makes it clear that SQLAlchemy's pool is not special to SQLAlchemy — it is
solving a generic problem (connection management) that would exist regardless of whether you
used an ORM. pgx's pool solves the same problem with a different model. The problem is
language-invariant; the implementation is not.

The other thing this reveals: the SQLAlchemy two-tier pool model (`pool_size` +
`max_overflow`) is a design choice, not an inherent property of connection pools. pgx made
a different choice (floor + ceiling). Understanding both makes the tradeoffs legible rather
than invisible.
