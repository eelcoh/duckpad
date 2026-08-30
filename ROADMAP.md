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

## Data sources  [DONE]

Not in the original plan, and it should have been: until this, every
notebook could only query one bundled CSV, which made the whole thing a
demo rather than a tool. It also comes first in dependency order —
joins are pointless over a single table, and export cannot be designed
until it is known how data gets in.

A source is its own cell kind with its own fence:

    ```source weather
    csv "https://cdn.jsdelivr.net/npm/vega-datasets@2/data/seattle-weather.csv"
    ```

Formats are `csv`, `parquet` and `json`. Locations are https URLs or
paths next to the notebook.

Decisions:

- **A source becomes a view, not a materialised table.** A source is a
  reference to external data, not a computed value, and the difference
  is load-bearing: a view lets DuckDB push filters and column pruning
  into the file, so a query over a remote Parquet fetches the byte ranges
  it needs. Materialising would pull every row into wasm memory and make
  HTTP range requests pointless. Query cells still materialise, so the
  value cache is unaffected.

  Measured in the browser: the three-million-row, 13 MB
  `flights-3m.parquet` loads as a source in **297 ms** over https. That
  number is the evidence for both this decision and the metadata one
  below — before nullability was read from the file footer, the same
  source was slow enough to notice.
- **A source's identity is where it points, not what is behind it.** Its
  hash is format, URI and row count. The notebook does not refetch to
  discover whether a remote file changed; the row count is carried along
  so a file that grew or shrank still invalidates dependents, which is
  free to know for Parquet.
- **The URI never reaches SQL.** The file is registered under a generated
  name and only that name is interpolated.
- **Schemes are restricted at parse time.** `file:`, `data:` and
  `javascript:` are refused, as is plain http except on localhost. The
  first attempt tested for `://` and let `data:` and `javascript:`
  through as relative paths; the tests caught it.
- **Nullability comes from Parquet's own metadata where it exists.**
  Every column chunk carries a null count in the file footer, so the
  answer is exact for the whole file and costs one metadata read.
  Measured against the CLI: 0.05s for three million rows, against 0.14s
  to sample 200k. For CSV and JSON, which cannot say, it is sampled up
  to a cap — a column whose only nulls lie past the cap renders as `?`
  rather than failing silently.
- The hardcoded base table is gone. The seeded notebook uses a source
  cell, so the mechanism is the only path in. It ships two: `orders` and
  `customers`, keyed on `owner` so the combining stages have something
  real to work on. `hugo` has orders but no customer record and `iris`
  the reverse, so swapping `intersect` for `diff` or `exclude` visibly
  changes the result.

### The seeded notebook

The notebook ships pointed at `vega-datasets`, the one open-data pairing
found so far that is both genuinely relational and CORS-clean.
`flights.origin` joins to `airports.iata`. Requiring the network for the
seeded data is not a new dependency: duckdb-wasm itself is fetched from
a CDN, so the page has never worked offline.

Its cells are `by_state` (a big-by-small star join, grouped and ranked),
`routes` (the same table joined twice) and `quiet` (an anti-join, with
`country` cast to a declared type — the column has exactly five values
in the data, so the cast is exhaustive). Every one of them is also a
roundtrip fixture, checked against local stand-in tables whose schemas
match what DuckDB infers from the real files, so the tests stay offline.

The notebook lives in `src/Seed.elm` and is written out to
`public/notebooks/flights.acadia.md` by `mise run seed`, which `build`
depends on. The shipped example is therefore the starting notebook
rather than a copy that has to be kept in step, and it is the only
worked example of the file format outside the tests. The emitter also
parses what it wrote and re-serialises it, so the format is checked
against real content and not only against fixtures.

| File | Size | Role |
|---|---|---|
| `vega-datasets@2/data/airports.csv` | 3,376 rows | dimension: iata, name, city, state, country, latitude, longitude |
| `vega-datasets@3.2.0/data/flights-3m.parquet` | 3M rows, 13 MB | fact: date, delay, distance, origin, destination |
| `vega-datasets@2/data/flights-5k.json` | 445 KB | same columns, small, for fast iteration |

