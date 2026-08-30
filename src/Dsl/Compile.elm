module Dsl.Compile exposing (Compiled, compile, readsOf)

{-| The front door: source text and a schema, in; SQL, an Elm module, and the
metadata the notebook engine needs, out.

`reads` is the part the engine cares about most. Phase 1 guessed a cell's
dependencies by scanning its text for identifiers that happened to match a
cell name; once a cell is written in the DSL the compiler simply knows, so the
guess can be retired for those cells.

-}

import Dsl.Ast exposing (Expr(..), Field, GroupKeys(..), Lambda, Pattern(..), Pipeline, Stage(..), TypeDecl)
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

    -- Whether this cell asked for a row order. The value cache's content hash
    -- is order-insensitive, so only a cell that sorts or limits needs the
    -- stricter comparison.
    , orderSignificant : Bool
    }


compile : Schema -> Check.Params -> String -> String -> Result String Compiled
compile schema params moduleName source =
    Dsl.Parser.parse source
        |> Result.andThen
            (\ast ->
                Check.check schema params ast
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
    , orderSignificant = checked.orderSignificant
    }


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
