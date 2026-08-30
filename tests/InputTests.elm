module InputTests exposing (checks)

{-| Tests for input cells: the control language, and the fact that a widget's
value reaches a query as an inlined literal.
-}

import Cell exposing (Kind(..))
import Check exposing (Check, equal, isErr)
import Dict
import Dsl.Ast exposing (Literal(..))
import Dsl.Compile
import Dsl.Input as Input
import Dsl.Schema exposing (Schema, Type(..))
import Notebook


checks : List Check
checks =
    specChecks ++ bindingChecks ++ formatChecks


specChecks : List Check
specChecks =
    [ equal "input: a range, with a step derived when none is given"
        (Ok (Input.Range { min = 0, max = 100, step = 1, default = 50 }))
        (Input.parse "range 0 100 default 50")
    , equal "input: an explicit step is kept"
        (Ok (Input.Range { min = 0, max = 10, step = 0.5, default = 2 }))
        (Input.parse "range 0 10 step 0.5 default 2")
    , equal "input: negative bounds"
        (Ok (Input.Range { min = -20, max = 20, step = 0.4, default = 0 }))
        (Input.parse "range -20 20 default 0")
    , equal "input: a select"
        (Ok (Input.Select { options = [ "north", "south" ], default = "south" }))
        (Input.parse "select \"north\" \"south\" default \"south\"")
    , equal "input: a range is a number and a select is text"
        [ TFloat, TString ]
        [ Input.valueType (Input.Range { min = 0, max = 1, step = 1, default = 0 })
        , Input.valueType (Input.Select { options = [ "a" ], default = "a" })
        ]
    , isErr "input: the bounds have to be the right way round"
        (Input.parse "range 100 0 default 50")
    , isErr "input: the default has to sit between the bounds"
        (Input.parse "range 0 10 default 50")
    , isErr "input: a select's default has to be one of its options"
        (Input.parse "select \"a\" \"b\" default \"c\"")
    , isErr "input: a select needs options"
        (Input.parse "select default \"a\"")
    , isErr "input: an unknown control is refused"
        (Input.parse "dial 0 10 default 5")
    ]



-- BINDING


schema : Schema
schema =
    Dict.fromList
        [ ( "orders", [ ( "owner", TString ), ( "total", TFloat ) ] ) ]


compileWith : List ( String, ( Type, Literal ) ) -> String -> Result String Dsl.Compile.Compiled
compileWith params =
    Dsl.Compile.compile schema (Dict.fromList params) "Generated"


bindingChecks : List Check
bindingChecks =
    [ equal "input: a bound name reaches the query as a literal"
        -- Inlined rather than passed as a parameter, which is what makes
        -- moving a control change the SQL and so invalidate the cache.
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE (\"orders\".\"total\" > 250)")
        (compileWith [ ( "threshold", ( TFloat, LFloat 250 ) ) ]
            "access orders () |> filter (\\o -> o.total > threshold) |> selectAll"
            |> Result.map .sql
        )
    , equal "input: a text value is escaped like any other literal"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE (\"orders\".\"owner\" = 'it''s')")
        (compileWith [ ( "who", ( TString, LString "it's" ) ) ]
            "access orders () |> filter (\\o -> o.owner == who) |> selectAll"
            |> Result.map .sql
        )
    , isErr "input: a name nothing bound is still an error"
        (compileWith [] "access orders () |> filter (\\o -> o.total > threshold) |> selectAll")
    , isErr "input: a bound value still has to typecheck"
        (compileWith [ ( "who", ( TString, LString "ada" ) ) ]
            "access orders () |> filter (\\o -> o.total > who) |> selectAll"
        )
    , equal "input: reading a value puts the input in the graph"
        -- Which is what orders the input ahead of the cell that reads it.
        [ "orders", "threshold" ]
        (Dsl.Compile.readsOf "access orders () |> filter (\\o -> o.total > threshold) |> selectAll")
    , equal "input: a lambda's own parameter is not a dependency"
        [ "orders" ]
        (Dsl.Compile.readsOf "access orders () |> groupBy .owner |> reduce (\\g -> { n = count g }) |> selectAll")
    ]



-- FILE FORMAT


formatChecks : List Check
formatChecks =
    [ equal "input: an input block round-trips through the file format"
        (Ok [ ( "threshold", Input ), ( "big", Query ) ])
        (Notebook.parse "```input threshold\nrange 0 100 default 50\n```\n\n```acadia big\naccess orders () |> selectAll\n```"
            |> Result.map (.cells >> List.map (\c -> ( c.id, c.kind )))
        )
    ]