It exercises every case at once:

- A big-by-small star join, which is the shape real analytics has.
  Measured against the CLI: 3M rows joined and grouped in 0.78s
  including the HTTP fetch, because DuckDB pruned to the two columns it
  needed.
- **The same table joined twice.** `origin` and `destination` both point
  at `airports`, so `intersect .origin airports .iata |> intersect
  .destination airports .iata` puts `airports` and `airports_2` in scope
  together. This is the case the earlier flat-merge design could not
  express at all, and the clearest demonstration of why rows are paired.
- Real asymmetry, in one direction only: every flight origin matches an
  airport, but 3,147 airports have no departures. Putting airports on
  the left gives `diff` and `exclude` something to show.

Two limitations this data surfaced, both real:

- The obvious "busiest city pairs" query needs two cells. After joining
  `airports` twice, `groupBy .city` is ambiguous, and `map` moves the
  pipeline past the phase where `groupBy` is allowed — so one cell
  projects the join and the next groups it. `groupBy` also takes a
  single accessor, so grouping by a pair of columns is not expressible
  at all.
- Keywords could not be used as column names, which meant the language
  could not read a column called `from`, `to`, `type` or `select` —
  and real data has all of those. Fixed: after a dot, and naming a
  record field, any identifier is allowed. Lambda parameters and table
  names stay restricted, because those do sit where a keyword could
  appear.

In `flights-5k.json` the `date` column is VARCHAR and `delay` is
HUGEINT, where the Parquet has TIMESTAMP and BIGINT. A useful accidental
test of the type mapping.

### Data sources that work from a browser

CORS is the binding constraint, and it is not guessable — these were
checked with a real preflight rather than assumed. All send
`access-control-allow-origin: *` and support range requests.

| Dataset | URI | Why |
|---|---|---|
| Seattle weather | `https://cdn.jsdelivr.net/npm/vega-datasets@2/data/seattle-weather.csv` | 1461 rows. A DATE, four DOUBLEs, and a `weather` column with exactly five values — an ideal `as` cast. The best default. |
| Stocks | `https://cdn.jsdelivr.net/npm/vega-datasets@2/data/stocks.csv` | Small time series, symbol/date/price. Good for Phase 6 charts. |
| Movies | `https://cdn.jsdelivr.net/npm/vega-datasets@2/data/movies.json` | 1.4 MB, exercises the JSON reader and a messier schema. |
| Flights | `https://cdn.jsdelivr.net/npm/vega-datasets@3.2.0/data/flights-3m.parquet` | Three million rows in 13 MB. The real test of Parquet over HTTP: DuckDB reads the schema and a preview from metadata and byte ranges without pulling the file. |

Checked and rejected:

- **NYC TLC trip data** (`d37ci6vzurychx.cloudfront.net`) sends no CORS
  header at all. It is the dataset everyone reaches for and it cannot be
  read from a browser.
- **palmerpenguins** encodes missing values as the string `NA`, so
  DuckDB types every numeric column as VARCHAR and finds no nulls. It
  needs a null-string option the source language does not have — a fair
  argument for adding reader options later.

## Combining rows  [DONE]

    access orders ()
      |> intersect .owner customers .owner
      |> map (\(o, c) -> { who = o.owner, tier = c.tier })
      |> selectAll

`intersect` is an inner join, `diff` a left join, `exclude` an anti-join.
The vocabulary is Acadia's own, and so is the shape.

### What the real Acadia docs changed

This was first built as `join`/`leftJoin` taking a boolean predicate and
producing a flat merged row, with an equi-join on a shared name compiled
to `USING` and any other shared name a compile error. That was invented,
not borrowed: the DSL had been designed from the homepage's marketing
copy, which names only `map`, `filter`, `reduce` and `intersect`.

Acadia's full API documentation turns out to be public, just not linked
as a file. The site is an Elm SPA that fetches hashed assets under `/_/`;
fetching a page and grepping for `/_/[a-f0-9]+\.(md|json)` finds them.
`b402657d…json` is the complete docs.json, 28 modules. The language is by
Evan Czaplicki, the creator of Elm.

