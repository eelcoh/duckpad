# Roadmap: duckpad, a reactive notebook over DuckDB

## Concept summary

A Jupyter-alternative notebook environment built around a functional,
statically-typed query language (Acadia-inspired; see the naming note) for
data cells and Elm
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

## What this is, and what it is not

**DuckDB, through an Elm/Acadia-inspired interface.** The engine is
DuckDB's; the contribution here is a typed, total, reactive surface over
it. That sentence settles most scope questions on its own:

- If DuckDB already does a thing, exposing it is in scope, and the work
  is a name, a type rule and a spelling.
- If it would mean inventing semantics DuckDB does not have, it is
  probably not worth it. Complex features are the failure mode to avoid,
  not the goal.
- Names are Elm-ish rather than SQL-ish — `startOfDay`, not
  `date_trunc` — because the interface is the point. The *semantics*
  stay DuckDB's.

The corollary is the escape-hatch decision recorded further down: a
second engine beside DuckDB is exactly the kind of complexity this rules
out, and it would cost the totality guarantee besides.

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

### Display verbs  [DONE]

    |> barChart { x = .state, y = .departures }

`barChart`, `lineChart` and `scatter` are terminators like `selectAll`:
the cell's value is still its rows, and the verb says how to show them.
Channels are a record of names to accessors rather than positional
arguments, because a chart has optional channels and no reading order
stays clear once `color` is one of them.

What makes generating the spec worth it: Vega-Lite needs every channel
annotated as quantitative, nominal or temporal, and those annotations
are normally typed by a person and quietly wrong — a number read as a
category, a date read as a string, and a chart that renders something
plausible and false. Here the annotation is derived from the column type
the compiler already worked out, and a `y` that is not a number is a
compile error rather than an empty picture.

Drawn by a custom element rather than a port, because the lifecycle is
the hard part: a port would have to find a div that may not exist yet
and clean up after one that has gone, whereas Elm creates and removes a
custom element like any other node. Vega is over a megabyte, so it is
imported the first time a chart appears and a notebook of tables never
pays for it.

A chart asks the database for more rows than a table does. A table only
shows a screenful, but a chart of the first two hundred points of a
series is a misleading picture rather than a partial one.

The seeded notebook uses all three: `by_state` is a bar chart,
`delay_by_distance` a line over 1,109 distinct distances, and
`airport_map` a scatter of longitude against latitude, which is
recognisably a map of the United States.

Not built, and each recorded rather than worked around:

- `scalar`, which wants a single number and cannot be reached until a
  global aggregate with no `groupBy` is expressible. One job, not two.
- `json` was dropped as not worth a verb.
- ~~No scalar functions at all.~~ Added: `startOfDay`, `startOfMonth`,
  `startOfYear`, `year`, `month`, `dayOfWeek`, `round`, `roundTo`,
  `abs`, `floor`, `ceiling`, `lower`, `upper`, and `++` for text.
  Applied by juxtaposition — `round o.total`, `roundTo 1 (avg g.delay)`
  — which binds tighter than any operator. Recognised by position like
  the aggregates, so a column or a lambda parameter called `round` or
  `month` still works.

  Each result type is fixed by the checker rather than read back from
  DuckDB, which is what lets a truncated timestamp reach a temporal axis
  and a rounded number count as an integer. The SQL casts `round`,
  `floor` and `ceiling`, because DuckDB returns a double for all three
  and the column type would otherwise disagree with the value.

- ~~Grouping by a computed value.~~ `groupBy` now takes a lambda as
  well as bare accessors:

      |> groupBy (\f -> { day = startOfDay f.date })

  A lambda rather than a bare expression, because a computed key needs a
  name of its own — `reduce` says `g.day`, and there is no column called
  `day` to point at — and a lambda is how every other stage already
  names things. Bare accessors still work for the common case, where the
  key is a column and takes its own name.

  Reading a key inlines its expression rather than referring to the
  alias, which sidesteps the question of whether a SELECT alias is
  visible to its own GROUP BY.

  This is what finally reaches the `temporal` channel: the seeded
  notebook's `daily` cell turns 213,834 minute-resolution timestamps
  into 182 days and draws them as a line.
