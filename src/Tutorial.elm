module Tutorial exposing (notebook)

{-| A notebook that teaches the language, written as a notebook.

Prose between worked queries, each one live and editable, building from
`access` to a chart and a control. It rides the same machinery as the seeded
notebook — emitted to `public/notebooks/` and checked cell by cell — so the
teaching material cannot go stale without a test failing.

It uses the two CSV files that ship with duckpad rather than anything remote:
a tutorial should not need the network, or a thirteen-megabyte download, before
its first query runs.

-}

import Cell exposing (Cell, Kind(..))
import Notebook exposing (Notebook)


notebook : Notebook
notebook =
    { title = "Learn duckpad", cells = cells }


cells : List Cell
cells =
    [ { id = "intro"
      , kind = Prose
      , source = "# duckpad in ten cells\n\nEvery cell below is live: edit one and everything that reads it re-runs, in dependency order. Nothing here needs the network — the data is two small CSV files that ship with duckpad.\n\nWork down the page. Each query cell introduces one idea and the prose above it says what to look for."
      }
    , { id = "p_source"
      , kind = Prose
      , source = "## Where data comes from\n\nA **source** cell names a file and binds it to the cell's name. Nothing else in the notebook knows or cares where `orders` came from."
      }
    , { id = "orders"
      , kind = Source
      , source = "csv \"data/orders.csv\""
      }
    , { id = "p_access"
      , kind = Prose
      , source = "## The shape of a query\n\nEvery query starts with `access`, pipes through stages with `|>`, and ends with a terminator that says what to do with the result. `selectAll` means \"give me the rows\".\n\nLook at the column headers: duckpad knows each column's type, and everything downstream is checked against them."
      }
    , { id = "everything"
      , kind = Query
      , source = "access orders ()\n  |> selectAll"
      }
    , { id = "p_filter"
      , kind = Prose
      , source = "## Keeping some rows\n\n`filter` takes a lambda. `\\o -> …` binds one row as `o`, and `o.total` reads a column from it. Try changing `500.0` to `900.0`."
      }
    , { id = "large"
      , kind = Query
      , source = "access orders ()\n  |> filter (\\o -> o.total > 500.0)\n  |> selectAll"
      }
    , { id = "p_map"
      , kind = Prose
      , source = "## Choosing and renaming columns\n\n`map` builds a new row. The names on the left become the columns; the expressions on the right can compute.\n\nRename `amount` to something else and watch the table header follow."
      }
    , { id = "summary"
      , kind = Query
      , source = "access orders ()\n  |> map (\\o ->\n       { who = o.owner\n       , where_from = o.region\n       , amount = o.total\n       })\n  |> selectAll"
      }
    , { id = "p_group"
      , kind = Prose
      , source = "## Summarising\n\n`groupBy` picks the key, `reduce` says what each group becomes. Inside `reduce`, a bare column is only allowed if it *is* the key — anything else has to be aggregated, because a group has many values for it. Try changing `g.region` to `g.owner` to see the error that rule gives you."
      }
    , { id = "by_region"
      , kind = Query
      , source = "access orders ()\n  |> groupBy .region\n  |> reduce (\\g ->\n       { region = g.region\n       , orders = count g\n       , revenue = roundTo 2 (sum g.total)\n       })\n  |> sortBy (desc .revenue)\n  |> selectAll"
      }
    , { id = "p_having"
      , kind = Prose
      , source = "## Filtering what you summarised\n\nA `filter` *after* a `reduce` reads the reduced rows, not the original ones. It becomes a `HAVING` in the generated SQL — open the **generated** panel below any cell to see what duckpad wrote."
      }
    , { id = "busy"
      , kind = Query
      , source = "access orders ()\n  |> groupBy .region\n  |> reduce (\\g ->\n       { region = g.region\n       , orders = count g\n       })\n  |> filter (\\r -> r.orders > 60)\n  |> selectAll"
      }
    , { id = "p_join"
      , kind = Prose
      , source = "## Combining two tables\n\n`intersect` matches rows by a key from each side. It **pairs** the rows rather than merging them, so each side keeps its own column names and the lambda takes both: `\\(o, c) -> …`. Two tables that both have an `id` need no renaming.\n\n`diff` keeps unmatched rows on the left, and `exclude` keeps only the unmatched ones."
      }
    , { id = "customers"
      , kind = Source
      , source = "csv \"data/customers.csv\""
      }
    , { id = "by_tier"
      , kind = Query
      , source = "access orders ()\n  |> intersect .owner customers .owner\n  |> groupBy .tier\n  |> reduce (\\g ->\n       { tier = g.tier\n       , orders = count g\n       , revenue = roundTo 2 (sum g.total)\n       })\n  |> sortBy (desc .revenue)\n  |> selectAll"
      }
    , { id = "p_types"
      , kind = Prose
      , source = "## Giving a column a type\n\nA text column holding a fixed set of values can be declared as a type. The table then shows constructors instead of raw strings, and the Elm module duckpad generates has a real `Status` type in it.\n\nDelete one of the constructors and the cell stops compiling — the tags have to cover what is in the data."
      }
    , { id = "typed"
      , kind = Query
      , source = "type Status\n  = Submitted \"submitted\"\n  | InTransit \"in_transit\"\n  | Delivered \"delivered\" from .delivered_at\n\naccess orders ()\n  |> map (\\o ->\n       { owner = o.owner\n       , status = o.status as Status\n       })\n  |> limit 20\n  |> selectAll"
      }
    , { id = "p_chart"
      , kind = Prose
      , source = "## Drawing it\n\nA chart is a terminator like `selectAll` — the cell's value is still its rows. The channels are checked against the row type, so asking to plot text on `y` is a compile error rather than an empty picture. Try swapping `.revenue` for `.region` to see it."
      }
    , { id = "chart"
      , kind = Query
      , source = "access by_region ()\n  |> barChart { x = .region, y = .revenue }"
      }
    , { id = "p_input"
      , kind = Prose
      , source = "## Controls\n\nAn **input** cell binds a control to its name. Any query that mentions the name depends on it, so moving the slider re-runs exactly those cells and nothing else.\n\nThat is the whole of duckpad's model: cells depend on what they mention, and changing something re-runs what depends on it."
      }
    , { id = "floor_price"
      , kind = Input
      , source = "range 0 800 step 50 default 300"
      }
    , { id = "above_floor"
      , kind = Query
      , source = "access orders ()\n  |> filter (\\o -> o.total >= floor_price)\n  |> reduce (\\g -> { orders = count g })\n  |> scalar"
      }
    ]
