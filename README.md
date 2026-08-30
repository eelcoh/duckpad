# duckpad

A reactive, typed notebook over [DuckDB](https://duckdb.org). Query cells are
written in a small functional language that compiles, in the browser, to SQL
*and* to an Elm module — both from one checked description, so they cannot
disagree about what a column is called or what type it holds.

```duckpad by_region
access orders ()
  |> groupBy .region
  |> reduce (\g ->
       { region = g.region
       , orders = count g
       , revenue = roundTo 2 (sum g.total)
       })
  |> sortBy (desc .revenue)
  |> barChart { x = .region, y = .revenue }
```

## What makes it different from a Jupyter notebook

- **Reactive, not sequential.** Cells depend on what they mention. Editing one
  marks everything downstream stale and re-runs it in dependency order, so a
  cell can never display a result that its code no longer produces.
- **Typed all the way through.** The compiler knows every column's type, so
  plotting text on a numeric axis, grouping by a column you forgot to
  aggregate, or joining on keys that cannot match are all errors in the cell
  you are editing rather than surprises at runtime.
- **Total.** There is no recursion and there are no user-defined functions,
  which is not an omission: it means the 1+N query problem cannot be expressed
  and every query terminates in time polynomial to the data. That idea is
  borrowed, via Acadia, from Datalog.
- **No server.** DuckDB runs in WebAssembly, the compiler is compiled Elm, and
  a notebook is a Markdown file that diffs cleanly.

## Running it

Tools are pinned with [mise](https://mise.jdx.dev); nothing is installed
globally.

    mise run build     # compile the notebook shell
    mise run serve     # http://localhost:8080
    mise run test      # 359 checks
    mise run roundtrip # every fixture's SQL run against a real DuckDB

`public/notebooks/tutorial.duckpad.md` is ten worked queries with prose between
them, and needs no network. Open it with the **Open** button.

There is also a desktop build, using [Tauri](https://tauri.app) — see the
packaging section of [ROADMAP.md](ROADMAP.md) for what it needs.

## Credit where it is due

duckpad exists because of [Acadia](https://acadia.engineering/), Evan
Czaplicki's database programming language, which is where the pipeline shape,
the set-operation names for joins, and the no-recursion guarantee all come
from.

The two are not comparable and duckpad does not try to be an equivalent.
Acadia is a database programming language with row-level security, transactions,
signed migrations, modules, user-defined functions, writes and generated
clients. This is a read-only query surface for a notebook. Go and look at the
real thing.

## Where the thinking is written down

[ROADMAP.md](ROADMAP.md) is the design document: what was built, in what order,
what was decided and why, and what is deliberately missing. Most non-obvious
choices have a paragraph there explaining the alternative that was rejected.
