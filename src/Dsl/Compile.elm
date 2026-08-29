module Dsl.Compile exposing (Compiled, compile)

{-| The front door: source text and a schema, in; SQL, an Elm module, and the
metadata the notebook engine needs, out.

`reads` is the part the engine cares about most. Phase 1 guessed a cell's
dependencies by scanning its text for identifiers that happened to match a
cell name; once a cell is written in the DSL the compiler simply knows, so the
guess can be retired for those cells.

-}

import Dsl.Check as Check exposing (Cardinality, Checked)
import Dsl.ElmGen
import Dsl.Parser
import Dsl.Schema exposing (Schema, Type)
import Dsl.Sql


type alias Compiled =
    { sql : String
    , elmModule : String
    , rowType : List ( String, Type )
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
    , reads = checked.reads
    , cardinality = checked.cardinality
    , orderSignificant = checked.orderSignificant
    }
