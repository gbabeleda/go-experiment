# docs/

This folder is a learning journal, not a tutorial.

## The Actual Goal

The goal is not to translate Python into Go. The goal is **production-grade software** —
full stop, language-agnostic. The properties that make a system production-grade (see
`engineering-notes/production-grade/production-grade-software.md`) don't care what
language implements them.

What's distinctive is the *method* used to get there. We have more production experience
in Python than in Go, so Python becomes the reference point — not the destination, the
known quantity that makes the unknown legible.

## The Method

1. **Decompose** — take something Python bundles into one abstraction (SQLAlchemy,
   Pydantic Settings, a monorepo workspace) and pull it apart into the distinct concerns
   it's actually solving. What is this thing doing, in SRP terms?
2. **Compare** — ask how Go, which tends to keep those concerns separate rather than
   bundle them, handles each one individually
3. **Synthesize** — use that comparison to figure out what production-grade actually
   requires, structurally, independent of either language

Translation is a side effect of this process, not its purpose. The real product is a
sharper, more portable understanding of what production-grade software requires —
regardless of which language you're standing in when you need it.

## What This Produces

Layered learning, deliberately:

- **Learn Go** — the most concrete layer, the one you notice first
- **Learn production-grade Go** — not just syntax, but how to build something that holds
  up against the properties in `production-grade-software.md`
- **Build a decomposition habit** — once SQLAlchemy has been pulled apart into "pooling +
  schema + migrations + queries," that's what to look for in *any* language's ORM, not
  just SQLAlchemy's. The skill transfers even when the tool doesn't.
- **Strengthen all three mental models at once** — general (language-agnostic production
  engineering), Python (seen freshly through "what is this actually bundling"), and Go
  (the new model being built)

---

## How Each Doc Is Structured

Every doc follows the same four-part framework — which is just the method above, written
down as a template:

**1. The underlying problem** *(sets up Decompose)*
What are we actually trying to solve? Stated in language-invariant terms. If you stripped
out all mention of Python and Go, this section should still make sense. This is the
language-agnostic frame the rest of the doc hangs off — without it, the comparison that
follows has nothing to anchor to.

**2. How Python decomposes it** *(Decompose)*
Which Python tools or libraries handle this problem, and what concerns do they bundle
together? Python abstractions often bundle several distinct concerns under one interface —
naming those concerns explicitly is the point of this section.

**3. How Go decomposes it** *(Compare)*
What are the Go options? Go tends to separate concerns that Python bundles. This section
shows that decomposition and explores the available choices.

**4. What the decomposition difference reveals** *(Synthesize)*
This is the payoff. When Python bundles X and Y under one tool, and Go separates them into
two, that difference reveals something about the underlying problem that was hidden by the
abstraction. Naming it explicitly is what turns a language comparison into a transferable
mental model — the thing that survives even if you forget the specific library names.

The process also runs in reverse: understanding the Go decomposition often sharpens the
understanding of what Python is doing. A concept that felt like one thing in Python becomes
two or three distinct things — and going back to Python with that lens changes how you read
and write it.

---

## Relationship to `engineering-notes/`

The notes here are more detailed and exploratory than the distilled references in
`engineering-notes/`:

- **`docs/` (here)** — exploration in progress. Written during implementation. Includes
  dead ends, comparisons, open questions, and the reasoning behind choices — the full
  decompose/compare/synthesize trail, visible.
- **`engineering-notes/`** — distilled and transferable. Written after the understanding
  is stable. Stripped of the exploration, kept as the synthesized result — the "what this
  reveals" sections, generalized beyond this specific repo.

When a doc here reaches a stable conclusion, the insight gets abstracted into
`engineering-notes/`. The exploration stays here. In other words: `docs/` is where
*Decompose* and *Compare* happen in full, messy detail; `engineering-notes/` is where the
*Synthesize* step's output ends up once it's proven durable enough to generalize.

---

## Current Docs

Grouped by the property clusters from `engineering-notes/production-grade/production-grade-software.md`.
This grouping is still settling — only the placements we're confident about are listed
here for now. (`config.md`, `backing-services.md`, and `query-patterns.md` exist but
aren't placed yet; their cluster fit needs more thought before they're slotted in.)

### Evolvability — can it change without pain?

- [project-structure.md](project-structure.md) — modular monolith philosophy, Go's `cmd/`/`internal/` convention vs Python monorepo workspaces, and why Go's module boundaries are compiler-enforced rather than convention-and-linter-enforced. The structural foundation everything else in this list builds on.
- [dev-tooling.md](dev-tooling.md) — why Go's quality-tooling stack is sparser than Python's, and how raw SQL as schema/query source-of-truth is a genuine departure from Python's all-in-one-language approach

### Operability — can humans actually ship and run it?

- [containerization.md](containerization.md) — static binaries vs interpreter+deps, image size and attack surface outcomes, and why containerization means something different for Go than for Python
