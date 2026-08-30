module Seed exposing (notebook)

{-| The notebook the app opens on, and the one `Reset` returns to.

It lives here rather than in `Main` because it is also written out as a file:
`mise run seed` serialises this and `public/notebooks/flights.acadia.md` is the
result, so the shipped example and the built-in starting point cannot drift
apart.

-}

import Cell exposing (Cell, Kind(..))
import Notebook exposing (Notebook)


notebook : Notebook
notebook =
    { title = "Flights", cells = seedCells }


seedCells : List Cell
seedCells =
    [ { id = "intro"
      , kind = Prose
      , source = "Two sources, both read straight from the web. `airports` is a small CSV; `flights` is three million rows of Parquet that DuckDB reads a page at a time, so the whole file never has to come down.\n\nA terminator says how a cell is shown: `selectAll` gives a table, and `barChart`, `lineChart` or `scatter` a chart. The channels are checked against the row, so plotting something that is not a number is a compile error rather than an empty picture.\n\n`intersect` pairs two tables rather than merging them, so each side keeps its own column names and a later lambda destructures: `\\(f, orig, dest) -> …`. Scalar functions work anywhere an expression does — `roundTo 1 (avg g.delay)` below, and `++` to build a label. `groupBy` takes a lambda when a key has to be computed, which is how `daily` turns a minute-resolution timestamp into a day.\n\n`countWhere` and its relatives count only the rows matching a condition, which is what a pivot is for — with the cases named rather than discovered in the data, so the row still has a type. A `filter` after a `reduce` becomes a HAVING, which is how `delay_by_distance` drops the distances too rare to average meaningfully.\n\nAn input cell binds a control to its name. Drag `min_distance` and only the cells that read it re-run — `total_flights` and `by_state` both do, and `since` trims the time series. `focus_state` takes its options from a column of `by_state`, so the states you can choose are the ones that chart is showing — the value is compiled into their SQL, so the cache does the rest. That is what lets `routes` below join `airports` twice — once for the origin and once for the destination — without the two sides colliding."
      }
    , { id = "airports"
      , kind = Source
      , source = "csv \"https://cdn.jsdelivr.net/npm/vega-datasets@2/data/airports.csv\""
      }
    , { id = "flights"
      , kind = Source
      , source = "parquet \"https://cdn.jsdelivr.net/npm/vega-datasets@3.2.0/data/flights-3m.parquet\""
      }
    , { id = "min_distance"
      , kind = Input
      , source = "range 0 2500 step 250 default 0"
      }
    , { id = "total_flights"
      , kind = Query
      , source = "access flights ()\n  |> filter (\\f -> f.distance >= min_distance)\n  |> reduce (\\g -> { flights = count g })\n  |> scalar"
      }
    , { id = "by_state"
      , kind = Query
      , source = "access flights ()\n  |> filter (\\f -> f.distance >= min_distance)\n  |> intersect .origin airports .iata\n  |> groupBy .state\n  |> reduce (\\g ->\n       { state = g.state\n       , departures = count g\n       , avg_delay = roundTo 1 (avg g.delay)\n       })\n  |> sortBy (desc .departures)\n  |> limit 12\n  |> barChart { x = .state, y = .departures }"
      }
    , { id = "punctuality"
      , kind = Query
      , source = "access flights ()\n  |> intersect .origin airports .iata\n  |> groupBy .state\n  |> reduce (\\g ->\n       { state = g.state\n       , early = countWhere (g.delay <= 0)\n       , late = countWhere (g.delay > 30)\n       , worst = max g.delay\n       })\n  |> filter (\\r -> r.late > 2000)\n  |> sortBy (desc .late)\n  |> selectAll"
      }
    , { id = "focus_state"
      , kind = Input
      , source = "select from by_state .state default \"CA\""
      }
    , { id = "state_airports"
      , kind = Query
      , source = "access airports ()\n  |> filter (\\a -> a.state == focus_state)\n  |> map (\\a ->\n       { code = a.iata\n       , city = a.city\n       })\n  |> sortBy .code\n  |> selectAll"
      }
    , { id = "since"
      , kind = Input
      , source = "date \"2001-01-01\" \"2001-07-01\" default \"2001-01-01\""
      }
    , { id = "daily"
      , kind = Query
      , source = "access flights ()\n  |> filter (\\f -> f.date >= since)\n  |> groupBy (\\f -> { day = startOfDay f.date })\n  |> reduce (\\g ->\n       { day = g.day\n       , flights = count g\n       })\n  |> sortBy .day\n  |> lineChart { x = .day, y = .flights }"
      }
    , { id = "delay_by_distance"
      , kind = Query
      , source = "access flights ()\n  |> groupBy .distance\n  |> reduce (\\g ->\n       { distance = g.distance\n       , avg_delay = roundTo 1 (avg g.delay)\n       , flights = count g\n       })\n  |> filter (\\r -> r.flights > 500)\n  |> lineChart { x = .distance, y = .avg_delay }"
      }
    , { id = "airport_map"
      , kind = Query
      , source = "access airports ()\n  |> filter (\\a -> a.longitude > -130.0 && a.latitude > 22.0)\n  |> map (\\a ->\n       { lon = a.longitude\n       , lat = a.latitude\n       })\n  |> scatter { x = .lon, y = .lat }"
      }
    , { id = "routes"
      , kind = Query
      , source = "access flights ()\n  |> intersect .origin airports .iata\n  |> intersect .destination airports .iata\n  |> map (\\(f, orig, dest) ->\n       { route = orig.city ++ \" → \" ++ dest.city\n       , miles = f.distance\n       , delay = f.delay\n       })\n  |> limit 200\n  |> selectAll"
      }
    , { id = "quiet"
      , kind = Query
      , source = "type Country\n  = Usa \"USA\"\n  | Marianas \"N Mariana Islands\"\n  | Palau \"Palau\"\n  | Thailand \"Thailand\"\n  | Micronesia \"Federated States of Micronesia\"\n\naccess airports ()\n  |> exclude .iata flights .origin\n  |> map (\\a ->\n       { code = a.iata\n       , city = a.city\n       , country = a.country as Country\n       })\n  |> sortBy .code\n  |> selectAll"
      }
    ]
