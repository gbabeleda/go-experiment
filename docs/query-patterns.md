# Query Patterns in Go

**Status:** Exploratory in this repo. The core layer-responsibility insight (below) was
validated in the InvestEd Python codebase; the Go-specific prediction — that sqlc's static SQL
surfaces dead domain filters *earlier* than a dynamic query builder would — is unbuilt and
unchecked here.

## The Problem

Every service needs to retrieve and filter data. The questions are: where does filtering
happen (database vs application), who owns that decision (domain layer vs application
layer), and what does the query tool allow or prevent?

---

## How Python Decomposes It

SQLAlchemy bundles query construction, execution, and result mapping under one abstraction.
Crucially, it allows **dynamic query building** — queries are Python objects that can be
conditionally modified before execution:

```python
async def get_institutions(
    session: AsyncSession,
    country_code: str | None = None,
) -> list[Institutions]:
    query = select(Institutions).where(Institutions.is_active.is_(True))
    if country_code is not None:
        query = query.where(Institutions.country_code == country_code)
    result = await session.execute(query)
    return list(result.scalars().all())
```

The domain layer can express optional filters cleanly. The application layer decides whether
to use them.

---

## How Go Decomposes It

**sqlc is static.** You write SQL; sqlc generates a Go function with a fixed signature. There
is no query object to conditionally modify. The SQL that goes into `sqlc generate` is the
SQL that runs — no conditional WHERE clauses, no dynamic parameter lists.

This is sqlc's strength (exact, type-safe, no surprises) and its constraint (no dynamic
query building at the domain layer).

The options when filters are needed:

**Multiple queries** — write a separate SQL function per filter combination:

```sql
-- name: GetInstitutions :many
SELECT id, name, country_code FROM institutions WHERE is_active = true;

-- name: GetInstitutionsByCountry :many
SELECT id, name, country_code FROM institutions
WHERE is_active = true AND country_code = $1;
```

Gets combinatorially painful with several optional filters.

**Nullable parameter trick** — pass NULL to skip a filter:

```sql
-- name: GetInstitutions :many
SELECT id, name, country_code FROM institutions
WHERE is_active = true
AND ($1::text IS NULL OR country_code = $1);
```

Works, but the query planner may not use indexes efficiently since the condition is not
constant. Use with care on large tables.

**In-memory filtering** — fetch the full dataset, filter in Go after retrieval. The right
call when the dataset is small, read-heavy, and cacheable.

**Raw pgx with manual query building** — bypass sqlc for that specific query and build
the SQL string dynamically. Loses sqlc's type safety. Worth it only for genuinely complex
dynamic filtering that no other approach handles cleanly.

---

## The In-Memory Filtering Pattern

For reference data — small datasets, rarely changing, read many times — in-memory filtering
after a full fetch is almost always the right choice:

```go
// Fetch everything (cached)
items, err := Cached(ctx, rdb, "myapp:institutions", ttl, fetchInstitutions)

// Filter in Go
if countryCode != "" {
    filtered := items[:0]
    for _, item := range items {
        if item.CountryCode == countryCode {
            filtered = append(filtered, item)
        }
    }
    items = filtered
}
```

The sqlc query is clean — no optional parameters, no conditional WHERE:

```sql
-- name: GetInstitutions :many
SELECT id, name, country_code FROM institutions WHERE is_active = true;
```

The architecture is honest: the domain layer returns everything; the application layer
decides what to surface.

---

## What This Reveals

This pattern surfaced an architectural insight during implementation of the InvestEd
reference data API.

The domain layer was written first with optional filter parameters:

```python
async def get_institutions(session, country_code=None):
    query = select(Institutions).where(...)
    if country_code is not None:
        query = query.where(Institutions.country_code == country_code)
```

The application layer was written second with a caching strategy. Because the cache stores
the full dataset and filtering happens in memory, the application layer never passes
`country_code` to the domain function. The domain-layer filter is functionally dead.

This only became visible after both layers existed. The domain layer was built with a
reasonable assumption ("filtering by country seems useful"); the application layer's
caching strategy made that assumption unnecessary.

**The principle:** once the application layer is built, look back at the domain layer and
remove what turned out to be unused. The first pass is exploratory; the cleanup pass is
where the design settles. A domain layer capability that no application layer calls is
either in the wrong layer or shouldn't exist.

In Go, sqlc accelerates this realisation. Because the SQL is static and you must commit
to the query shape before the application layer uses it, the tension surfaces earlier —
you can't add "just in case" optional parameters to a sqlc query without writing a
separate SQL function. The static constraint is a forcing function for cleaner domain
layer design.

---

## Choice for This Repo

- **sqlc** for all queries — static SQL, generated type-safe functions
- **In-memory filtering** for reference data and other small cacheable datasets
- **Nullable parameter trick** for cases where DB-level filtering is genuinely needed and
  the dataset is too large to cache
- **Raw pgx** as the escape hatch for genuinely dynamic queries — document the tradeoff
  when used
