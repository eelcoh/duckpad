module Dsl.Keywords exposing (aggregates, formats, reserved)

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
    Set.fromList [ "count", "sum", "avg", "min", "max" ]


{-| The formats a source cell may name.
-}
formats : Set String
formats =
    Set.fromList [ "csv", "parquet", "json" ]
