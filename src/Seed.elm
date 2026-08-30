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
      , source = "Two sources, both read straight from the web. `airports` is a small CSV; `flights` is three million rows of Parquet that DuckDB reads a page at a time, so the whole file never has to come down.\n\nA terminator says how a cell is shown: `selectAll` gives a table, and `barChart`, `lineChart` or `scatter` a chart. The channels are checked against the row, so plotting something that is not a number is a compile error rather than an empty picture.\n\n`intersect` pairs two tables rather than merging them, so each side keeps its own column names and a later lambda destructures: `\\(f, orig, dest) -> …`. Scalar functions work anywhere an expression does — `roundTo 1 (avg g.delay)` below, and `++` to build a label. That is what lets `routes` below join `airports` twice — once for the origin and once for the destination — without the two sides colliding."
      }
    , { id = "airports"
      , kind = Source
      , source = "csv \"https://cdn.jsdelivr.net/npm/vega-datasets@2/data/airports.csv\""
      }
    , { id = "flights"
      , kind = Source
      , source = "parquet \"https://cdn.jsdelivr.net/npm/vega-datasets@3.2.0/data/flights-3m.parquet\""
      }
    , { id = "by_state"
      , kind = Query
      , source = "access flights ()\n  |> intersect .origin airports .iata\n  |> groupBy .state\n  |> reduce (\\g ->\n       { state = g.state\n       , departures = count g\n       , avg_delay = roundTo 1 (avg g.delay)\n       })\n  |> sortBy (desc .departures)\n  |> limit 12\n  |> barChart { x = .state, y = .departures }"
      }
    , { id = "delay_by_distance"
      , kind = Query
      , source = "access flights ()\n  |> groupBy .distance\n  |> reduce (\\g ->\n       { distance = g.distance\n       , avg_delay = roundTo 1 (avg g.delay)\n       })\n  |> lineChart { x = .distance, y = .avg_delay }"
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
