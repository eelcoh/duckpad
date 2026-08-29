port module TestRunner exposing (main)

{-| A dependency-free test harness for the pure half of the engine.

Run with `mise run test`. This deliberately avoids elm-test: the modules under
test have no effects, so a `Platform.worker` that reports a list of checks is
enough, and it keeps the spike free of an npm toolchain it does not otherwise
need.

-}

import Cell exposing (Cell, Kind(..), Status(..))
import Dag
import Deps
import Dict exposing (Dict)
import Engine exposing (CellState)
import Hash
import Json.Encode as E
import Query exposing (Table)
import Set


port report : E.Value -> Cmd msg


type alias Check =
    { name : String
    , ok : Bool
    , detail : String
    }


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), report (E.list encode allChecks) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


encode : Check -> E.Value
encode c =
    E.object
        [ ( "name", E.string c.name )
        , ( "ok", E.bool c.ok )
        , ( "detail", E.string c.detail )
        ]


allChecks : List Check
allChecks =
    depsChecks ++ dagChecks ++ hashChecks ++ engineChecks


assert : String -> Bool -> Check
assert name ok =
    { name = name, ok = ok, detail = "" }


equal : String -> a -> a -> Check
equal name expected actual =
    { name = name
    , ok = expected == actual
    , detail =
        if expected == actual then
            ""

        else
            "expected " ++ Debug.toString expected ++ ", got " ++ Debug.toString actual
    }



-- DEPS


depsChecks : List Check
depsChecks =
    [ assert "deps: finds a table reference"
        (Set.member "orders" (Deps.identifiers "SELECT * FROM orders WHERE x > 1"))
    , assert "deps: ignores names inside string literals"
        (not (Set.member "orders" (Deps.identifiers "SELECT 'orders' AS label")))
    , assert "deps: ignores names in line comments"
        (not (Set.member "orders" (Deps.identifiers "-- reads orders\nSELECT 1")))
    , assert "deps: ignores names in block comments"
        (not (Set.member "orders" (Deps.identifiers "/* orders */ SELECT 1")))
    , assert "deps: collects double-quoted identifiers"
        (Set.member "my_cell" (Deps.identifiers "SELECT * FROM \"my_cell\""))
    , assert "deps: splits qualified names on the dot"
        (Deps.identifiers "SELECT orders.total FROM orders"
            |> (\s -> Set.member "orders" s && Set.member "total" s)
        )
    , assert "deps: an escaped quote does not end the literal early"
        (not (Set.member "orders" (Deps.identifiers "SELECT 'it''s orders' AS x")))
    , assert "deps: resumes collecting after a comment ends"
        (Set.member "later" (Deps.identifiers "-- skip\nSELECT * FROM later"))
    ]



-- DAG


chain : Dag.Graph
chain =
    Dag.build
        [ ( "a", Set.fromList [ "read_csv_auto" ] )
        , ( "b", Set.fromList [ "a" ] )
        , ( "c", Set.fromList [ "b" ] )
        ]


diamond : Dag.Graph
diamond =
    Dag.build
        [ ( "top", Set.empty )
        , ( "left", Set.fromList [ "top" ] )
        , ( "right", Set.fromList [ "top" ] )
        , ( "join", Set.fromList [ "left", "right" ] )
        ]


dagChecks : List Check
dagChecks =
    [ equal "dag: unknown identifiers are not edges"
        Set.empty
        (Dag.dependenciesOf "a" chain)
    , equal "dag: a chain sorts upstream first"
        (Ok [ "a", "b", "c" ])
        (Dag.topoSort chain)
    , equal "dag: self-reference is not a cycle"
        (Ok [ "solo" ])
        (Dag.topoSort (Dag.build [ ( "solo", Set.fromList [ "solo" ] ) ]))
    , equal "dag: a two-cell cycle is reported, not sorted"
        (Err [ "x", "y" ])
        (Dag.topoSort
            (Dag.build
                [ ( "x", Set.fromList [ "y" ] )
                , ( "y", Set.fromList [ "x" ] )
                ]
            )
        )
    , equal "dag: an acyclic cell alongside a cycle still sorts"
        (Err [ "x", "y" ])
        (Dag.topoSort
            (Dag.build
                [ ( "ok", Set.empty )
                , ( "x", Set.fromList [ "y" ] )
                , ( "y", Set.fromList [ "x" ] )
                ]
            )
            |> Result.mapError (List.filter (\i -> i /= "ok"))
        )
    , equal "dag: diamond respects both branches before the join"
        (Ok [ "top", "left", "right", "join" ])
        (Dag.topoSort diamond)
    , equal "dag: downstream closure is transitive and includes the seed"
        (Set.fromList [ "a", "b", "c" ])
        (Dag.downstreamClosure (Set.singleton "a") chain)
    , equal "dag: downstream closure of a leaf is just the leaf"
        (Set.fromList [ "c" ])
        (Dag.downstreamClosure (Set.singleton "c") chain)
    , equal "dag: dependents are the reverse of dependencies"
        (Set.fromList [ "left", "right" ])
        (Dag.dependentsOf "top" diamond)
    , equal "dag: execution order follows file order, not alphabetical"
        (Ok [ "zulu", "alpha" ])
        (Dag.topoSort
            (Dag.build
                [ ( "zulu", Set.empty )
                , ( "alpha", Set.fromList [ "zulu" ] )
                ]
            )
        )
    ]