Its `Rows` module has joins under set-operation names:

    intersect : (a -> key) -> Rows a -> (b -> key) -> Rows b -> Rows ( a, b )
    diff      : (a -> key) -> Rows a -> (b -> key) -> Rows b -> Rows ( a, Maybe b )
    exclude   : (a -> key) -> Rows a -> (b -> key) -> Rows b -> Rows a

Two of those ideas are better than what had been built here, and both
were adopted:

- **Key extractors, not a predicate.** These are equi-joins by
  construction. There is no way to write a non-equi join, and therefore
  no way to write an accidental cross product.
- **Paired rows, not merged ones.** Each side keeps its own namespace, so
  two tables that both have `id` need no renaming and no collision rule.
  The whole `USING`-plus-error mechanism was machinery solving a problem
  that only existed because rows were flattened. It is gone. A later
  lambda destructures instead: `\(o, c) -> …`, with arity checked against
  the number of sides. A table combined with itself gets a distinct alias
  and works, which the flat design could never have managed.

Also corrected: the old `intersect` stage was SQL `INTERSECT`, a set
operation over identical row types. That was a misreading of the verb
from a marketing list. Acadia has no SQL-style set operations at all —
`union` and `xunion` are key-based joins too. The stage is removed.

### Design notes

- The SQL aliases every table and qualifies every column, which is what
  lets sides keep separate namespaces.
- `groupBy` and columns inside `reduce` take a bare accessor with no
  pattern to disambiguate them, so they resolve across sides and refuse
  an ambiguous name rather than guessing.
- A pipeline that combines tables must project with `map` before
  selecting: the output row has to be a record.
- `exclude` contributes no columns, so it adds no side and becomes a
  `NOT EXISTS` in the WHERE clause.

### Still divergent from real Acadia

- Acadia's `Rows` are first-class values combined by a function over two
  of them; ours is a single pipeline per cell, so combining is a stage
  and the right side is named rather than piped.
- `select` there returns exactly one row and `selectMaybe` returns
  `Maybe`. Ours has only `select`, which behaves as `selectMaybe`.
- `groupBy` there takes a `Reducer` directly and yields `(key, summary)`
  pairs. `Reducer` is an applicative built from `count`, `min`, `max`,
  `median`, `mode` and `percentile` with `map2..map9` — and notably has
  no `sum` or `avg`.
- `access foods Security.Unrestricted` passes a security policy where
  ours writes `()`. Row-level security is not modelled here at all.
- No `union`/`xunion` (full outer joins).

### The principle behind all of it

Acadia has no recursion and no `for` loops, deliberately, because Datalog
is Prolog without unbounded recursion. That buys three guarantees: the
1+N query problem cannot be expressed, all queries terminate, and all
queries terminate in time polynomial to the data. Our DSL inherits the
same guarantees for the same reason — it has no recursion and no
user-defined functions — which is worth stating explicitly before anyone
adds either.

## Editor and presentation

The cell surface is a plain `<textarea>` over hand-written CSS, which was
enough to get the engine working and is now the weakest part of the
notebook. Four changes, in the order they should be done:

1. ~~**Suppress the spell checker.**~~ Done. `spellcheck False` on the
   textarea, with `autocorrect`, `autocapitalize` and `autocomplete` off
   so mobile keyboards do not rewrite code.

2. ~~**A monospace font with programming ligatures.**~~ Done. Fira Code
   from Google Fonts, with `IBM Plex Mono` and the system monospace
   behind it. IBM Plex Sans is loaded too — it was named in the stack
   from the start but never actually fetched. Ligatures are stated
   explicitly through `calt` rather than left to the face's defaults, so
   a fallback that also has them behaves the same.

   Also done, and not on the original list: **prose renders as
   Markdown.** It was shown as its own source, so a heading appeared as
   `# Notes` and the narrative half of a notebook read like a diff. A
   prose cell now renders and becomes a textarea when clicked, through
   `dillonkearns/elm-markdown` with raw HTML left off — a notebook is a
   thing people pass around. Spell-checking is on for prose and off for
   code, which is the right way round and was not before.

