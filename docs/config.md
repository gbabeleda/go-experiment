# Config in Go

**Status:** Exploratory — `internal/config/config.go` is a stub (`Config` struct only; `Load()`
not implemented). Nothing here has met a running system yet.

## The Problem

Every service has values that vary between environments — database URLs, API keys, ports,
feature flags. Hardcoding these is a security and operability problem. The solution, per
12-factor Factor III, is to store config in the environment: environment variables that are
set outside the application and read at startup.

The challenge is not reading env vars — that is one line of code. The challenge is doing it
in a way that is safe, explicit, and fails fast when something is missing or wrong.

---

## How Python Decomposes It

Python bundles the following concerns under a single tool — `pydantic-settings`:
- Reading values from the environment (or a `.env` file)
- Converting strings to the declared type
- Validating that required values are present
- Providing defaults for optional values
- Exposing all config as a single typed object

`pydantic-settings` is the production Python standard. It solves these concerns together:

**Type coercion.** Environment variables are always strings. `PORT=8080` in the shell is the
string `"8080"`. Pydantic Settings converts it to `int` automatically based on the field
declaration. Same for bools, lists, nested models.

**Validation and required fields.** If a required field has no value, the app raises a clear
error at startup — not mid-request when the value is first used. Fail fast at the boundary.

**Defaults.** Optional config can have a default value declared alongside the field.

**Self-documentation.** The Settings class is the single source of truth for what config the
service accepts. New engineers read one file to understand all config.

**Singleton loading.** Combined with `@cache`, `get_settings()` loads config once at startup
and returns the same object on every call.

```python
class Settings(BaseSettings):
    DATABASE_URL: str                          # required — no default, must be set
    PORT: int = 8080                           # optional — defaults to 8080
    REDIS_URL: str
    API_KEY: str

    model_config = SettingsConfigDict(
        env_file=".env",                       # loads .env for local dev
        case_sensitive=True,
        extra="ignore",
    )

@cache
def get_settings() -> Settings:
    return Settings()

settings = get_settings()
```

The problems it solves, summarised:
- Type coercion (string → int, bool, etc.)
- Required field enforcement at startup
- Default values
- Single source of truth for all config
- Fail-fast with a clear error

---

## How Go Decomposes It

### What Go Officially Recommends

Nothing. The Go team does not prescribe a config approach. The standard library exposes
`os.Getenv` and `os.LookupEnv` and leaves the rest to you. This is consistent with Go's
general philosophy — the stdlib covers the primitive, the community converges on patterns.

### What the Community Actually Uses