-- HASH


hashChecks : List Check
hashChecks =
    let
        long =
            String.repeat 4000 "abcdefghij"
    in
    [ equal "hash: deterministic"
        (Hash.toString (Hash.ofString "select 1"))
        (Hash.toString (Hash.ofString "select 1"))
    , assert "hash: distinguishes similar strings"
        (Hash.toString (Hash.ofString "select 1") /= Hash.toString (Hash.ofString "select 2"))
    , assert "hash: stays inside 32 bits over a long input"
        (case String.toInt (Hash.toString (Hash.ofString long)) of
            Just n ->
                n >= 0 && n <= 4294967295

            Nothing ->
                False
        )
    , assert "hash: order matters when combining"
        (Hash.toString (Hash.combine (Hash.ofString "a") (Hash.ofString "b"))
            /= Hash.toString (Hash.combine (Hash.ofString "b") (Hash.ofString "a"))
        )
    ]



-- ENGINE


cellB : Cell
cellB =
    { id = "b", kind = Query, source = "SELECT * FROM a" }


tableWith : String -> Table
tableWith hash =
    { columns = [], rows = [], rowCount = 0, truncated = False, hash = hash, millis = 0 }


freshState : String -> CellState
freshState hash =
    { status = Fresh { cached = False, millis = 1 }
    , table = Just (tableWith hash)
    , valueHash = Just hash
    , keyForValue = Nothing
    }


statesWith : String -> Dict String CellState
statesWith upstreamHash =
    Dict.fromList
        [ ( "a", freshState upstreamHash )
        , ( "b", Engine.initialState )
        ]


withStatus : Status -> CellState -> CellState
withStatus status state =
    { state | status = status }


engineChecks : List Check
engineChecks =
    let
        baseline =
            Engine.cacheKeyFor chain (statesWith "H1") cellB
    in
    [ assert "engine: cache key changes when the cell's own source changes"
        (baseline /= Engine.cacheKeyFor chain (statesWith "H1") { cellB | source = "SELECT 1" })
    , assert "engine: cache key changes when an upstream value changes"
        (baseline /= Engine.cacheKeyFor chain (statesWith "H2") cellB)
    , assert "engine: cache key is stable when nothing relevant changed"
        (baseline == Engine.cacheKeyFor chain (statesWith "H1") cellB)
    , assert "engine: cache key changes when the cell is renamed"
        (baseline /= Engine.cacheKeyFor chain (statesWith "H1") { cellB | id = "b2" })
    , equal "engine: a fresh upstream does not block"
        Nothing
        (Engine.blockingUpstream chain (statesWith "H1") "b")
    , equal "engine: a failed upstream blocks"
        (Just "a")
        (Engine.blockingUpstream chain
            (Dict.insert "a" (withStatus (Failed "boom") (freshState "H1")) (statesWith "H1"))
            "b"
        )
    , equal "engine: a stale upstream blocks rather than being read"
        (Just "a")
        (Engine.blockingUpstream chain
            (Dict.insert "a" (withStatus Stale (freshState "H1")) (statesWith "H1"))
            "b"
        )
    , equal "engine: marking stale reaches transitive dependents"
        [ Just Stale, Just Stale, Just Stale ]
        (let
            all =
                Dict.fromList
                    [ ( "a", freshState "H1" )
                    , ( "b", freshState "H2" )
                    , ( "c", freshState "H3" )
                    ]

            marked =
                Engine.markStale (Set.singleton "a") chain all
         in
         [ "a", "b", "c" ] |> List.map (\i -> Dict.get i marked |> Maybe.map .status)
        )
    , equal "engine: marking stale keeps the old value for the cache to reuse"
        (Just True)
        (Engine.markStale (Set.singleton "a") chain (statesWith "H1")
            |> Dict.get "a"
            |> Maybe.map Engine.hasValue
        )
    , assert "engine: a never-run cell has no value"
        (not (Engine.hasValue Engine.initialState))
    ]
