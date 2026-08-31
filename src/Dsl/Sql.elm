module Dsl.Sql exposing (render)

{-| Typed IR to DuckDB SQL.

One of two renderings of `Dsl.Check.Checked`. It never re-derives a name or a
type: anything this module needs to know was settled by the checker, which is
what keeps it in step with the generated Elm.

-}

import Dsl.Ast as Ast exposing (CombineKind(..), Literal(..), Op(..), SortDir(..))
import Dsl.Check exposing (Checked, CheckedCombine, CheckedUnpivot, CheckedWindow, Projection(..), TExpr(..))
import Dsl.Schema exposing (Type(..))


render : Checked -> String
render checked =
    ([ "SELECT " ++ projection checked
     , "FROM " ++ from checked ++ " AS " ++ ident checked.sourceAlias
     ]
        ++ List.filterMap joinClause checked.combines
        ++ maybeLine "WHERE " (whereClause checked)
        ++ maybeLine "GROUP BY " (groupKeys checked.groupBy)
        ++ maybeLine "HAVING " (Maybe.map expr checked.having)
        ++ maybeLine "QUALIFY " (Maybe.map expr checked.qualify)
        ++ maybeLine "ORDER BY " (Maybe.map sort checked.sort)
        ++ maybeLine "LIMIT " (Maybe.map String.fromInt checked.limit)
    )
        |> String.join "\n"



{-| The table the pipeline reads, which an `unpivot` replaces.

DuckDB's UNPIVOT is a table-producing construct rather than a clause, so it
belongs here. That it can only appear in the FROM is the same fact the checker
states as "unpivot has to be the first stage".

-}
from : Checked -> String
from checked =
    case checked.unpivot of
        Nothing ->
            ident checked.source

        Just spec ->
            "(UNPIVOT "
                ++ ident checked.source
                ++ " ON "
                ++ (spec.columns |> List.map ident |> String.join ", ")
                ++ " INTO NAME "
                ++ ident spec.name
                ++ " VALUE "
                ++ ident spec.value
                ++ ")"


groupKeys : List TExpr -> Maybe String
groupKeys keys =
    case keys of
        [] ->
            Nothing

        _ ->
            -- The expressions themselves, not the aliases they are selected
            -- under: a computed key has no column to point at, and repeating
            -- the expression is valid wherever an alias would have been.
            Just (keys |> List.map expr |> String.join ", ")


{-| `intersect` and `diff` become joins; `exclude` is an anti-join and is
expressed in the WHERE clause instead, because it contributes no columns.
-}
joinClause : CheckedCombine -> Maybe String
joinClause combine =
    case combine.kind of
        Exclude ->
            Nothing

        Intersect ->
            Just (joinLine "JOIN " combine)

        Diff ->
            Just (joinLine "LEFT JOIN " combine)

        Union ->
            Just (joinLine "FULL OUTER JOIN " combine)

        XUnion ->
            Just (joinLine "FULL OUTER JOIN " combine)


joinLine : String -> CheckedCombine -> String
joinLine keyword combine =
    keyword
        ++ ident combine.table
        ++ " AS "
        ++ ident combine.alias
        ++ " ON "
        ++ qualified combine.leftAlias combine.leftKey
        ++ " = "
        ++ qualified combine.alias combine.rightKey


whereClause : Checked -> Maybe String
whereClause checked =
    let
        conditions =
            (checked.filter |> Maybe.map expr |> maybeToList)
                ++ List.filterMap antiJoin checked.combines
    in
    case conditions of
        [] ->
            Nothing

        _ ->
            Just (String.join " AND " conditions)


maybeToList : Maybe a -> List a
maybeToList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []


{-| The conditions a combine contributes to the WHERE clause.

`exclude` is an anti-join and lives here entirely; `xunion` is a full outer
join kept to the rows only one side had, which is a condition on the join
rather than a join of its own.
-}
antiJoin : CheckedCombine -> Maybe String
antiJoin combine =
    case combine.kind of
        XUnion ->
            Just
                ("("
                    ++ qualified combine.leftAlias combine.leftKey
                    ++ " IS NULL OR "
                    ++ qualified combine.alias combine.rightKey
                    ++ " IS NULL)"
                )

        Exclude ->
            Just
                ("NOT EXISTS (SELECT 1 FROM "
                    ++ ident combine.table
                    ++ " AS "
                    ++ ident combine.alias
                    ++ " WHERE "
                    ++ qualified combine.alias combine.rightKey
                    ++ " = "
                    ++ qualified combine.leftAlias combine.leftKey
                    ++ ")"
                )

        _ ->
            Nothing


maybeLine : String -> Maybe String -> List String
maybeLine prefix value =
    case value of
        Just v ->
            [ prefix ++ v ]

        Nothing ->
            []


sort : Ast.SortSpec -> String
sort spec =
    ident spec.column
        ++ (case spec.direction of
                Asc ->
                    ""

                Desc ->
                    " DESC"
           )


projection : Checked -> String
projection checked =
    case checked.projection of
        All ->
            "*"

        Extended fields ->
            -- The row as it was, plus what the window computed. `*` rather
            -- than the columns spelled out, because an extend does not know
            -- or care what they are.
            String.join ", "
                ("*" :: List.map (\( name, e ) -> expr e ++ " AS " ++ ident name) fields)

        Fields fields ->
            let
                visible =
                    List.map (\( name, e ) -> expr e ++ " AS " ++ ident name) fields

                -- Payload columns the generated decoder reads but the row type
                -- does not expose. Selected under their own names.
                hidden =
                    List.map (\( alias, name, _ ) -> qualified alias name ++ " AS " ++ ident name) checked.hidden
            in
            String.join ", " (visible ++ hidden)


{-| A window function, without its OVER clause, which `over` supplies.

Only the ranking and offset functions are spelled out here. Everything else in
an `extend` is an ordinary aggregate and goes through `aggregate`, so it keeps
the one spelling — `correlation` became `correlation(...)` rather than
`corr(...)` while this had a name table of its own.

-}
windowCall : String -> List String -> String
windowCall fn args =
    case ( fn, args ) of
        ( "rowNumber", [] ) ->
            "row_number()"

        ( "denseRank", [] ) ->
            "dense_rank()"

        _ ->
            aggregate fn args


over : CheckedWindow -> String
over window =
    let
        parts =
            (case window.partition of
                [] ->
                    []

                keys ->
                    [ "PARTITION BY " ++ (keys |> List.map expr |> String.join ", ") ]
            )
                ++ (window.order |> Maybe.map (\spec -> "ORDER BY " ++ sort spec) |> maybeToList)
    in
    " OVER (" ++ String.join " " parts ++ ")"


expr : TExpr -> String
expr e =
    case e of
        TCol alias name _ ->
            qualified alias name

        TLit literal _ ->
            lit literal

        TBin op left right _ ->
            "(" ++ expr left ++ " " ++ sqlOp op ++ " " ++ expr right ++ ")"

        TNot inner ->
            "NOT (" ++ expr inner ++ ")"

        TAgg fn args _ ->
            aggregate fn (List.map expr args)

        TWin fn args window _ ->
            windowCall fn (List.map expr args) ++ over window

        TCall fn args _ ->
            call fn (List.map expr args)

        TCast inner _ ->
            -- A custom type exists only in the Elm output; SQL carries the
            -- underlying tag column through untouched.
            expr inner


