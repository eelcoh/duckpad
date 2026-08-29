# Roadmap: an Elm/Acadia-flavored reactive notebook over DuckDB

## Concept summary

A Jupyter-alternative notebook environment built around a functional,
statically-typed query language (Acadia-inspired) for data cells and Elm
for view/compute cells, running against DuckDB (via duckdb-wasm) instead
of pandas/kernels. Key departures from Jupyter, chosen deliberately:

- **Reactive, dependency-graph execution** (Pluto/Observable-style)
  instead of an imperative, order-dependent kernel — fits the purity of
  Elm and the query language naturally, and eliminates Jupyter's classic
  stale-output footgun by construction.
- **Typed handoff between query cells and view cells** — a query cell's
  inferred row type (including custom ADTs) flows into Elm as a real
  type, not an untyped DataFrame/JSON boundary. Schema drift becomes a
  compile error on the cell you edited, not a runtime surprise three
  cells later.
- **DuckDB runs in-browser via duckdb-wasm.** A saved, already-run
  notebook can be exported as a single static HTML file with no server
  — matching Observable/Pluto's sharing story. Tradeoff accepted: this
  targets local, file-sized data exploration, not fronting a
  warehouse-scale DuckDB instance (no custom extensions, browser
  storage-quota ceiling, no larger-than-RAM spilling). A "daemon owns
  DuckDB natively" mode is a possible later addition, not the default.
- **Compilation stays local**, never a hosted multi-tenant service —
  both the Elm compiler and the query-language compiler are native
  toolchains with no browser build, and running someone else's
  compiler as a shared cloud service isn't something we want to build
  the whole design around, especially once real user schemas/data are
  involved.

## Phase 0 — Resolve the Acadia dependency (decision gate)

Acadia (https://acadia.engineering/) is a closed-source, commercially
distributed language with no public grammar or compiler source. Two
paths:

- **(a) Partner with Acadia's team** for a licensed way to embed their
  compiler in a local daemon. Outside our control; not something to
  schedule around.
- **(b) Build our own small Acadia-*inspired* DSL** — same pipeline
  spirit (`access | filter | map | reduce | intersect | select`), fully
  owned, no licensing dependency, buildable immediately.

**DECIDED 2026-08-29: (b).** We build our own DSL. Treat (a) as an
opportunistic parallel track, not a blocker. Everything below assumes (b).

## Phase 1 — Reactive engine skeleton (no real compiler yet)  [SPIKED]

- Elm notebook-shell UI: cell list, add/edit/delete, markdown rendering
  for prose cells.
- DAG engine: free-identifier extraction per cell, topological
  re-execution, cycle detection, stale/blocked-cell marking.
- Two content-hash caches: compile cache, value cache.
- Compilation is stubbed/faked at this stage. Goal: prove the execution
  model before language complexity enters.

## Phase 2 — DuckDB-wasm + a hand-written spike  [SPIKED]

- Embed duckdb-wasm; load a local file.
- Hand-write one raw-SQL query cell and a hand-written Elm decoder to
  validate the riskiest integration point (Arrow/JS -> typed Elm) with
  the fewest moving parts, before any codegen exists.

## Phase 3 — The DSL and its compiler

- Formal grammar (PEG) for the pipeline subset: `access`, `filter`,
  `map`, `reduce`, `intersect`, `select`/`selectAll`, lambda +
  field-accessor syntax, `type X = A | B` ADTs, basic type annotations.
- Parser + type checker against DuckDB's column types.
- Two codegen targets from one typed AST, deliberately co-derived so
  they can't drift: SQL text, and an Elm module (record alias +
  decoder).
- Unit-test against fixtures in isolation before wiring into anything
  live.

## Phase 4 — Compile daemon + per-cell module scheme

- Native local process owning the on-disk per-cell module tree
  (`Cell_<id>.elm` / `Cell_<id>.dsl`), shelling out to `elm make`
  (inheriting its `elm-stuff` incremental cache) and the DSL compiler.
- Stateless protocol over a local socket:
  `compile(cellId, kind, source, depSignatures) -> Ok(js, signature) | Err(diagnostics)`.
- Validate: editing one cell in a multi-cell notebook only triggers
  recompilation of it plus downstream importers.

## Phase 5 — Wire it all together

- Connect Phase 1's DAG engine to Phase 4's real compiled output and
  Phase 2's real query execution. First point where "edit a query
  cell, downstream chart updates" works end to end.
- Stale/blocked-cell UX, per-cell compiler-error surfacing.

## Phase 6 — Display verbs + input widgets

- `table` / `barChart` / `lineChart` / `scalar` / `json` as pipeline
  terminators compiling to Vega-Lite specs, rendered by one generic
  `vega-embed` mount.
- Widget cells (`input.range` / `input.select` / `input.dateRange`) as
  graph nodes with no compile step — just a bound value that
  re-triggers the graph on change.

## Phase 7 — File format

- Markdown container with typed fenced code blocks (Acadia-DSL, Elm,
  input-widget config) interleaved with prose.
- Cell identity = binding name (not a hidden UUID) — renaming is a real
  identity change.
- File preserves user-controlled reading order, independent of the
  computed topological execution order.
- Outputs, generated modules, and compiled JS are never persisted in
  the file — rebuilt from source on load, cached in a sibling
  build-cache directory keyed by (cell id, source hash).
- Confirm round-trip load/save and clean single-cell git diffs.

## Phase 8 — Sharing story

- "Export as static artifact": bake compiled JS + snapshotted/OPFS
  data into a single shareable HTML file, viewable with no daemon.
- Promote hand-authored Elm escape-hatch cells (structurally supported
  since Phase 4) to a polished, documented feature.

## Current state (2026-08-29)

The Phase 1+2 spike is built and runs. `mise run build` compiles the
shell, `mise run serve` hosts it on :8080, `mise run test` runs 32
engine checks under node (all passing).

What exists:

- `src/Deps.elm` — syntactic identifier extraction (skips comments and
  string literals, collects quoted identifiers).
- `src/Dag.elm` — graph build, topological sort with file order as the
  tie-break, cycle detection, downstream closure.
- `src/Engine.elm` — value-cache keys, stale marking, upstream blocking.
- `src/Main.elm` — notebook shell; edits mark downstream stale on every
  keystroke, execution is committed on blur.
- `src/Spike/Orders.elm` — the hand-written typed decoder standing in
  for Phase 3 codegen (opaque id, ADT rebuilt from two columns,
  `Time.Posix`).
- `public/duckdb-bridge.js` — materialises each cell as a temp table,
  returns a preview plus an in-database content hash.

Findings worth carrying into Phase 3:

- DuckDB's default integer is BIGINT, so almost every id column crosses
  the bridge as a JS BigInt. Generated decoders cannot assume `Int`
  survives the trip untouched; the bridge widens to Number only when
  the value is a safe integer and falls back to a string otherwise, so
  a decoder fails loudly rather than silently truncating.
- The content hash is computed in SQL (`md5(string_agg(...))`) to avoid
  pulling whole results into JS, but aggregating in row-text order makes
  it order-insensitive: a pure reordering does not invalidate
  dependents. Verified directly against the CLI. The DSL will need to
  say whether a cell's row order is significant.
- Cells are materialised as temp tables, not views. With views every
  downstream query silently re-executes its whole upstream chain, which
  makes the value cache meaningless.
- Cycle detection has to survive partial graphs: an acyclic cell sitting
  beside a cycle must still be reported separately from the cycle.

## Next up

Phase 3: the DSL grammar, type checker, and the two co-derived codegen
targets. `Spike.Orders` is the exact shape the Elm target must emit.
