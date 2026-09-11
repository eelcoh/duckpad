module Dsl.Compile exposing (Compiled, compile, readsOf, typeRefsOf)

{-| The front door: source text and a schema, in; SQL, an Elm module, and the
metadata the notebook engine needs, out.

`reads` is the part the engine cares about most. Phase 1 guessed a cell's
dependencies by scanning its text for identifiers that happened to match a
cell name; once a cell is written in the DSL the compiler simply knows, so the
guess can be retired for those cells.

-}

import Dict exposing (Dict)
import Dsl.Ast exposing (Expr(..), Field, GroupKeys(..), Lambda, Literal(..), Pattern(..), Pipeline, Stage(..), TypeDecl)
import Set exposing (Set)
import Dsl.Check as Check exposing (Cardinality, Checked, Display)
import Dsl.ElmGen
import Dsl.Parser
import Dsl.Schema exposing (Schema, Type)
import Dsl.Sql


type alias Compiled =
    { sql : String
    , elmModule : String
    , rowType : List ( String, Type )

    -- Carried through so the notebook can render a custom-typed column as its
    -- constructor rather than as the raw tag sitting in the database.
    , declarations : List TypeDecl
    , reads : List String
    , cardinality : Cardinality
    , display : Display

    -- How many decimal places each rounded column asked for. See
    -- `declaredDecimals`: the value cannot carry this, so the table does.
    , decimals : Dict String Int

    -- Whether this cell asked for a row order. The value cache's content hash
    -- is order-insensitive, so only a cell that sorts or limits needs the
    -- stricter comparison.
    , orderSignificant : Bool
    }


compile : Schema -> Check.Params -> List TypeDecl -> String -> String -> Result String Compiled
compile schema params inherited moduleName source =
    Dsl.Parser.parse source
        |> Result.andThen
            (\ast ->
                Check.check schema params inherited ast
                    |> Result.map (assemble moduleName ast)
            )


assemble : String -> Pipeline -> Checked -> Compiled
assemble moduleName ast checked =
    { sql = Dsl.Sql.render checked
    , elmModule = Dsl.ElmGen.render moduleName checked
    , rowType = checked.rowType
    , declarations = checked.declarations
    , reads = checked.reads ++ Set.toList (freeVars ast)
    , cardinality = checked.cardinality
    , display = checked.display
    , decimals = declaredDecimals checked
    , orderSignificant = checked.orderSignificant
    }


{-| Columns that asked to be rounded to a fixed number of decimal places, and
how many they asked for.

A double has no scale: 12.50 and 12.5 are one value, so `roundTo 2` loses its
trailing zero the moment the last digit is one, long before anything renders
it. Nothing downstream can recover that from the number — but the checker
knows what was asked for, and this carries the intent to the table so it can
put the zeros back.

Only a `roundTo` that *is* the whole field counts. `roundTo 2 g.total + 1` is
not a two-decimal quantity, and padding it would advertise a precision the
arithmetic does not have.

-}
declaredDecimals : Checked -> Dict String Int
declaredDecimals checked =
    let
        fields =
            case checked.projection of
                Check.All ->
                    []

                Check.Fields declared ->
                    declared

                Check.Extended declared ->
                    declared
    in
    fields
        |> List.filterMap
            (\( name, expr ) ->
                case expr of
                    Check.TCall "roundTo" [ Check.TLit (LInt places) _, _ ] _ ->
                        if places > 0 then
                            Just ( name, places )

                        else
                            -- `roundTo 0` and the negative "round to tens"
                            -- spellings produce whole numbers; there is no
                            -- fractional part to pad.
                            Nothing

                    _ ->
                        Nothing
            )
        |> Dict.fromList


