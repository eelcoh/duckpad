module Dsl.Sql exposing (render)

{-| Typed IR to DuckDB SQL.

One of two renderings of `Dsl.Check.Checked`. It never re-derives a name or a
type: anything this module needs to know was settled by the checker, which is
what keeps it in step with the generated Elm.

-}

import Dsl.Ast as Ast exposing (JoinKind(..), Literal(..), Op(..), SortDir(..))
import Dsl.Check exposing (Checked, CheckedJoin, Projection(..), TExpr(..))
import Dsl.Schema exposing (Type(..))


render : Checked -> String
render checked =
    let
        core =
            ([ "SELECT " ++ projection checked
             , "FROM " ++ ident checked.source
             ]
                ++ List.map joinClause checked.joins
            )
                ++ maybeLine "WHERE " (Maybe.map expr checked.filter)
                ++ maybeLine "GROUP BY " (Maybe.map (ident << Tuple.first) checked.groupBy)
                |> String.join "\n"

        withIntersects =
            case checked.intersects of
                [] ->
                    core

                others ->
                    -- Parenthesised so the trailing ORDER BY / LIMIT applies
                    -- to the whole set operation rather than its last branch.
                    ("(" ++ core ++ ")")
                        :: List.map (\o -> "INTERSECT\n(SELECT * FROM " ++ ident o ++ ")") others
                        |> String.join "\n"
    in
    (withIntersects :: tail checked)
        |> String.join "\n"


{-| Columns are never qualified by table here, and do not need to be: the
checker rejects a join whose sides share a column name, except the equi-join
key it turns into `USING`. Every name in the merged row is therefore unique.
-}
joinClause : CheckedJoin -> String
joinClause join =
    let
        keyword =
            case join.kind of
                Inner ->
                    "JOIN "

                LeftOuter ->
                    "LEFT JOIN "

        condition =
            case ( join.using, join.on ) of
                ( Just key, _ ) ->
                    " USING (" ++ ident key ++ ")"

                ( Nothing, Just predicate ) ->
                    " ON " ++ expr predicate

                ( Nothing, Nothing ) ->
                    ""
    in
    keyword ++ ident join.table ++ condition


tail : Checked -> List String
tail checked =
    maybeLine "ORDER BY " (Maybe.map sort checked.sort)
        ++ maybeLine "LIMIT " (Maybe.map String.fromInt checked.limit)


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
                    List.map (ident << Tuple.first) checked.hidden
            in
            String.join ", " (visible ++ hidden)


expr : TExpr -> String
expr e =
    case e of
        TCol name _ ->
            ident name

        TLit literal _ ->
            lit literal

        TBin op left right _ ->
            "(" ++ expr left ++ " " ++ sqlOp op ++ " " ++ expr right ++ ")"

        TNot inner ->
            "NOT (" ++ expr inner ++ ")"

        TAgg fn Nothing _ ->
            fn ++ "(*)"

        TAgg fn (Just column) _ ->
            fn ++ "(" ++ ident column ++ ")"

        TCast inner _ ->
            -- A custom type exists only in the Elm output; SQL carries the
            -- underlying tag column through untouched.
            expr inner


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


ident : String -> String
ident name =
    "\"" ++ String.replace "\"" "\"\"" name ++ "\""
