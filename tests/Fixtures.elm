port module Fixtures exposing (main)

{-| Emits the compiler's output for a set of fixture cells so an external
harness can check the two claims Elm cannot check for itself: that the
generated SQL runs against a real DuckDB, and that the generated Elm module
actually compiles.

Run through `mise run roundtrip`.

-}

import Dict
import Dsl.Ast exposing (Literal(..))
import Dsl.Check
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
        , ( "customers", [ ( "owner", TString ), ( "tier", TString ), ( "joined", TTimestamp ) ] )
        , ( "people", [ ( "person", TString ), ( "rank", TInt ) ] )

        -- The two sources the seeded notebook ships with.
        , ( "airports"
          , [ ( "iata", TString )
            , ( "name", TString )
            , ( "city", TString )
            , ( "state", TString )
            , ( "country", TString )
            , ( "latitude", TFloat )
            , ( "longitude", TFloat )
            ]
          )
        , ( "flights"
          , [ ( "date", TTimestamp )
            , ( "delay", TInt )
            , ( "distance", TInt )
            , ( "origin", TString )
            , ( "destination", TString )
            ]
          )
        ]


{-| The values the seeded notebook's input cells are bound to, so the cells
that read them can be checked like any other.
-}
params : Dsl.Check.Params
params =
    Dict.fromList [ ( "min_distance", ( TFloat, LFloat 0 ) ) ]


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
    , ( "excluded"
      , """
access orders ()
  |> exclude .owner vips .owner
  |> map (\\o -> { owner = o.owner, total = o.total })
  |> sortBy .owner
  |> selectAll
"""
      )
    , ( "intersected"
      , """
access orders ()
  |> intersect .owner customers .owner
  |> filter (\\(o, c) -> c.tier == "gold")
  |> groupBy .tier
  |> reduce (\\g -> { tier = g.tier, spend = sum g.total, n = count g })
  |> sortBy (desc .spend)
  |> selectAll
"""
      )
    , ( "differenced"
      , """
access orders ()
  |> diff .owner people .person
  |> map (\\(o, p) -> { who = o.owner, standing = p.rank, amount = o.total })
  |> limit 25
  |> selectAll
"""
      )
      -- Every query cell the seeded notebook ships with, so that what a
      -- reader first sees is known to compile and to run.
    , ( "seeded_total_flights"
      , """
access flights ()
  |> filter (\\f -> f.distance >= min_distance)
  |> reduce (\\g -> { flights = count g })
  |> scalar
"""
      )
    , ( "seeded_by_state"
      , """
access flights ()
  |> filter (\\f -> f.distance >= min_distance)
  |> intersect .origin airports .iata
  |> groupBy .state
  |> reduce (\\g ->
       { state = g.state
       , departures = count g
       , avg_delay = roundTo 1 (avg g.delay)
       })
  |> sortBy (desc .departures)
  |> limit 12
  |> barChart { x = .state, y = .departures }
"""
      )
    , ( "seeded_punctuality"
      , """
access flights ()
  |> intersect .origin airports .iata
  |> groupBy .state
  |> reduce (\\g ->
       { state = g.state
       , early = countWhere (g.delay <= 0)
       , late = countWhere (g.delay > 30)
       , worst = max g.delay
       })
  |> filter (\\r -> r.late > 2000)
  |> sortBy (desc .late)
  |> selectAll
"""
      )
    , ( "seeded_daily"
      , """
access flights ()
  |> groupBy (\\f -> { day = startOfDay f.date })
  |> reduce (\\g ->
       { day = g.day
       , flights = count g
       })
  |> sortBy .day
  |> lineChart { x = .day, y = .flights }
"""
      )
    , ( "seeded_delay_by_distance"
      , """
access flights ()
  |> groupBy .distance
  |> reduce (\\g ->
       { distance = g.distance
       , avg_delay = roundTo 1 (avg g.delay)
       , flights = count g
       })
  |> filter (\\r -> r.flights > 500)
  |> lineChart { x = .distance, y = .avg_delay }
"""
      )
    , ( "seeded_airport_map"
      , """
access airports ()
  |> filter (\\a -> a.longitude > -130.0 && a.latitude > 22.0)
  |> map (\\a ->
       { lon = a.longitude
       , lat = a.latitude
       })
  |> scatter { x = .lon, y = .lat }
"""
      )
    , ( "seeded_routes"
      , """
access flights ()
  |> intersect .origin airports .iata
  |> intersect .destination airports .iata
  |> map (\\(f, orig, dest) ->
       { route = orig.city ++ " → " ++ dest.city
       , miles = f.distance
       , delay = f.delay
       })
  |> limit 200
  |> selectAll
"""
      )
    , ( "seeded_quiet"
      , """
type Country
  = Usa "USA"
  | Marianas "N Mariana Islands"
  | Palau "Palau"
  | Thailand "Thailand"
  | Micronesia "Federated States of Micronesia"

access airports ()
  |> exclude .iata flights .origin
  |> map (\\a ->
       { code = a.iata
       , city = a.city
       , country = a.country as Country
       })
  |> sortBy .code
  |> selectAll
"""
      )
      -- Busiest routes: the query that could not be written before, because
      -- grouping took a single key.
    , ( "busiest_routes"
      , """
access flights ()
  |> groupBy .origin .destination
  |> reduce (\\g ->
       { origin = g.origin
       , destination = g.destination
       , flights = count g
       , avg_delay = roundTo 1 (avg g.delay)
       })
  |> sortBy (desc .flights)
  |> limit 20
  |> selectAll
"""
      )
    , ( "self_combined"
      , """
access orders ()
  |> intersect .owner orders .owner
  |> map (\\(a, b) -> { left = a.id, right = b.id, who = a.owner })
  |> limit 10
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
    case Dsl.Compile.compile schema params moduleName source of
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
