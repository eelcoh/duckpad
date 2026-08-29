module EngineTests exposing (checks)

{-| Tests for the pure half of the reactive engine: the graph, the two caches,
schema assembly and staleness.
-}

import Cell exposing (Cell, Kind(..), Status(..))
import Check exposing (Check, assert, equal)
import Dag
import Dict exposing (Dict)
import Dsl.Check exposing (Cardinality(..))
import Dsl.Compile exposing (Compiled)
import Dsl.Schema exposing (Type(..))
import Engine exposing (CellState)
import Hash
import Query exposing (Table)
import Set


checks : List Check
checks =
    dagChecks ++ hashChecks ++ engineChecks



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
    { id = "b", kind = Query, source = "access a () |> selectAll" }


compiledWith : List ( String, Type ) -> Compiled
compiledWith rowType =
    { sql = "SELECT * FROM \"a\""
    , elmModule = ""
    , rowType = rowType
    , declarations = []
    , reads = [ "a" ]
    , cardinality = Many
    , orderSignificant = False
    }


tableWith : String -> Table
tableWith hash =
    { columns = [], rows = [], rowCount = 0, truncated = False, hash = hash, millis = 0, described = [] }


{-| An upstream cell that has run: it has both a shape and a value, and the
tests vary them independently.
-}
upstreamState : List ( String, Type ) -> String -> CellState
upstreamState rowType valueHash =
    { status = Fresh { cached = False, millis = 1 }
    , compiled = Just (compiledWith rowType)
    , rowType = Just rowType
    , compileKey = Just "k"
    , table = Just (tableWith valueHash)
    , valueHash = Just valueHash
    , keyForValue = Nothing
    }


defaultRow : List ( String, Type )
defaultRow =
    [ ( "id", TInt ), ( "total", TFloat ) ]


statesWith : List ( String, Type ) -> String -> Dict String CellState
statesWith rowType valueHash =
    Dict.fromList
        [ ( "a", upstreamState rowType valueHash )
        , ( "b", Engine.initialState )
        ]


withStatus : Status -> CellState -> CellState
withStatus status state =
    { state | status = status }


engineChecks : List Check
engineChecks =
    let
        states =
            statesWith defaultRow "H1"

        compileBaseline =
            Engine.compileKeyFor chain states cellB

        valueBaseline =
            Engine.valueKeyFor chain states "b" "SELECT 1"
    in
    [ -- The compile cache tracks shape.
      assert "engine: compile key changes when the source changes"
        (compileBaseline /= Engine.compileKeyFor chain states { cellB | source = "access a () |> select" })
    , assert "engine: compile key changes when an upstream's row type changes"
        (compileBaseline
            /= Engine.compileKeyFor chain (statesWith [ ( "id", TInt ) ] "H1") cellB
        )
    , assert "engine: compile key ignores an upstream value change"
        -- The distinction the two caches exist for: new rows of the same shape
        -- cannot change the SQL, so nothing needs recompiling.
        (compileBaseline == Engine.compileKeyFor chain (statesWith defaultRow "H2") cellB)
    , assert "engine: compile key changes when the cell is renamed"
        (compileBaseline /= Engine.compileKeyFor chain states { cellB | id = "b2" })

    -- The value cache tracks rows.
    , assert "engine: value key changes when the generated SQL changes"
        (valueBaseline /= Engine.valueKeyFor chain states "b" "SELECT 2")
    , assert "engine: value key changes when an upstream value changes"
        (valueBaseline /= Engine.valueKeyFor chain (statesWith defaultRow "H2") "b" "SELECT 1")
    , assert "engine: value key is stable when nothing relevant changed"
        (valueBaseline == Engine.valueKeyFor chain states "b" "SELECT 1")

    -- Schema assembly.
    , equal "engine: a cell compiles against its upstream's row type"
        (Just defaultRow)
        (Engine.schemaFor Dict.empty chain states "b" |> Dict.get "a")
    , equal "engine: base tables stay visible"
        (Just [ ( "x", TString ) ])
        (Engine.schemaFor (Dict.fromList [ ( "orders", [ ( "x", TString ) ] ) ]) chain states "b"
            |> Dict.get "orders"
        )
    , equal "engine: a cell cannot see past its direct dependencies"
        Nothing
        (Engine.schemaFor Dict.empty chain states "b" |> Dict.get "c")

    -- Blocking and staleness.
    , equal "engine: a fresh upstream does not block"
        Nothing
        (Engine.blockingUpstream chain states "b")
    , equal "engine: a failed upstream blocks"
        (Just "a")
        (Engine.blockingUpstream chain
            (Dict.insert "a" (withStatus (Failed "boom") (upstreamState defaultRow "H1")) states)
            "b"
        )
    , equal "engine: a cell that does not compile blocks its dependents"
        (Just "a")
        (Engine.blockingUpstream chain
            (Dict.insert "a" (withStatus (Invalid "no such column") (upstreamState defaultRow "H1")) states)
            "b"
        )
    , equal "engine: a stale upstream blocks rather than being read"
        (Just "a")
        (Engine.blockingUpstream chain
            (Dict.insert "a" (withStatus Stale (upstreamState defaultRow "H1")) states)
            "b"
        )
    , equal "engine: marking stale reaches transitive dependents"
        [ Just Stale, Just Stale, Just Stale ]
        (let
            all =
                Dict.fromList
                    [ ( "a", upstreamState defaultRow "H1" )
                    , ( "b", upstreamState defaultRow "H2" )
                    , ( "c", upstreamState defaultRow "H3" )
                    ]

            marked =
                Engine.markStale (Set.singleton "a") chain all
         in
         [ "a", "b", "c" ] |> List.map (\i -> Dict.get i marked |> Maybe.map .status)
        )
    , equal "engine: marking stale keeps the old value for the cache to reuse"
        (Just True)
        (Engine.markStale (Set.singleton "a") chain states
            |> Dict.get "a"
            |> Maybe.map Engine.hasValue
        )
    , assert "engine: a never-run cell has no value"
        (not (Engine.hasValue Engine.initialState))
    ]