3. ~~**Keyboard editing.**~~ Done, and not on the original list. A
   textarea's own Enter goes to column zero, which loses the indentation
   on every line of a pipeline, and its own Tab leaves the field
   entirely. Both are intercepted now: Enter starts the new line at the
   indent of the one before it, one step deeper after a line that opens
   a bracket or ends in a lambda arrow; Tab indents, and shifts a whole
   block when the selection covers more than one line; Shift-Tab goes
   back out.

   Deliberately **not** an auto-formatter. The layout these cells are
   conventionally written in is hand-aligned in the Elm style — a
   record's `{` lines up under what it belongs to, not at a multiple of
   two — and a rule trying to reproduce that would be wrong more often
   than right, and would fight the author when it was. It never loses
   ground; going back out is explicit rather than guessed.

   The logic is in `src/Indent.elm` with tests, because it is entirely
   off-by-one positions. Elm owns the textarea's value, so a synthetic
   edit moves the caret to the end; a port puts it back on the next
   frame.

4. **Colour coding.** The interesting part is that the notebook already
   has a real lexer, so highlighting can be driven by `Dsl.Parser`'s own
   tokens rather than by a regex approximation. Highlighting would then
   agree with the compiler by construction — the same property the SQL
   and Elm outputs already have — and the same pass could underline the
   exact span of a type error instead of printing a line and column.

   The mechanism is the awkward part. A `<textarea>` cannot style its
   own contents, so the usual approach is a transparent textarea over a
   highlighted `<pre>`, with scroll position and metrics kept in sync.
   That is fiddly but has no dependency. The alternative is CodeMirror 6
   through a custom element, which is a large dependency and puts the
   editing model outside Elm. Prefer the overlay; reconsider only if
   selection or IME handling turns out badly.

5. **Rebuild the view on elm-ui** (`mdgriffith/elm-ui`, pin 1.1.8 for
   Elm 0.19; version 2 is not released). Layout becomes Elm values
   rather than a stylesheet, which suits a UI whose structure is already
   computed — cell states, staleness, the execution-order strip.

   One tension to plan around: items 4 and 5 pull against each other.
   The highlight overlay needs exact text metrics and absolute
   positioning, which is precisely what elm-ui abstracts away. The
   workable split is elm-ui for the shell — chrome, cell frames, status
   pills, tables, the generated-artefact panels — and a raw
   `Element.html` escape hatch for the editor surface itself, which
   keeps its own CSS. Doing 4 before 5 means the editor's CSS is already
   isolated when the rest is converted.

## Phase 8 — Sharing story

- "Export as static artifact": bake compiled JS + snapshotted/OPFS
  data into a single shareable HTML file, viewable with no daemon.
- Promote hand-authored Elm escape-hatch cells (structurally supported
  since Phase 4) to a polished, documented feature.

## Current state (2026-08-29)

`mise run build` compiles the shell, `mise run serve` hosts it on :8080,
`mise run test` runs 182 checks under node, and `mise run roundtrip`
executes every fixture's generated SQL against a real DuckDB and compiles
every generated module with `elm make`.

Layout:

- `src/Dsl/` — the compiler: `Schema`, `Ast`, `Parser`, `Check`, `Sql`,
  `ElmGen`, `Compile`.
- `src/Dag.elm`, `src/Engine.elm`, `src/Hash.elm` — the reactive engine.
- `src/Notebook.elm` — the Markdown file format.
- `src/Dsl/Source.elm` — the source-cell language.
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

The editor and presentation work above is the most visible improvement
available, and its first item is a one-line fix.

Otherwise, in dependency order: Phase 6 (display verbs and input
widgets), then Phase 8 (static export, which has to serialize whatever
cell kinds exist by then).

Smaller known gaps: HAVING (`filter` after `groupBy`), opaque newtype
wrappers, reader options for sources such as a null string or an
explicit delimiter, and `union`/`xunion` (full outer joins).

Phase 4 has shrunk to "a daemon for hand-written Elm cells" and is only
needed once those are wanted.
