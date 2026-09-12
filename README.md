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
- **No server.** DuckDB runs in WebAssembly in the browser and natively in the
  desktop build, the compiler is compiled Elm, and a notebook is a Markdown
  file that diffs cleanly. Nothing round-trips through a backend either way.

## Running it

Tools are pinned with [mise](https://mise.jdx.dev); nothing is installed
globally. The first build also vendors DuckDB and its Excel extension, so
everything afterwards works offline.

    mise run build     # compile the notebook shell
    mise run serve     # http://localhost:8080

`public/tutorial.duckpad.md` is ten worked queries with prose between
them, and needs no network. Open it with the **Open** button.

### In the browser

`mise run serve` is the whole of it. DuckDB runs in WebAssembly, so the page
is the database — but a browser cannot silently overwrite a file it did not
open, so Save downloads a new copy unless the browser has the File System
Access API. `localStorage` holds a recovery copy either way.

### On the desktop

The desktop build wraps the same page in [Tauri](https://tauri.app) and swaps
WebAssembly for a native DuckDB, which is what lets it read a file path rather
than a URL. Which task to use depends on how the Rust side gets built:

    mise run desktop         # Linux, via the duckpad-tauri container
    mise run desktop-native  # macOS and Windows, against the host toolchain

    mise run release         # Linux bundles: deb, rpm, AppImage
    mise run release-native  # macOS and Windows bundles

The split exists because this project is developed on a Fedora host with no
webkit2gtk development headers, so the Linux tasks enter a distrobox container
that has them. macOS and Windows need no container — their webview ships with
the OS — so the `-native` tasks call `cargo tauri` directly. They need a Rust
toolchain and `cargo install tauri-cli --version "^2.0"`, which mise does not
pin.

Prebuilt bundles for all four targets are attached to every CI run on `master`
under **Artifacts**, and expire after two weeks. They are unsigned: macOS
reports an un-notarized app as *damaged* rather than as unsigned, and
`xattr -dr com.apple.quarantine` is the local workaround where policy allows
it. Building on the machine itself avoids the question — nothing compiled
locally is ever quarantined.

### Making the text bigger

Ctrl or Cmd with `+`, `-` and `0` scales the interface, and the level is
remembered between launches.

## Changing it

Two commands, and neither is needed to *use* duckpad — they are here for
working on the compiler.

    mise run test      # 497 checks: parser, checker, engine, file format
    mise run roundtrip # proves the generated SQL and Elm are real

`test` is the ordinary suite. It has no npm toolchain behind it — the modules
under test have no effects, so a `Platform.worker` reporting a list of checks
is enough — and it runs under node in seconds.

`roundtrip` closes a gap the suite cannot reach. A query cell compiles to SQL
*and* to an Elm module, and a test comparing strings can tell you the compiler
emitted the text you expected but never that the text is valid — a suite can
be entirely green over a compiler emitting `SELCET`. So `roundtrip` takes 43
fixture cells, one per language feature, executes each one's SQL against a
real DuckDB and puts each one's generated module through `elm make`. Run it
after touching `Dsl/Sql.elm` or `Dsl/ElmGen.elm`: that is exactly where a
change can keep every string assertion passing while producing something
neither DuckDB nor Elm will accept.

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
