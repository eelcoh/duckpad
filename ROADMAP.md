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

## Phase 3 — The DSL and its compiler  [DONE]

- Formal grammar (PEG) for the pipeline subset: `access`, `filter`,
  `map`, `reduce`, `intersect`, `select`/`selectAll`, lambda +
  field-accessor syntax, `type X = A | B` ADTs, basic type annotations.
- Parser + type checker against DuckDB's column types.
- Two codegen targets from one typed AST, deliberately co-derived so
  they can't drift: SQL text, and an Elm module (record alias +
  decoder).
- Unit-test against fixtures in isolation before wiring into anything
  live.

### Phase 3 as built

Written in Elm rather than as a native binary. The Phase 4 daemon exists
because `elm make` has no browser build; our own compiler has no such
constraint, so it runs client-side. Query cells therefore need no daemon
at all, and a shared static notebook can recompile its own queries. Only
hand-written Elm escape-hatch cells still require the daemon, which
shrinks Phase 4 rather than growing it.

Modules, all under `src/Dsl/`:

- `Schema.elm` — the type language and the DuckDB type mapping.
- `Ast.elm` — surface syntax.
- `Parser.elm` — `elm/parser`, lexeme style. Binary operators are read by
  maximal munch into a flat list and folded by precedence afterwards,
  which is what keeps `/` from biting off half of `/=` and forcing the
  grammar to backtrack.
- `Check.elm` — AST + schema into a typed IR.
- `Sql.elm` and `ElmGen.elm` — the two renderings of that one IR.
- `Compile.elm` — the front door.

The language:

    type Status
      = Submitted "submitted"
      | InTransit "in_transit"
      | Delivered "delivered" from .delivered_at

    access orders ()
      |> filter (\o -> o.total > 100.0)
      |> map (\o -> { owner = o.owner, status = o.status as Status })
      |> selectAll

Stages: `access`, `filter`, `map`, `groupBy`, `reduce`, `sortBy`,
`limit`, `intersect`, `select`, `selectAll`. Aggregates: `count`, `sum`,
`avg`, `min`, `max`.

Decisions worth remembering:

- The checker enforces SQL's grouping rule at the language level: inside
  `reduce`, a bare column is only legal if it is the grouping key.
  "column must appear in the GROUP BY clause" becomes a message about
  the cell being edited.
- A constructor's `from .column` payload makes the compiler select a
  column the row type does not expose. Hand-written pairs drift exactly
  here, which is the case for co-deriving both artifacts from one IR.
- `select` generates `Maybe Row`, not `Row`. A query matching nothing is
  an ordinary outcome. Rejecting a result that has more than one row is
  a runtime concern and lands in Phase 5.
- `Compiled.reads` is exact, so the syntactic `Deps.identifiers` guess
  can be retired for DSL cells when Phase 5 wires this in.
- `Compiled.orderSignificant` is true only when a cell sorts or limits,
  which is what the order-insensitive content hash needs in order to be
  safe.

Deliberately not in Phase 3, and each an honest gap rather than an
oversight:

- Joins. Only `intersect` combines two tables.
- `filter` after `groupBy`, i.e. HAVING. Rejected with a message saying
  to move the filter earlier.
- Opaque newtype wrappers (`type OrderId = OrderId UInt64`). Only
  enum-style ADTs with string wire tags are supported; the mechanism for
  attaching a declared type to a column is proven, the wrapper shape is
  not built.
- User-defined functions and modules, which real Acadia has.

Verified by 124 checks in `mise run test`, plus `mise run roundtrip`,
which executes every fixture's generated SQL against a real DuckDB built
from the sample CSV and puts every generated module through `elm make`.
That harness was negative-controlled: deliberately corrupting codegen
makes it fail.

## Phase 4 — Compile daemon + per-cell module scheme

- Native local process owning the on-disk per-cell module tree
  (`Cell_<id>.elm` / `Cell_<id>.dsl`), shelling out to `elm make`
  (inheriting its `elm-stuff` incremental cache) and the DSL compiler.
- Stateless protocol over a local socket:
  `compile(cellId, kind, source, depSignatures) -> Ok(js, signature) | Err(diagnostics)`.
- Validate: editing one cell in a multi-cell notebook only triggers
  recompilation of it plus downstream importers.

## Phase 5 — Wire it all together  [DONE]

- Connect Phase 1's DAG engine to Phase 4's real compiled output and
  Phase 2's real query execution. First point where "edit a query
  cell, downstream chart updates" works end to end.
- Stale/blocked-cell UX, per-cell compiler-error surfacing.

### Phase 5 as built

Query cells are now DSL cells, compiled in the browser. No daemon exists
and none is needed.

The ordering problem and how it is solved: compiling a cell needs the row
types of the cells upstream of it, but knowing which cells those are
needs the graph, which needs the compilation. Parsing breaks the cycle —
a cell's source and its `intersect` targets are syntax, so
`Dsl.Compile.readsOf` builds the graph from the parse alone, and the
checker then runs in topological order against a schema that accumulates
as it goes. A cell that does not parse reads nothing, so it becomes an
isolated node reporting its own error instead of corrupting the order.

Both caches are now real and they answer different questions:

- The **compile cache** asks whether the SQL could have changed, keyed on
  the source and on the *row types* of the inputs.
