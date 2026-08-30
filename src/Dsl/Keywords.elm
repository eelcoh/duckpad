module Dsl.Keywords exposing (aggregates, formats, functions, reserved)

{-| The words the language reserves.

One list, used by the parser to reject them as names and by the lexer to
colour them. Keeping them apart would mean a keyword added to the grammar
silently stopped being highlighted, which is the sort of drift the rest of
this project goes out of its way to avoid.

-}

import Set exposing (Set)


reserved : Set String
reserved =
    Set.fromList
        [ "access"
        , "filter"
        , "map"
        , "groupBy"
        , "reduce"
        , "sortBy"
        , "limit"
        , "intersect"
        , "diff"
        , "exclude"
        , "select"
        , "selectAll"
        , "type"
        , "from"
        , "as"
        , "asc"
        , "desc"
        , "not"
        , "true"
        , "false"
        ]


{-| Not reserved — an aggregate is recognised by position, so a column may
still be called `count`. They are highlighted because reading them as calls
is what makes a `reduce` legible.
-}
aggregates : Set String
aggregates =
    Set.fromList
        [ "count"
        , "countDistinct"
        , "sum"
        , "avg"
        , "min"
        , "max"
        , "median"
        , "mode"
        , "stdDev"
        , "variance"
        , "quantile"
        , "correlation"
        , "countWhere"
        , "sumWhere"
        , "avgWhere"
        ]


{-| Scalar functions, recognised by position like the aggregates, so a column
called `round` or `month` still works.

There are no user-defined functions, so a fixed set is enough — and it is what
lets `round o.total` parse as a call rather than as two names in a row.
-}
functions : Set String
functions =
    Set.fromList
        [ "startOfDay"
        , "startOfMonth"
        , "startOfYear"
        , "year"
        , "month"
        , "dayOfWeek"
        , "round"
        , "roundTo"
        , "abs"
        , "floor"
        , "ceiling"
        , "lower"
        , "upper"
        ]


{-| The formats a source cell may name.
-}
formats : Set String
formats =
    Set.fromList [ "csv", "parquet", "json" ]
