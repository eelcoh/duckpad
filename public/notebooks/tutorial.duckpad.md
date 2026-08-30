---
title: Learn duckpad
---

# duckpad in ten cells

Every cell below is live: edit one and everything that reads it re-runs, in dependency order. Nothing here needs the network — the data is two small CSV files that ship with duckpad.

Work down the page. Each query cell introduces one idea and the prose above it says what to look for.

## Where data comes from

A **source** cell names a file and binds it to the cell's name. Nothing else in the notebook knows or cares where `orders` came from.

```source orders
csv "data/orders.csv"
```

## The shape of a query

Every query starts with `access`, pipes through stages with `|>`, and ends with a terminator that says what to do with the result. `selectAll` means "give me the rows".

Look at the column headers: duckpad knows each column's type, and everything downstream is checked against them.

```duckpad everything
access orders ()
  |> selectAll
```

## Keeping some rows

`filter` takes a lambda. `\o -> …` binds one row as `o`, and `o.total` reads a column from it. Try changing `500.0` to `900.0`.

```duckpad large
access orders ()
  |> filter (\o -> o.total > 500.0)
  |> selectAll
```

## Choosing and renaming columns

`map` builds a new row. The names on the left become the columns; the expressions on the right can compute.

Rename `amount` to something else and watch the table header follow.

```duckpad summary
access orders ()
  |> map (\o ->
       { who = o.owner
       , where_from = o.region
       , amount = o.total
       })
  |> selectAll
```

## Summarising

`groupBy` picks the key, `reduce` says what each group becomes. Inside `reduce`, a bare column is only allowed if it *is* the key — anything else has to be aggregated, because a group has many values for it. Try changing `g.region` to `g.owner` to see the error that rule gives you.

```duckpad by_region
access orders ()
  |> groupBy .region
  |> reduce (\g ->
       { region = g.region
       , orders = count g
       , revenue = roundTo 2 (sum g.total)
       })
  |> sortBy (desc .revenue)
  |> selectAll
```

## Filtering what you summarised

A `filter` *after* a `reduce` reads the reduced rows, not the original ones. It becomes a `HAVING` in the generated SQL — open the **generated** panel below any cell to see what duckpad wrote.

```duckpad busy
access orders ()
  |> groupBy .region
  |> reduce (\g ->
       { region = g.region
       , orders = count g
       })
  |> filter (\r -> r.orders > 60)
  |> selectAll
```

## Combining two tables

`intersect` matches rows by a key from each side. It **pairs** the rows rather than merging them, so each side keeps its own column names and the lambda takes both: `\(o, c) -> …`. Two tables that both have an `id` need no renaming.

`diff` keeps unmatched rows on the left, and `exclude` keeps only the unmatched ones.

```source customers
csv "data/customers.csv"
```

```duckpad by_tier
access orders ()
  |> intersect .owner customers .owner
  |> groupBy .tier
  |> reduce (\g ->
       { tier = g.tier
       , orders = count g
       , revenue = roundTo 2 (sum g.total)
       })
  |> sortBy (desc .revenue)
  |> selectAll
```

## Giving a column a type

A text column holding a fixed set of values can be declared as a type. The table then shows constructors instead of raw strings, and the Elm module duckpad generates has a real `Status` type in it.

Delete one of the constructors and the cell stops compiling — the tags have to cover what is in the data.

```duckpad typed
type Status
  = Submitted "submitted"
  | InTransit "in_transit"
  | Delivered "delivered" from .delivered_at

access orders ()
  |> map (\o ->
       { owner = o.owner
       , status = o.status as Status
       })
  |> limit 20
  |> selectAll
```

## Drawing it

A chart is a terminator like `selectAll` — the cell's value is still its rows. The channels are checked against the row type, so asking to plot text on `y` is a compile error rather than an empty picture. Try swapping `.revenue` for `.region` to see it.

```duckpad chart
access by_region ()
  |> barChart { x = .region, y = .revenue }
```

## Controls

An **input** cell binds a control to its name. Any query that mentions the name depends on it, so moving the slider re-runs exactly those cells and nothing else.

That is the whole of duckpad's model: cells depend on what they mention, and changing something re-runs what depends on it.

```input floor_price
range 0 800 step 50 default 300
```

```duckpad above_floor
access orders ()
  |> filter (\o -> o.total >= floor_price)
  |> reduce (\g -> { orders = count g })
  |> scalar
```
