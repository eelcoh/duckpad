module Dsl.Compile exposing (Compiled, compile, readsOf)

{-| The front door: source text and a schema, in; SQL, an Elm module, and the
metadata the notebook engine needs, out.

`reads` is the part the engine cares about most. Phase 1 guessed a cell's
dependencies by scanning its text for identifiers that happened to match a
cell name; once a cell is written in the DSL the compiler simply knows, so the
guess can be retired for those cells.

-}

import Dsl.Ast exposing (Stage(..), TypeDecl)
import Dsl.Check as Check exposing (Cardinality, Checked)
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

    -- Whether this cell asked for a row order. The value cache's content hash
    -- is order-insensitive, so only a cell that sorts or limits needs the
    -- stricter comparison.
    , orderSignificant : Bool
    }


compile : Schema -> String -> String -> Result String Compiled
compile schema moduleName source =
    Dsl.Parser.parse source
        |> Result.andThen (Check.check schema)
        |> Result.map (assemble moduleName)


assemble : String -> Checked -> Compiled
assemble moduleName checked =
    { sql = Dsl.Sql.render checked
    , elmModule = Dsl.ElmGen.render moduleName checked
    , rowType = checked.rowType
    , declarations = checked.declarations
    , reads = checked.reads
    , cardinality = checked.cardinality
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
            ast.source :: List.filterMap tableTarget ast.stages

        Err _ ->
            []


tableTarget : Stage -> Maybe String
tableTarget stage =
    case stage of
        Combine _ _ other _ ->
            Just other

        _ ->
            Nothing
