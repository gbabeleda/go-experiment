# Input Validation Boundary

**Status:** Exploratory — no Go implementation of the request boundary built yet; this is
the decomposition, not a validated reveal.

> TLDR. The depth lives in `engineering-notes/backend/pydantic-v2-reference.md`
> ("Pydantic as a parse boundary: four jobs") and the *parse, don't validate* idea in
> `engineering-notes/named-principles/`. This doc just records the decomposition so the Go
> side has something to compare against.

## 1. The underlying problem

Every service has an edge where untrusted external input (a JSON request body) becomes a
value the domain operates on. The problem, stated language-invariantly: **convert messy,
untrusted, multi-form input into a typed, in-range, canonical, self-consistent value once,
at the boundary — so nothing downstream re-checks or re-shapes it.** That's the
*parse, don't validate* principle: make illegal/ambiguous states unrepresentable past the
edge.

## 2. How Python decomposes it

One abstraction — a Pydantic `BaseModel` — bundles **four distinct jobs**:

1. **Type coercion / parsing** — wire types → typed Python objects; reject what won't convert.
2. **Constraint validation** — is the value *allowed*? (`Field(gt=0)`, `Literal[...]`) — accept/reject, no change.
3. **Canonicalization** — many equivalent forms → one (strip whitespace, percent → fraction). Representation changes, meaning doesn't.
4. **Derivation** — compute new values from validated ones (`computed_field`).

Plus a hard line: canonicalization is the boundary's job; mapping a value to a *consumer's*
business meaning (e.g. a scoring model's coefficient index) is **domain logic**, kept out
of the schema.

## 3. How Go decomposes it

Go has no `BaseModel`, so the four jobs don't come bundled — you write each explicitly:

- **Coercion/parsing:** `json.Decode` into a struct (types enforced by the struct), or
  `json.RawMessage` + manual parse for looser input.
- **Constraint validation:** hand-written checks, or a struct-tag library (`go-playground/validator`).
- **Canonicalization:** ordinary code in the handler/service before use.
- **Derivation:** ordinary code — there's no computed-field hook.

(Specifics to be filled in once the boundary is actually built here — see Status.)

## 4. What the decomposition difference reveals *(prediction)*

The reveal to test: **because Go forces the four jobs apart, the boundary that Pydantic
makes implicit becomes explicit — and the canonicalize-vs-domain-mapping line, which is
easy to blur inside one Pydantic model, is harder to accidentally cross when each step is
its own block of code.** Prediction that could be wrong: the explicit version costs more
boilerplate but makes "where does parsing end and domain logic begin" structurally obvious
rather than a discipline you have to remember.

## 5. Choice for this repo

Not yet decided — the request boundary hasn't been built. Pre-register the pain: start with
stdlib `json.Decode` + hand-written validation; adopt a struct-tag validator only when the
hand-written checks become repetitive across enough endpoints to be a real maintenance
cost, not merely verbose.

## 6. What building it validated

_Pending — no implementation yet._
