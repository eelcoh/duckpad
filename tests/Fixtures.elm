port module Fixtures exposing (main)

{-| Emits the compiler's output for a set of fixture cells so an external
harness can check the two claims Elm cannot check for itself: that the
generated SQL runs against a real DuckDB, and that the generated Elm module
actually compiles.

Run through `mise run roundtrip`.

-}

import Dict
import Dsl.Compile
import Dsl.Schema exposing (Schema, Type(..))
import Json.Encode as E


port emit : E.Value -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), emit (E.list encode (List.indexedMap compileFixture fixtures)) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Mirrors the tables the harness builds in DuckDB from the sample CSV.
-}
schema : Schema
schema =
    Dict.fromList
        [ ( "orders"
          , [ ( "id", TInt )
            , ( "owner", TString )
            , ( "region", TString )
            , ( "status", TString )
            , ( "delivered_at", TMaybe TTimestamp )
            , ( "total", TFloat )
            ]
          )
        , ( "vips", [ ( "owner", TString ) ] )
        , ( "regions", [ ( "region", TString ) ] )
        ]


fixtures : List ( String, String )
fixtures =
    [ ( "passthrough"
      , "access orders () |> selectAll"
      )
    , ( "filter_and_map"
      , """
access orders ()
  |> filter (\\o -> o.total > 100.0 && o.owner /= "ada")
  |> map (\\o -> { who = o.owner, amount = o.total, big = o.total > 500.0 })
  |> selectAll
"""
      )
    , ( "grouped"
      , """
access orders ()
  |> filter (\\o -> o.status == "delivered")
  |> groupBy .region
  |> reduce (\\g -> { region = g.region, n = count g, revenue = sum g.total, biggest = max g.total })
  |> sortBy (desc .revenue)
  |> selectAll
"""
      )
    , ( "custom_type"
      , """
type Status
  = Submitted "submitted"
  | InTransit "in_transit"
  | Delivered "delivered" from .delivered_at

access orders ()
  |> filter (\\o -> o.total > 50.0)
  |> map (\\o -> { id = o.id, owner = o.owner, status = o.status as Status, total = o.total })
  |> selectAll
"""
      )
    , ( "nullable_and_arithmetic"
      , """
access orders ()
  |> map (\\o -> { when = o.delivered_at, doubled = o.total * 2.0, ratio = o.total / 3.0 })
  |> limit 20
  |> selectAll
"""
      )
    , ( "intersected"
      , """
access orders ()
  |> map (\\o -> { owner = o.owner })
  |> intersect vips
  |> sortBy .owner
  |> selectAll
"""
      )
    , ( "single_row"
      , """
access orders ()
  |> filter (\\o -> o.id == 1)
  |> map (\\o -> { owner = o.owner, total = o.total })
  |> select
"""
      )
    ]


compileFixture : Int -> ( String, String ) -> E.Value
compileFixture index ( name, source ) =
    let
        moduleName =
            "Gen" ++ String.fromInt index
    in
    case Dsl.Compile.compile schema moduleName source of
        Ok compiled ->
            E.object
                [ ( "name", E.string name )
                , ( "module", E.string moduleName )
                , ( "ok", E.bool True )
                , ( "sql", E.string compiled.sql )
                , ( "elm", E.string compiled.elmModule )
                ]

        Err message ->
            E.object
                [ ( "name", E.string name )
                , ( "module", E.string moduleName )
                , ( "ok", E.bool False )
                , ( "error", E.string message )
                ]


encode : E.Value -> E.Value
encode =
    identity