- The category palette has seven colours, so a `color` channel over more
  than that many values will cycle. Fine for a handful of series, wrong
  for fifty states.

### Input widgets  [DONE]

    ```input min_distance
    range 0 2500 step 250 default 0
    ```

`range` and `select`. An input is a cell like any other, with its own
fence in the file, and it is a graph node with no compile step: its
value is bound to the cell's name, and a query mentioning that name
depends on it.

**The value is inlined into the SQL rather than passed as a query
parameter**, and that is the whole design. Moving a control changes the
generated SQL, which changes the cell's cache key, which re-runs exactly
what reads it. The reactive machinery needed no special case for widgets
at all — the two caches that were already there do the work.

One thing did need adjusting. The compile cache keys a cell on the *row
types* of what it depends on, and an input has no row type, so a moved
slider would have handed back a stale query. An input's signature is now
its value, which is correct for the same reason: its value is what its
dependents compile against.

Dependencies come from free variables in the parse — names no lambda
bound — which is what puts the input ahead of its readers in the graph
without a schema being involved.

Not built: `dateRange`, which wants two values and date parsing, and
options drawn from a query rather than written out, which would make a
widget depend on a cell and is a real design question rather than a
missing case.

## Phase 7 — File format  [DONE]

- Markdown container with typed fenced code blocks (the DSL, Elm,
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

A notebook is Markdown. Query cells are fenced blocks tagged `duckpad`
plus a name; everything else is prose:

    ---
    title: Orders
    ---

    Intro prose.

    ```duckpad delivered
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
are not in the file. The parser only takes an interest in a `duckpad`
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
`public/notebooks/flights.duckpad.md` by `mise run seed`, which `build`
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

- Grouping by a pair of columns used to be impossible, so the busiest
  routes could not be asked for at all. `groupBy` now takes one or more
  accessors — `groupBy .origin .destination` — written as repeated
  accessors rather than a list, because the language has no list syntax
  and `intersect .a t .b` already reads that way.

  The *city-name* version of that query still needs two cells, for a
  different reason: after joining `airports` twice both sides have a
  `city`, and an accessor cannot say which side it means. One cell
  projects the join, the next groups it. Naming a side in a `groupBy`
  would need syntax the language does not have, and two cells is not a
  bad answer in a notebook.
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

4. ~~**Colour coding.**~~ Done, as an overlay: a coloured `<pre>` with a
   transparent textarea exactly on top of it. No dependency, and the
   editing model stays in Elm, which CodeMirror would have taken out of
   it.

   `Dsl.Lexer` is separate from `Dsl.Parser` because the two want
   different things — a parser discards whitespace and comments and
   stops at the first error, a highlighter must account for every
   character and keep going — but they share `Dsl.Keywords`, so a word
   added to the grammar is coloured without anyone remembering to.

   The lexer is lossless, and that is mechanical rather than tidy: the
   coloured text sits under the textarea, so tokens that did not
   reconstruct the source exactly would drift the two layers apart and
   put the caret in the wrong place. Ten samples pin it. The same is
   true of the CSS — one rule serves both layers rather than two that
   happen to match today.

   Still available from this: the lexer could underline the exact span
   of a type error instead of the compiler printing a line and column.

5. ~~**Rebuild the view on elm-ui**~~ Done, on 1.1.8 (version 2 is not
   released). Layout is Elm values now, and the design tokens live in
   `src/Ui.elm`, so a colour or a font stack is something the compiler
   knows about rather than a rule that silently stops applying.

   The split the plan called for held. elm-ui took the chrome: the top
   bar, the title and cell-name fields, buttons, the notice, cell
   frames and headers, status pills, the dependency edges, and the
   generated-artefact disclosure. Three things stayed raw HTML, each
   for the same underlying reason — they need control elm-ui exists to
   take away:

   - The editor overlay. Two layers have to agree on exact text
     metrics, which is precisely what a layout abstraction removes.
   - Rendered Markdown, which is a tree of HTML by nature.
   - The result table, because a sticky header over a scrolling body
     is not something elm-ui expresses.

   Doing colour coding first paid off as expected: the editor's CSS was
   already isolated, so converting the rest did not touch it. The
   stylesheet went from roughly two hundred lines to those three
   concerns.

   One thing changed shape rather than moving across. The artefact
   panel was a native `details`/`summary`; elm-ui has no equivalent, so
   the open state is in the model. That is arguably better — the
   disclosure now survives a re-render instead of being the browser's
   private business — but it is a state the app did not previously have
   to hold.

## Phase 8 — Sharing story  [DONE]

The plan here said "bake compiled JS and snapshotted data into a single
shareable HTML file, viewable with no daemon". That was written when a
daemon was expected. There is no daemon, the page is already static, and
"viewable without one" has been true since Phase 5 — so the original
wording no longer describes anything missing.

What was actually missing is a **report**: the notebook as it currently
stands, results and all, for someone who wants to read what you found
rather than re-run it. `Export` writes a single page that carries no
database, fetches nothing, and does not need this application to open.

It works by snapshotting the rendered page rather than re-deriving it,
which is the only way to be certain the export shows what the reader was
actually looking at. Three things have to be repaired in the copy, and
each is a property of the DOM rather than an oversight:

- A chart lives in a canvas, and a cloned canvas is blank — its pixels
  are not markup. The image is read off the live page and inlined.
- A textarea's contents are a property, not markup, so a clone
  serialises empty. For a code cell the coloured layer underneath
  already shows the source, so the textarea goes; prose caught
  mid-edit becomes text.
- Every control is inert once the scripts are gone, so it should not be
  there at all. Chrome that only makes sense while the app is running
  is marked `data-export="drop"` in the view rather than guessed at by
  class name, since elm-ui's class names are opaque.

Note that the `.md` file and the export are different artefacts and both
are worth having: the Markdown is the document, diffable and re-runnable;
the export is a picture of one run of it.

Not built: promoting hand-authored Elm cells to a documented feature,
which still waits on a daemon that nothing else needs.

## Current state (2026-08-29)

`mise run build` compiles the shell, `mise run serve` hosts it on :8080,
`mise run test` runs 293 checks under node, and `mise run roundtrip`
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

## Remaining language work

Everything in the original plan is built. What is left are gaps that were
recorded as they were hit, in the order they are worth closing:

1. ~~**HAVING**~~ — done. `filter` after a projection reads as filtering
   what the projection produced, and does. Where it lands depends on
   whether there was a grouping: after a `reduce` the expressions
   contain aggregates and it becomes a HAVING; after a plain `map` there
   is nothing aggregated and a WHERE is correct. Both inline the
   projection's expression rather than naming the alias it is selected
   under, for the same reason a computed grouping key does — an alias is
   not reliably visible to the clause that would need it.

   A filter after `limit` is refused, because SQL would apply it before
   the limit rather than after, which is not what the pipeline says.

   The seeded `delay_by_distance` chart uses it to drop distances flown
   fewer than 500 times: 907 of 1,109 points remain and the y-range
   tightens from [-14.4, 37.6] to [-13.0, 21.6], so what it removes is
   genuinely thin buckets rather than signal.

2. ~~**Global aggregates, and `scalar` with them.**~~ Done, and they
   were one job as expected. `reduce` with no `groupBy` before it
   reduces the whole table; every column still has to be aggregated,
   which is the same rule as before stated at its limit — with no
   grouping there is no key to be the exception. `scalar` is a
   terminator that shows a single number with its column name as the
   label, and refuses a row with more than one column.

   The seeded notebook has a `total_flights` scalar that reads the same
   slider `by_state` does, which is the clearest demonstration that an
   input feeds whatever depends on it rather than one designated cell.

3. ~~**Reader options for sources**~~ — done. `nulls`, `delimiter`,
   `header` and `skip`, appended to the reader call:

       csv "…/penguins.csv" nulls "NA"

   That example is the motivating one and it works: without the option
   `bill_length_mm` is inferred as text and the file is useless; with
   it, the column is a double with two real nulls. Options apply to csv
   only, since that is the format that has them, and they are part of a
   source's cache key — an option changes the data as surely as the URI
   does.

4. ~~**`union` and `xunion`**~~ — done, completing the set Acadia's
   `Rows` module has. Both are full outer joins; `xunion` keeps only the
   rows one side had alone.

   A union makes *every* side optional, not only the one being added:
   a row the right side contributed alone has no left side at all, and
   the row type says so. That is the difference between this and SQL,
   where it is a runtime surprise.

   A `filter` before a union is refused. SQL applies WHERE after the
   join, so it would drop every row the right side contributed alone and
   quietly leave an inner join — the same class of trap as filtering
   after a `limit`, and refused for the same reason.

5. ~~**Opaque newtype wrappers**~~ — done. `type OrderId = OrderId Int`,
   the other shape a declared type can take:

       type OrderId = OrderId Int

       access orders ()
         |> map (\o -> { id = o.id as OrderId, owner = o.owner })
         |> selectAll

   It changes nothing about the query — the SQL selects the same column
   — and everything about what the generated Elm will let you do with
   it: `id : OrderId` rather than `id : Int`, so an order id cannot be
   handed to something expecting a customer id. Both shapes are cast
   with `as`, and each requires the column type it reads: text for an
   enum, the wrapped primitive for a wrapper.

6. ~~**`dateRange` inputs**~~ — done, and not as a range. A cell binds
   one value to its name, so a *range* of dates is two `date` cells;
   inventing a two-valued cell to save writing two would have been the
   more complicated answer, not the simpler one.

       date "2001-01-01" "2001-07-01" default "2001-01-01"

   It binds a `Timestamp`, which meant a timestamp literal — inlined as
   `TIMESTAMP '…'`, and not writable from the language itself, only
   bindable by an input. ISO dates sort as text, so the bound checks are
   string comparisons.

   The control is `fabhof/elm-ui-datepicker` rather than the browser's
   own `input type=date`. The native one was the first thing on the page
   that did not belong to the rest of it, and the styling is the smaller
   half of the argument: `input type=date` is three different controls
   across the three webviews a Tauri build would target, and WebKitGTK's
   is the thinnest of them. Picking a library here buys the same control
   everywhere, which is worth two dependencies and a little state.

   The state is per cell — which month is showing, whether it is open,
   what has been typed — and none of it is the value. Half-typed text
   is deliberately not bound: it would invalidate everything downstream
   on each keystroke. The bounds the cell declared are handed to the
   picker's `disabled`, so they are enforced by the control and not only
   by the parser that read them.

   ~~**Options drawn from a query**~~ — done.

       select from by_state .state default "CA"

   The cell it reads is a dependency like any other, so it runs first
   and the input re-resolves when it changes. A cell that filtered on
   the widget while also feeding its options would be a cycle, and the
   graph already reports those.

   Three decisions, all made the same way — refuse rather than do
   something unasked:

   - **A choice that is no longer among the options blocks.** Snapping
     to the default would re-run everything downstream with a value
     nobody picked. The input goes `Invalid`, its dependents block, and
     it says what happened — while still drawing its control, since the
     reader is being asked to choose.
   - **A truncated upstream is refused**, rather than offering the
     subset that happened to be fetched. So is a column with more
     distinct values than anyone would choose between; both say to group
     the source cell down first.
   - **No automatic "any" entry.** There is no way to say "do not
     filter", and adding a value that is not in the column and a filter
     that quietly rewrites itself is worse than the gap.

   The control is a row of buttons while they fit and a dropdown past
   twelve — buttons show every choice at once, which is worth having for
   a handful and unreadable for fifty.

7. **`UNPIVOT`**, which unlike `PIVOT` is statically typeable — the
   columns to fold and the names to fold them into are all written down.
   No demonstration data here has the wide shape it is for, which is why
   it has not been done.

8. **Window functions**, the one item left that needs real design rather
   than a name and a type rule. See the note in the pandas section.

## What a pandas user would miss

Worth separating, because "add pandas" is three different asks:

1. **Tabular transformation** — grouping, joining, reshaping, ranking,
   describing.
2. **The ecosystem** — scikit-learn, scipy, statsmodels, geopandas.
3. **An escape hatch** — arbitrary code over rows, and glue.

### The first is mostly DuckDB's, and we were under-exposing it

Partly closed. The statistical aggregates are in: `median`, `mode`,
`stdDev`, `variance`, `countDistinct`, `quantile` and `correlation`,
with DuckDB's own result types — a median is a double even over
integers, a mode keeps its column's type. Two needed more than a
rename, and both are the interface differing from the engine on purpose:
a distinct count is a modifier rather than a function, and `quantile`
reads better with the fraction first while DuckDB wants it last.

Aggregates take a list of arguments now rather than exactly one, which
is what made the two-argument ones possible and matches how scalar
functions already worked.

**Window functions are what is left, and they are the largest single
item.** They need a stage of their own — a partition, an ordering, and a
result that is still a row rather than a group — which is the one place
in this section where real design is required rather than a name and a
type rule. Worth weighing against the thesis at the top of this
document before starting: `rank` within a partition is what a pandas
user asks for most, but a windowing abstraction is also the most complex
thing this language would contain.

Note on **list aggregates**, which an earlier draft of this section
called cheap: they are not. `list(x)` returns a list, and this type
language has no list — adding one means a new constructor through the
checker, the Elm codegen, the table rendering and the chart channels.
Worth doing only if something actually needs it.

**Pivoting is done, and not as `PIVOT`.** DuckDB's `PIVOT` produces one
column per distinct value found in the data, so its result has no row
type until the query has run — and a row type known before the query
runs is what this entire design rests on. Naming the cases instead gives
the same table statically, through `FILTER`:

    |> reduce (\g ->
         { state = g.state
         , early = countWhere (g.delay <= 0)
         , late = countWhere (g.delay > 30)
         })

`countWhere`, `sumWhere` and `avgWhere`. It generalises past what a
pivot does — any condition, not only equality against a value that
happens to be present — and inside the condition the grouping rule is
lifted, because a condition looks at one row at a time and a bare column
is exactly what is meant there.

`UNPIVOT` and the list aggregates remain unexposed and are cheap.

### The other two need an escape hatch, and it costs the guarantee

This language is deliberately total — no recursion, no user-defined
functions — which is what makes the 1+N problem inexpressible and every
query terminate in time polynomial to the data. That is inherited from
Acadia, and from Datalog before it. Pandas is the exact opposite, and no
amount of care makes those compatible: an escape hatch gives up
totality, and pretending otherwise would be worse than not having one.

The move is to **contain it structurally rather than linguistically**.
What the guarantee protects is not really the language, it is the
*graph* — its predictability, its termination, the absence of a hidden
query per row. A cell of arbitrary code can leave all of that intact if:

- it is **typed going in**, which costs nothing because a query cell's
  row type is already known;
- it is a **leaf** — nothing downstream compiles against its output, so
  an untyped result cannot spread into the type story;
- it runs in a **worker with a timeout**, so a loop that never finishes
  takes one cell down rather than the notebook.

The guarantee then reads: the graph is total, and one cell kind sits
outside it and says so.

### Which language, if one is wanted

- **JavaScript in the browser.** No daemon, npm through a CDN — already
  how Vega is loaded — and a worker is its natural home. The pragmatic
  choice, and closest to what Observable does.
- **Python through Pyodide.** The literal answer: Pyodide ships pandas,
  numpy and much of scikit-learn, and Arrow crosses from duckdb-wasm
  cleanly. It costs perhaps ten megabytes and some speed, lazily loaded
  the way Vega already is, and it needs no server — so it keeps the
  property everything else here has.
- **Elm through a daemon.** Pure and total, so it does not answer the
  ecosystem ask at all, and it needs infrastructure nothing else wants.
  The original plan, and the weakest of the three for this purpose.

**Decided: no escape hatch.** Stay close to what DuckDB provides. The
first section is the work; the rest of this is recorded so the reasoning
is not lost, and so that if the question is reopened it starts from the
containment argument rather than from scratch.

That decision is worth stating positively rather than as a refusal: the
totality guarantee survives intact, which is the thing that makes this
notebook different from a Jupyter one, and every unit of effort goes
into exposing an engine that is already very good at this rather than
into bolting a second one beside it.

## The name

**This is `duckpad`.** A notepad over DuckDB, which is what it is.

It was called Acadia after the language that prompted it, and that was
never sustainable: Acadia is Evan Czaplicki's commercial product, and
wearing its name implied a lineage that is not there and took credit
belonging elsewhere. `note-ml` was a brief intermediate, dropped because
the `-ml` claimed a place in a family this has no real membership of —
no type inference, no user-defined functions, no pattern matching beyond
destructuring.

`duckpad` claims nothing at all. It says where the data lives and what
shape the thing is, and leaves the rest to be discovered by reading it.

**The trade, recorded rather than glossed:** the name is welded to one
engine. If this ever ran on something other than DuckDB the name would
be wrong, where a name claiming nothing — the `Pluto` and `Marimo`
pattern of a short concrete noun — would still fit. That is a real cost
and was accepted knowingly.

**What is honestly borrowed from Acadia**, and should stay credited
wherever the design is explained:

- The pipeline shape, and `access`, `filter`, `map`, `reduce`.
- Naming the joins after set operations — `intersect`, `diff`,
  `exclude`, `union`, `xunion` — and returning pairs rather than merged
  rows. That was read out of Acadia's published `docs.json` after the
  first attempt here got it wrong, and it is a better design than what
  it replaced.
- The Datalog reasoning: no recursion, so 1+N cannot be written and
  every query terminates in time polynomial to the data. That principle
  is the single most valuable thing taken from it.

**What makes the two not comparable.** Acadia is a database programming
language: row-level security as a property every table must declare,
transactions, signed migrations, resources and sequences, modules,
user-defined functions, inserts and deletes, generated clients in more
than one language, its own compiler and server. This is a read-only
query surface for a notebook, with none of that, built in days against
something its author has been thinking about far longer. Acadia should
keep being named as the trigger and the source of the ideas above. What
has stopped is this project answering to it.

**Done in code**: the fence tag is ```` ```duckpad ````, notebooks are
`.duckpad.md`, and the browser-storage key changed with them — so a
notebook saved under an older key is orphaned rather than silently
half-read by a parser that no longer knows its fences. The three
remaining mentions of Acadia in the source are references to *their*
language and are correct.

**Not done**: the repository directory is still `~/Code/ideas/acadia`,
and the distrobox container is still `acadia-tauri`. Both are the
author's to rename, and neither affects anything that ships.

## A tutorial

Nothing here teaches the language. The seeded notebook demonstrates it,
which is not the same thing: it shows a finished pipeline rather than
how to arrive at one, and it says nothing about why `intersect` pairs
rows or when a `reduce` needs a `groupBy`.

A tutorial should be a notebook, because that is the honest medium for
this — prose cells between worked queries, each one runnable and
editable, building from `access` through to a chart. It would ride the
same machinery as the seed: written in Elm, emitted to
`public/notebooks/`, and every cell a roundtrip fixture, so the teaching
material cannot rot without a test failing.

Worth doing after the language settles rather than before, so it is
written once.

## Packaging

Serving on localhost is a poor way to hand this to anyone, and the
question of a desktop shell is worth taking seriously — but for a reason
larger than convenience.

**What a shell would actually buy.** The app needs no backend, which is
unusual: most of what a desktop wrapper exists to provide, we do not
want. Three things are genuinely missing, in increasing order of
importance:

- No terminal and no server to start.
- **Real local files.** A source must be an https URL or a path served
  beside the page; you cannot point at `~/data/sales.parquet` at all.
  Saving is worse than it looks, too — the File System Access API is
  Chromium-only, so outside Chromium `Save` already falls back to a
  download.
- **Native DuckDB instead of duckdb-wasm.** This is the one that changes
  the architecture rather than the packaging. A Rust backend has the
  `duckdb` crate right there, which removes the wasm ceiling entirely:
  larger-than-RAM spilling, extensions, real file paths, and no 13 MB
  download to read a Parquet. It is exactly the "a daemon owns DuckDB
  natively" mode this document flagged in its opening summary as a
  possible later addition, arriving by a different route.

**The recommendation is Tauri v2** (2.11 as of writing). It uses the
operating system's webview rather than bundling a browser, so a build is
single-digit megabytes against Electron's ~150, and its Rust side is
what makes native DuckDB available. Electron remains the right answer
only if rendering has to be identical everywhere, or if nobody wants to
touch Rust. Wails is the same bargain with Go, and Deno has an
experimental `deno desktop` that is too new to build on.

macOS is supported from 10.15 and uses WKWebView, which tracks Safari
and is in better repair than Linux's WebKitGTK — so of the two, Linux is
the target more likely to find a problem and macOS the one more likely
to be shipped. Two macOS costs are worth knowing before committing:
building requires a Mac or a macOS CI runner, there being no
cross-compiling, and distributing to anyone else's machine wants an
Apple Developer account for notarisation. Both are true of Electron too,
but Electron's signing and auto-update tooling is the more mature today,
which is the strongest argument in its favour if shipping to other
people's Macs is a real goal rather than a maybe.

Safari has no File System Access API, so `Save` and `Open` would degrade
there — moot under Tauri, where the native file APIs replace that path
anyway, and the same change is what makes a local file usable as a
source.

**The honest risk** is that same system webview. Everything here has been
developed against Chromium, and Tauri would put it on WebKitGTK on
Linux, WKWebView on macOS and WebView2 on Windows. This application is
demanding — WebAssembly, workers, canvas, custom elements, dynamic
import — and WebKitGTK is the least exercised of the three. Note though
that going native for DuckDB removes the WebAssembly and worker demands
outright, which is most of the risk; what would remain is ordinary.

**The seam already exists**, which is the good news. `Ports.materialize`,
`Ports.loadSource` and `Ports.dbReady` are a small, stable contract
between the notebook and whatever runs the queries. A Tauri build swaps
the JavaScript bridge for one that calls Rust commands and changes
nothing above it. Keeping both a browser build and a desktop build is
therefore possible rather than a fork — one interface, two
implementations.

**A cheaper step worth knowing about.** If the only pain is not wanting
to run a server, a PWA needs a manifest and a service worker and nothing
else: installable, offline, in an engine already known to work. It does
not help with local files.

**Suggested sequence.** Spike a Tauri shell that loads the existing page
unchanged, still on duckdb-wasm. That answers the WebKitGTK question for
a few hours' work and before any commitment to a Rust backend. Only then
decide whether to move DuckDB native. Run the spike on macOS too if a
Mac is available: WebKitGTK is the likelier to break and WKWebView the
likelier to ship.

**Setup on this machine — done.** The host is image-based Fedora
(bootc/rpm-ostree) with a read-only `/usr`, so Tauri's system
dependencies cannot simply be installed. They live in a distrobox
container instead of being layered onto the host image: no reboot, and
the host stays as it was.

    distrobox create --name acadia-tauri \
      --image registry.fedoraproject.org/fedora-toolbox:latest
    distrobox enter acadia-tauri -- sudo dnf install -y \
      webkit2gtk4.1-devel openssl-devel curl wget file \
      libappindicator-gtk3-devel librsvg2-devel \
      gcc gcc-c++ make rust cargo
    distrobox enter acadia-tauri -- cargo install tauri-cli --version "^2" --locked

What that gives: Rust 1.98 (Tauri 2 wants 1.77 or later), webkit2gtk
4.1 at 2.52.5, gtk3 3.24 and libsoup3 3.6.

The container shares `$HOME`, so the repository is the same files inside
and out. That suggests the division of labour for the spike: the
frontend stays on the host, where mise already has elm and node, and
only the Rust side runs in the container. Tauri needs nothing but the
built `public/` directory, which `mise run build` already produces.

Rust and the Tauri CLI install under `~/.cargo`, which is shared — the
only thing this leaves on the host, and removable with the container by
deleting that directory.

## Next up

The language gaps above, or the Tauri spike. They do not depend on each
other.
