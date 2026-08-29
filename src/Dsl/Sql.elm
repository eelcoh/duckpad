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
        ++ maybeLine "GROUP BY " (Maybe.map groupKey checked.groupBy)
        ++ maybeLine "ORDER BY " (Maybe.map sort checked.sort)
        ++ maybeLine "LIMIT " (Maybe.map String.fromInt checked.limit)
    )
        |> String.join "\n"


groupKey : ( String, String, a ) -> String
groupKey ( alias, column, _ ) =
    qualified alias column


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


antiJoin : CheckedCombine -> Maybe String
antiJoin combine =
    case combine.kind of
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

        TAgg fn Nothing _ ->
            fn ++ "(*)"

        TAgg fn (Just ( alias, column )) _ ->
            fn ++ "(" ++ qualified alias column ++ ")"

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


qualified : String -> String -> String
qualified alias column =
    ident alias ++ "." ++ ident column


ident : String -> String
ident name =
    "\"" ++ String.replace "\"" "\"\"" name ++ "\""