- The **value cache** asks whether the rows could have changed, keyed on
  the generated SQL and on the *values* of the inputs.

An upstream edit that produces new rows of the same shape invalidates the
second and not the first. There is a test pinning exactly that.

Retired, because the compiler now knows better:

- `src/Deps.elm`. The syntactic identifier scan is replaced by
  `Compiled.reads`, which is exact. A string literal that happens to name
  a cell is no longer a dependency, and that now falls out of parsing
  rather than needing a special case in a tokeniser.
- `src/Spike/Orders.elm`. The hand-written decoder it existed to
  discover is what `Dsl.ElmGen` emits.

Bridge changes:

- It builds the base tables at boot and reports their schema, so the
  checker knows what `access` may name before any cell has run.
- Nullability is observed from the data, not read off the declaration.
  A table built by CREATE TABLE AS carries no NOT NULL constraints, so
  `information_schema` calls every column nullable and the row type would
  drown in `Maybe`. Counting nulls answers the question the notebook
  actually has.
- The content hash is now order-aware. `orderSignificant` from the
  compiler picks between folding rows in sorted order (cheap,
  deterministic, blind to a reordering) and folding them as they lie.
  This closes the Phase 2 finding.

The notebook renders results against the compiler's row type rather than
against whatever JSON arrived, so a timestamp shows as a date and a
custom-typed column shows as its constructor with its payload. Each cell
also has a `generated` panel showing its SQL and its Elm module side by
side.

## Phase 6 — Display verbs + input widgets

- `table` / `barChart` / `lineChart` / `scalar` / `json` as pipeline
  terminators compiling to Vega-Lite specs, rendered by one generic
  `vega-embed` mount.
- Widget cells (`input.range` / `input.select` / `input.dateRange`) as
  graph nodes with no compile step — just a bound value that
  re-triggers the graph on change.

## Phase 7 — File format  [DONE]

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

### Phase 7 as built

A notebook is Markdown. Query cells are fenced blocks tagged `acadia`
plus a name; everything else is prose:

    ---
    title: Orders
    ---

    Intro prose.

    ```acadia delivered
    access orders ()
      |> filter (\o -> o.status == "delivered")
      |> selectAll
    ```

One decision changed from the sketch: **prose has no identity**. The
original plan gave every cell a name, but in a Markdown container prose
is just the text between the fences, and naming it would put a label in
the file that nothing can refer to. Only query cells are named, because
only they are bindings. The model still needs a key for prose state, so
one is assigned on load and never written back.

Everything else held. Reading order is the file's order and is never
sorted into dependency order. Results, generated SQL and generated Elm
are not in the file. The parser only takes an interest in an `acadia`
fence, so a notebook can contain a shell snippet or a JSON sample
without confusing it.

The diff property is tested rather than asserted: editing one cell's
body changes exactly the one line it changed, and renaming a cell
changes exactly its fence line.

Deviation from the plan: there is no sibling build-cache directory,
because there is no daemon and no filesystem to put one in. The compile
and value caches already hold what it would have held, keyed the same
way.

Persistence has two layers, and they are not the same thing. The
document is a file the reader saves, through the File System Access API
where it exists and an ordinary download where it does not. Underneath
that, every edit is mirrored into `localStorage` purely so a reload does
not lose work; a buffer that no longer parses is reported rather than
silently discarded.

## Phase 8 — Sharing story

- "Export as static artifact": bake compiled JS + snapshotted/OPFS
  data into a single shareable HTML file, viewable with no daemon.
- Promote hand-authored Elm escape-hatch cells (structurally supported
  since Phase 4) to a polished, documented feature.

## Current state (2026-08-29)

`mise run build` compiles the shell, `mise run serve` hosts it on :8080,
`mise run test` runs 145 checks under node, and `mise run roundtrip`
executes every fixture's generated SQL against a real DuckDB and compiles
every generated module with `elm make`.

Layout:

- `src/Dsl/` — the compiler: `Schema`, `Ast`, `Parser`, `Check`, `Sql`,
  `ElmGen`, `Compile`.
- `src/Dag.elm`, `src/Engine.elm`, `src/Hash.elm` — the reactive engine.
- `src/Notebook.elm` — the Markdown file format.
- `src/Main.elm` — the notebook shell.
- `public/duckdb-bridge.js` — base tables, schema reporting, query
  execution, content hashing.

Standing findings:

- DuckDB's default integer is BIGINT, so almost every id column crosses
  the bridge as a JS BigInt. The bridge widens to Number only when the
  value is a safe integer and falls back to a string otherwise, so a
  generated decoder fails loudly rather than silently truncating.
- Cells are materialised as temp tables, not views. With views every
  downstream query silently re-executes its whole upstream chain, which
  makes the value cache meaningless.
- Cycle detection has to survive partial graphs: an acyclic cell sitting
  beside a cycle must still be reported separately from the cycle.

## Next up

Phase 6 (display verbs and input widgets) is the last piece of the
original design that is not built. Phase 8 (export a run notebook as one
static HTML file) is now mostly a packaging job, since the compiler
already runs in the browser.

Phase 4 has shrunk to "a daemon for hand-written Elm cells" and is only
needed once those are wanted.
