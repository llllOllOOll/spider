# Architecture decisions

Each file here records one decision about how Spider is built: the problem,
what was measured, the options, what was chosen and what it costs. They are
for whoever works on Spider or wants to know why it is the way it is.

- One file per decision, numbered: `NNNN-short-title.md`, in the format of
  [`template.md`](template.md).
- A decision is written here only when it is settled: the problem studied,
  measured where numbers matter, the alternatives compared, the sources
  given, and the maintainer has accepted it. Proposals and discussion happen
  before, not in this folder.
- An accepted record is not edited. When a decision changes, a new record
  replaces it and the old one gets `Superseded by NNNN`, so the reasoning
  stays readable.
- Larger designs are discussed first as an RFC (`docs/rfcs/`); the decision
  that comes out of one can then be recorded here, pointing to it.

| # | Decision | Status |
|---|---|---|
| [0001](0001-io-backend.md) | zio is the default I/O backend | Proposed |