{-| Each aggregate's DuckDB spelling. Two need more than a rename: a distinct
count is a modifier rather than a function, and `quantile` reads better with
the fraction first while DuckDB wants it last.
-}
aggregate : String -> List String -> String
aggregate fn args =
    case ( fn, args ) of
        ( "count", [] ) ->
            "count(*)"

        ( "countDistinct", [ a ] ) ->
            "count(DISTINCT " ++ a ++ ")"

        ( "stdDev", [ a ] ) ->
            "stddev(" ++ a ++ ")"

        ( "quantile", [ fraction, a ] ) ->
            "quantile_cont(" ++ a ++ ", " ++ fraction ++ ")"

        ( "correlation", [ a, b ] ) ->
            "corr(" ++ a ++ ", " ++ b ++ ")"

        ( "covarPop", [ a, b ] ) ->
            "covar_pop(" ++ a ++ ", " ++ b ++ ")"

        ( "covarSamp", [ a, b ] ) ->
            "covar_samp(" ++ a ++ ", " ++ b ++ ")"

        ( "regrSlope", [ a, b ] ) ->
            "regr_slope(" ++ a ++ ", " ++ b ++ ")"

        ( "regrIntercept", [ a, b ] ) ->
            "regr_intercept(" ++ a ++ ", " ++ b ++ ")"

        ( "regrR2", [ a, b ] ) ->
            "regr_r2(" ++ a ++ ", " ++ b ++ ")"

        ( "regrCount", [ a, b ] ) ->
            -- DuckDB returns UINTEGER, which the row type calls Int; the cast
            -- keeps the value and the type agreeing across the port.
            "CAST(regr_count(" ++ a ++ ", " ++ b ++ ") AS BIGINT)"

        ( "countWhere", [ predicate ] ) ->
            "count(*) FILTER (WHERE " ++ predicate ++ ")"

        ( "sumWhere", [ a, predicate ] ) ->
            "sum(" ++ a ++ ") FILTER (WHERE " ++ predicate ++ ")"

        ( "avgWhere", [ a, predicate ] ) ->
            "avg(" ++ a ++ ") FILTER (WHERE " ++ predicate ++ ")"

        _ ->
            fn ++ "(" ++ String.join ", " args ++ ")"


{-| Each function's DuckDB spelling. The casts are not decoration: `round`
and `floor` are typed here as returning an integer, and DuckDB returns a
double, so without them the column type and the value would disagree.
-}
call : String -> List String -> String
call fn args =
    case ( fn, args ) of
        ( "startOfDay", [ a ] ) ->
            "date_trunc('day', " ++ a ++ ")"

        ( "startOfMonth", [ a ] ) ->
            "date_trunc('month', " ++ a ++ ")"

        ( "startOfYear", [ a ] ) ->
            "date_trunc('year', " ++ a ++ ")"

        ( "dayOfWeek", [ a ] ) ->
            "dayofweek(" ++ a ++ ")"

        ( "round", [ a ] ) ->
            "CAST(round(" ++ a ++ ") AS BIGINT)"

        ( "floor", [ a ] ) ->
            "CAST(floor(" ++ a ++ ") AS BIGINT)"

        ( "ceiling", [ a ] ) ->
            "CAST(ceil(" ++ a ++ ") AS BIGINT)"

        ( "roundTo", [ digits, a ] ) ->
            "round(" ++ a ++ ", " ++ digits ++ ")"

        _ ->
            fn ++ "(" ++ String.join ", " args ++ ")"


sqlOp : Op -> String
sqlOp op =
    case op of
        Eq ->
            "="

        Neq ->
            "<>"

        And ->
            "AND"

        Or ->
            "OR"

        Concat ->
            "||"

        _ ->
            Ast.opSymbol op


lit : Literal -> String
lit literal =
    case literal of
        LInt n ->
            String.fromInt n

        LFloat f ->
            String.fromFloat f

        LBool True ->
            "TRUE"

        LBool False ->
            "FALSE"

        LString s ->
            "'" ++ String.replace "'" "''" s ++ "'"

        LTimestamp iso ->
            "TIMESTAMP '" ++ String.replace "'" "''" iso ++ "'"


qualified : String -> String -> String
qualified alias column =
    ident alias ++ "." ++ ident column


ident : String -> String
ident name =
    "\"" ++ String.replace "\"" "\"\"" name ++ "\""
