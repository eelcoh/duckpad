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
      , source = "Two sources, both read straight from the web. `airports` is a small CSV; `flights` is three million rows of Parquet that DuckDB reads a page at a time, so the whole file never has to come down.\n\n`intersect` pairs two tables rather than merging them, so each side keeps its own column names and a later lambda destructures: `\\(f, orig, dest) -> …`. That is what lets `routes` below join `airports` twice — once for the origin and once for the destination — without the two sides colliding."
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
      , source = "access flights ()\n  |> intersect .origin airports .iata\n  |> groupBy .state\n  |> reduce (\\g ->\n       { state = g.state\n       , departures = count g\n       , avg_delay = avg g.delay\n       })\n  |> sortBy (desc .departures)\n  |> limit 12\n  |> selectAll"
      }
    , { id = "routes"
      , kind = Query
      , source = "access flights ()\n  |> intersect .origin airports .iata\n  |> intersect .destination airports .iata\n  |> map (\\(f, orig, dest) ->\n       { from = orig.city\n       , to = dest.city\n       , miles = f.distance\n       , delay = f.delay\n       })\n  |> limit 200\n  |> selectAll"
      }
    , { id = "quiet"
      , kind = Query
      , source = "type Country\n  = Usa \"USA\"\n  | Marianas \"N Mariana Islands\"\n  | Palau \"Palau\"\n  | Thailand \"Thailand\"\n  | Micronesia \"Federated States of Micronesia\"\n\naccess airports ()\n  |> exclude .iata flights .origin\n  |> map (\\a ->\n       { code = a.iata\n       , city = a.city\n       , country = a.country as Country\n       })\n  |> sortBy .code\n  |> selectAll"
      }
    ]
