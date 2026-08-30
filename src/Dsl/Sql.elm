module Dsl.Sql exposing (render)

{-| Typed IR to DuckDB SQL.

One of two renderings of `Dsl.Check.Checked`. It never re-derives a name or a
type: anything this module needs to know was settled by the checker, which is
what keeps it in step with the generated Elm.

-}

import Dsl.Ast as Ast exposing (CombineKind(..), Literal(..), Op(..), SortDir(..))
import Dsl.Check exposing (Checked, CheckedCombine, Projection(..), TExpr(..))
import Dsl.Schema exposing (Type(..))


render : Checked -> String
render checked =
    ([ "SELECT " ++ projection checked
     , "FROM " ++ ident checked.source ++ " AS " ++ ident checked.sourceAlias
     ]
        ++ List.filterMap joinClause checked.combines
        ++ maybeLine "WHERE " (whereClause checked)
        ++ maybeLine "GROUP BY " (groupKeys checked.groupBy)
        ++ maybeLine "HAVING " (Maybe.map expr checked.having)
        ++ maybeLine "ORDER BY " (Maybe.map sort checked.sort)
        ++ maybeLine "LIMIT " (Maybe.map String.fromInt checked.limit)
    )
        |> String.join "\n"


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