A [ByteSizeGo survey](https://www.bytesizego.com/blog/env-var-go) asking hundreds of Go
engineers found notably *less* consensus on config than on almost any other topic. The
landscape:

- **Pure stdlib** — a minority preference, but not uncommon in smaller or opinionated codebases
- **`caarlos0/env`** — popular, zero dependencies, struct tags, closest to Pydantic Settings
- **`sethvargo/go-envconfig`** — by Seth Vargo (ex-Google, ex-HashiCorp). Same struct-tag
  approach but with a meaningful differentiator: supports arbitrary lookup functions, not just
  `os.Getenv`. This makes it easier to test (env vars are global state; a custom lookup can
  be swapped in tests without touching the real environment) and easier to integrate with
  secrets managers.
- **`kelseyhightower/envconfig`** — the oldest struct-tag library, still in use, less active
- **Viper** — for services that need multi-source config (files + env + flags); overkill for
  12-factor services

[Three Dots Labs](https://threedots.tech/post/list-of-recommended-libraries/) maintains a
curated list of recommended Go libraries — their config recommendations align with the above.

The honest conclusion: the Go community has not fully converged here. The choice is between
stdlib (explicit, no dep) and a struct-tag library (concise, familiar if coming from Pydantic).
`caarlos0/env` and `sethvargo/go-envconfig` are the two strongest options in that category.

### Option 1: Pure stdlib — `os.Getenv`

No external dependencies. Config is a plain struct; a `Load()` function reads env vars and
returns it. Type conversion and validation are manual.

```go
package config

import (
    "errors"
    "os"
)

type Config struct {
    DatabaseURL string
    Port        string
    RedisURL    string
    APIKey      string
}

func Load() (*Config, error) {
    dbURL := os.Getenv("DATABASE_URL")
    if dbURL == "" {
        return nil, errors.New("DATABASE_URL is required")
    }
    // ... same for other required fields

    return &Config{
        DatabaseURL: dbURL,
        Port:        getOrDefault("PORT", "8080"),
        RedisURL:    os.Getenv("REDIS_URL"),
        APIKey:      os.Getenv("API_KEY"),
    }, nil
}

func getOrDefault(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}
```

What you get and what you don't:

| Problem | Handled? |
|---|---|
| Type coercion | Manual — `strconv.Atoi` for int, etc. |
| Required fields | Manual — explicit nil check per field |
| Defaults | Manual — helper function |
| Self-documentation | Yes — the struct is the source of truth |
| Fail-fast | Yes — `Load()` returns error before anything else runs |

Verbose, but nothing is hidden. Good for understanding the problem before layering on a library.

---

### Option 2: `caarlos0/env`

Struct tags declare the mapping, required constraint, and default — same mental model as
Pydantic Settings field declarations.

```go
package config

import "github.com/caarlos0/env/v11"

type Config struct {
    DatabaseURL string `env:"DATABASE_URL,required"`
    Port        int    `env:"PORT"          envDefault:"8080"`
    RedisURL    string `env:"REDIS_URL,required"`
    APIKey      string `env:"API_KEY,required"`
}

func Load() (*Config, error) {
    cfg := &Config{}
    if err := env.Parse(cfg); err != nil {
        return nil, err
    }
    return cfg, nil
}
```

| Problem | Handled? |
|---|---|
| Type coercion | Yes — struct field type drives conversion |
| Required fields | Yes — `required` tag, error at parse time |
| Defaults | Yes — `envDefault` tag |
| Self-documentation | Yes — all config visible in the struct |
| Fail-fast | Yes — `env.Parse` returns error before anything runs |

The translation from Pydantic Settings is direct: field type → type coercion, `required` tag →
required validation, `envDefault` → default value. Less magic than Pydantic (no metaclass, no
`__init__` generation) but the struct tag approach is idiomatic Go.

---

### Option 3: `sethvargo/go-envconfig`

Same struct-tag approach as `caarlos0/env` with one meaningful differentiator: supports
arbitrary lookup functions instead of being hardwired to `os.Getenv`. In practice this means
you can swap in a test-specific lookup without touching the real environment — important
because env vars are global state and hard to isolate in parallel tests.

```go
package config

import (
    "context"
    "github.com/sethvargo/go-envconfig"
)

type Config struct {
    DatabaseURL string `env:"DATABASE_URL,required"`
    Port        int    `env:"PORT,default=8080"`
    RedisURL    string `env:"REDIS_URL,required"`
    APIKey      string `env:"API_KEY,required"`
}

func Load(ctx context.Context) (*Config, error) {
    cfg := &Config{}
    if err := envconfig.Process(ctx, cfg); err != nil {
        return nil, err
    }
    return cfg, nil
}
```

The `context.Context` as first argument is idiomatic Go — it carries deadlines and cancellation,
and is the standard first parameter for any function that does I/O or external lookups.

| Problem | Handled? |
|---|---|
| Type coercion | Yes — struct field type drives conversion |
| Required fields | Yes — `required` tag |
| Defaults | Yes — `default=` tag |
| Self-documentation | Yes |
| Fail-fast | Yes |
| Test isolation | Yes — swap lookup function without touching env |

The testing advantage is the main reason to choose this over `caarlos0/env`. If parallel tests
or secrets manager integration are a concern, this is the stronger option.

---

### Option 4: Viper

`spf13/viper` supports multiple config sources — env vars, config files (JSON/YAML/TOML),
command-line flags, remote config (etcd, Consul). It is the standard choice when a service
needs to read from more than one source or when config files are a hard requirement.

For a service that follows 12-factor and reads only from environment variables, Viper is
overkill. The added surface area is not justified.

---

### Comparison

| | stdlib `os.Getenv` | `caarlos0/env` | `sethvargo/go-envconfig` | Viper |
|---|---|---|---|---|
| External dep | No | Yes (zero deps) | Yes (small) | Yes (large) |
| Type coercion | Manual | Automatic | Automatic | Automatic |
| Required fields | Manual | Tag | Tag | Manual or tag |
| Defaults | Manual | Tag | Tag | Built-in |
| Custom lookup (testing) | No | No | Yes | No |
| Config files | No | No | No | Yes |
| Verbosity | High | Low | Low | Medium |
| Closest Python equivalent | — | Pydantic Settings | Pydantic Settings | — |

## What This Reveals

Go does not have a single tool that bundles all five concerns. It separates them: `os.Getenv`
reads, `strconv` converts, validation is explicit code, defaults are explicit code. The
struct is the typed object.

What this reveals about Pydantic Settings is that it is doing more than "read env vars" —
it is a typed schema validator that happens to read from the environment. The same validation
machinery that Pydantic uses for HTTP request bodies is the machinery it uses for config. Go
does not conflate these; they are separate problems with separate tools.

Going back to Python with this lens: `pydantic-settings` is valuable not because it reads
env vars but because it brings the same fail-fast validation to config that Pydantic brings
to request parsing. That distinction is easy to miss when you only know one language.

---

## Choice for This Repo

**Phase 1: stdlib.** Start with pure `os.Getenv`. This is a deliberate choice, not a
default — the goal is to encounter the pain points firsthand rather than have a library paper
over them. Where does the boilerplate accumulate? What breaks when a required var is missing?
What does type conversion actually look like? These are the questions the stdlib phase answers.

**Phase 2: migrate — but only on a named trigger.** The temptation is to migrate the moment
the boilerplate "feels heavy." That is the exact vibes trap the validation step warns against:
verbosity is the cost we *accepted* in Phase 1, not pain. Pre-register the events that count as
real pain, before feeling them:

- We need env-var isolation in parallel tests — stdlib reads global `os` state;
  `sethvargo/go-envconfig`'s custom lookup function is the seam that fixes it.
- We need secrets-manager integration — same lookup-function seam.
- A missing or malformed required var reaches runtime instead of failing at startup — i.e. the
  hand-written validation actually let a bug through.

Until one of those fires, stdlib stays, however verbose it looks. The migration, when it comes,
is the learning — what the library removed, what it added — not the goal. And if none of them
ever fire, that is the **Overblown** outcome from the validation step: record "stdlib is
sufficient — do not revisit until one of the above," and stop thinking about it.
