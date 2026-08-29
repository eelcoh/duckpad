module Engine exposing
    ( CellState
    , blockingUpstream
    , cacheKeyFor
    , hasValue
    , initialState
    , markStale
    )

{-| The pure half of the reactive engine: what is stale, what may run, and
whether a run can be skipped. Everything here is a function of the graph and
the current cell states, so it can be reasoned about without DuckDB in the
picture.
-}

import Cell exposing (Cell, Status(..))
import Dag exposing (Graph)
import Dict exposing (Dict)
import Hash
import Query exposing (Table)
import Set exposing (Set)


type alias CellState =
    { status : Status
    , table : Maybe Table
    , valueHash : Maybe String
    , keyForValue : Maybe String
    }


initialState : CellState
initialState =
    { status = NeverRun
    , table = Nothing
    , valueHash = Nothing
    , keyForValue = Nothing
    }


hasValue : CellState -> Bool
hasValue state =
    case state.table of
        Just _ ->
            True

        Nothing ->
            False


{-| The value-cache key: this cell's own identity and source, plus the *values*
its upstreams currently hold.

Keying on upstream values rather than on "did an upstream re-run" is what stops
propagation early: editing a cell in a way that produces an identical result
leaves every downstream key unchanged, so nothing below it re-executes. The
cell's own id is part of the key because the id is also the name of the table
this cell materialises into.

-}
cacheKeyFor : Graph -> Dict String CellState -> Cell -> String
cacheKeyFor graph states cell =
    let
        upstreamHashes =
            Dag.dependenciesOf cell.id graph
                |> Set.toList
                |> List.map
                    (\dep ->
                        Dict.get dep states
                            |> Maybe.andThen .valueHash
                            |> Maybe.withDefault "?"
                    )
    in
    (cell.id :: cell.source :: upstreamHashes)
        |> String.join "\u{0000}"
        |> Hash.ofString
        |> Hash.toString


{-| The first upstream cell that cannot supply a value, if any.

A cell whose upstream failed is `Blocked`, never "run anyway against whatever
table happens to still be lying around in the database".

-}
blockingUpstream : Graph -> Dict String CellState -> String -> Maybe String
blockingUpstream graph states id =
    Dag.dependenciesOf id graph
        |> Set.toList
        |> List.filter (\dep -> not (isUsable dep states))
        |> List.head


isUsable : String -> Dict String CellState -> Bool
isUsable id states =
    case Dict.get id states |> Maybe.map .status of
        Just (Fresh _) ->
            True

        _ ->
            False


{-| Mark the seeds and everything downstream of them stale.

The previous value is deliberately kept on the state: it is what the value
cache may still be able to reuse. The `Stale` status is what stops the UI from
presenting it as current.

-}
markStale : Set String -> Graph -> Dict String CellState -> Dict String CellState
markStale seeds graph states =
    Dag.downstreamClosure seeds graph
        |> Set.foldl
            (\id acc ->
                Dict.update id (Maybe.map (\s -> { s | status = Stale })) acc
            )
            states
