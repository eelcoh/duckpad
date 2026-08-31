module Dsl.Keywords exposing (aggregates, formats, functions, reserved, windows)

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
        , "unpivot"
        , "summarize"
        , "partitionBy"
        , "extend"
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


{-| The functions that only mean anything over a window.

Kept apart from the aggregates because the two are legal in different places:
an aggregate works in a `reduce` and, over a partition, in an `extend`; these
work only in an `extend`. Both are highlighted, and both are recognised by
position, so a column may still be called `rank`.

-}
windows : Set String
windows =
    Set.fromList
        [ "rowNumber"
        , "rank"
        , "denseRank"
        , "lag"
        , "lead"
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
        , "covarPop"
        , "covarSamp"
        , "skewness"
        , "kurtosis"
        , "mad"
        , "entropy"
        , "regrSlope"
        , "regrIntercept"
        , "regrR2"
        , "regrCount"
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
