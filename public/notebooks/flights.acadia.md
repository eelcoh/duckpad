---
title: Flights
---

Two sources, both read straight from the web. `airports` is a small CSV; `flights` is three million rows of Parquet that DuckDB reads a page at a time, so the whole file never has to come down.

A terminator says how a cell is shown: `selectAll` gives a table, and `barChart`, `lineChart` or `scatter` a chart. The channels are checked against the row, so plotting something that is not a number is a compile error rather than an empty picture.

`intersect` pairs two tables rather than merging them, so each side keeps its own column names and a later lambda destructures: `\(f, orig, dest) -> …`. Scalar functions work anywhere an expression does — `roundTo 1 (avg g.delay)` below, and `++` to build a label. `groupBy` takes a lambda when a key has to be computed, which is how `daily` turns a minute-resolution timestamp into a day.

`countWhere` and its relatives count only the rows matching a condition, which is what a pivot is for — with the cases named rather than discovered in the data, so the row still has a type. A `filter` after a `reduce` becomes a HAVING, which is how `delay_by_distance` drops the distances too rare to average meaningfully.

An input cell binds a control to its name. Drag `min_distance` and only the cells that read it re-run — `total_flights` and `by_state` both do, and `since` trims the time series. `focus_state` takes its options from a column of `by_state`, so the states you can choose are the ones that chart is showing — the value is compiled into their SQL, so the cache does the rest. That is what lets `routes` below join `airports` twice — once for the origin and once for the destination — without the two sides colliding.

```source airports
csv "https://cdn.jsdelivr.net/npm/vega-datasets@2/data/airports.csv"
```

```source flights
parquet "https://cdn.jsdelivr.net/npm/vega-datasets@3.2.0/data/flights-3m.parquet"
```

```input min_distance
range 0 2500 step 250 default 0
```

```acadia total_flights
access flights ()
  |> filter (\f -> f.distance >= min_distance)
  |> reduce (\g -> { flights = count g })
  |> scalar
```

```acadia by_state
access flights ()
  |> filter (\f -> f.distance >= min_distance)
  |> intersect .origin airports .iata
  |> groupBy .state
  |> reduce (\g ->
       { state = g.state
       , departures = count g
       , avg_delay = roundTo 1 (avg g.delay)
       })
  |> sortBy (desc .departures)
  |> limit 12
  |> barChart { x = .state, y = .departures }
```

```acadia punctuality
access flights ()
  |> intersect .origin airports .iata
  |> groupBy .state
  |> reduce (\g ->
       { state = g.state
       , early = countWhere (g.delay <= 0)
       , late = countWhere (g.delay > 30)
       , worst = max g.delay
       })
  |> filter (\r -> r.late > 2000)
  |> sortBy (desc .late)
  |> selectAll
```

```input focus_state
select from by_state .state default "CA"
```

```acadia state_airports
access airports ()
  |> filter (\a -> a.state == focus_state)
  |> map (\a ->
       { code = a.iata
       , city = a.city
       })
  |> sortBy .code
  |> selectAll
```

```input since
date "2001-01-01" "2001-07-01" default "2001-01-01"
```

```acadia daily
access flights ()
  |> filter (\f -> f.date >= since)
  |> groupBy (\f -> { day = startOfDay f.date })
  |> reduce (\g ->
       { day = g.day
       , flights = count g
       })
  |> sortBy .day
  |> lineChart { x = .day, y = .flights }
```

```acadia delay_by_distance
access flights ()
  |> groupBy .distance
  |> reduce (\g ->
       { distance = g.distance
       , avg_delay = roundTo 1 (avg g.delay)
       , flights = count g
       })
  |> filter (\r -> r.flights > 500)
  |> lineChart { x = .distance, y = .avg_delay }
```

```acadia airport_map
access airports ()
  |> filter (\a -> a.longitude > -130.0 && a.latitude > 22.0)
  |> map (\a ->
       { lon = a.longitude
       , lat = a.latitude
       })
  |> scatter { x = .lon, y = .lat }
```

```acadia routes
access flights ()
  |> intersect .origin airports .iata
  |> intersect .destination airports .iata
  |> map (\(f, orig, dest) ->
       { route = orig.city ++ " → " ++ dest.city
       , miles = f.distance
       , delay = f.delay
       })
  |> limit 200
  |> selectAll
```

```acadia quiet
type Country
  = Usa "USA"
  | Marianas "N Mariana Islands"
  | Palau "Palau"
  | Thailand "Thailand"
  | Micronesia "Federated States of Micronesia"

access airports ()
  |> exclude .iata flights .origin
  |> map (\a ->
       { code = a.iata
       , city = a.city
       , country = a.country as Country
       })
  |> sortBy .code
  |> selectAll
```