{-| The tables a cell reads, from the parse alone.

The notebook needs the dependency graph *before* it can compile anything,
because compiling a cell requires the row types of the cells upstream of it,
and it only knows which those are once the graph exists. Parsing settles the
question without a schema: a source and its `intersect` targets are syntax.

A cell that does not parse reads nothing, which leaves it an isolated node
reporting its own error rather than silently poisoning the order.

-}
readsOf : String -> List String
readsOf source =
    case Dsl.Parser.parse source of
        Ok ast ->
            (ast.source :: List.filterMap tableTarget ast.stages)
                ++ Set.toList (freeVars ast)

        Err _ ->
            []


{-| Declared type names a query applies. The notebook resolves these in a
separate namespace to type cells before building the graph.
-}
typeRefsOf : String -> List String
typeRefsOf source =
    case Dsl.Parser.parse source of
        Ok ast ->
            let
                local =
                    ast.declarations |> List.map .name |> Set.fromList
            in
            ast.stages
                |> List.concatMap stageTypeRefs
                |> Set.fromList
                |> (\refs -> Set.diff refs local)
                |> Set.toList

        Err _ ->
            []


stageTypeRefs : Stage -> List String
stageTypeRefs stage =
    case stage of
        Filter lambda ->
            exprTypeRefs lambda.body

        Map lambda ->
            exprTypeRefs lambda.body

        Reduce lambda ->
            exprTypeRefs lambda.body

        GroupBy (ByExpressions lambda) ->
            exprTypeRefs lambda.body

        Extend lambda ->
            exprTypeRefs lambda.body

        _ ->
            []


exprTypeRefs : Expr -> List String
exprTypeRefs expr =
    case expr of
        Cast inner name ->
            name :: exprTypeRefs inner

        Record fields ->
            List.concatMap (\field -> exprTypeRefs field.value) fields

        Binary _ left right ->
            exprTypeRefs left ++ exprTypeRefs right

        Not inner ->
            exprTypeRefs inner

        Aggregate _ args ->
            List.concatMap exprTypeRefs args

        Call _ args ->
            List.concatMap exprTypeRefs args

        _ ->
            []


{-| Names the cell mentions that no lambda bound.

An input cell's value is bound to its name, so a bare name that is not a
parameter is a reference to one — which is what puts the input in the graph
ahead of the cell that reads it. Anything else unbound is an error the checker
will report; collecting it here only means the graph knows about the edge that
was intended.

-}
freeVars : Pipeline -> Set String
freeVars ast =
    ast.stages |> List.map stageVars |> List.foldl Set.union Set.empty


stageVars : Stage -> Set String
stageVars stage =
    case stage of
        Filter lambda ->
            lambdaVars lambda

        Map lambda ->
            lambdaVars lambda

        Reduce lambda ->
            lambdaVars lambda

        GroupBy (ByExpressions lambda) ->
            lambdaVars lambda

        _ ->
            Set.empty


lambdaVars : Lambda -> Set String
lambdaVars lambda =
    exprVars (bound lambda.pattern) lambda.body


bound : Pattern -> Set String
bound pattern =
    case pattern of
        Single name ->
            Set.singleton name

        Destructure names ->
            Set.fromList names


exprVars : Set String -> Expr -> Set String
exprVars scope expr =
    case expr of
        Var name ->
            if Set.member name scope then
                Set.empty

            else
                Set.singleton name

        Record fields ->
            fields |> List.map (\f -> exprVars scope f.value) |> List.foldl Set.union Set.empty

        Binary _ left right ->
            Set.union (exprVars scope left) (exprVars scope right)

        Not inner ->
            exprVars scope inner

        Aggregate _ args ->
            args |> List.map (exprVars scope) |> List.foldl Set.union Set.empty

        Call _ args ->
            args |> List.map (exprVars scope) |> List.foldl Set.union Set.empty

        Cast inner _ ->
            exprVars scope inner

        _ ->
            Set.empty


tableTarget : Stage -> Maybe String
tableTarget stage =
    case stage of
        Combine _ _ other _ ->
            Just other

        _ ->
            Nothing
