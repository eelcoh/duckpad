module Dag exposing
    ( Graph
    , build
    , dependenciesOf
    , dependentsOf
    , downstreamClosure
    , topoSort
    )

{-| The notebook's dependency graph.

Cell order in the file is reading order, chosen by the author. Execution order
is this graph's topological order. The two are kept deliberately separate: the
file must never be reshuffled just because the graph shape changed.

File order is still used here as the tie-break whenever several cells are
independently runnable, so execution order is deterministic and matches what
the reader sees rather than depending on Dict iteration order.

-}

import Dict exposing (Dict)
import Set exposing (Set)


type alias Graph =
    { order : List String
    , edges : Dict String (Set String)
    , reverse : Dict String (Set String)
    }


{-| Build the graph from each cell's id and the raw identifiers its source
mentions. Identifiers that do not name a cell are left alone (they are real
tables, functions or keywords), and self-references are dropped so that a cell
reading a table of its own name is not a one-node cycle.
-}
build : List ( String, Set String ) -> Graph
build cells =
    let
        known =
            Set.fromList (List.map Tuple.first cells)

        edges =
            cells
                |> List.map
                    (\( id, mentioned ) ->
                        ( id
                        , mentioned
                            |> Set.intersect known
                            |> Set.remove id
                        )
                    )
                |> Dict.fromList
    in
    { order = List.map Tuple.first cells
    , edges = edges
    , reverse = invert edges
    }


invert : Dict String (Set String) -> Dict String (Set String)
invert edges =
    Dict.foldl
        (\from tos acc ->
            Set.foldl
                (\to inner ->
                    Dict.update to
                        (Just << Set.insert from << Maybe.withDefault Set.empty)
                        inner
                )
                acc
                tos
        )
        (Dict.map (\_ _ -> Set.empty) edges)
        edges


dependenciesOf : String -> Graph -> Set String
dependenciesOf id graph =
    Dict.get id graph.edges |> Maybe.withDefault Set.empty


dependentsOf : String -> Graph -> Set String
dependentsOf id graph =
    Dict.get id graph.reverse |> Maybe.withDefault Set.empty


{-| Every cell reachable downstream of the seeds, seeds included. This is the
blast radius of an edit: exactly the set that must be marked stale.
-}
downstreamClosure : Set String -> Graph -> Set String
downstreamClosure seeds graph =
    expand (Set.toList seeds) graph seeds


expand : List String -> Graph -> Set String -> Set String
expand frontier graph seen =
    case frontier of
        [] ->
            seen

        id :: rest ->
            let
                fresh =
                    dependentsOf id graph
                        |> Set.filter (\d -> not (Set.member d seen))
            in
            expand (Set.toList fresh ++ rest) graph (Set.union fresh seen)


{-| Topological order, or the cells caught in a cycle.

Cycles are a notebook-level error rather than a runtime surprise: nothing runs
until the author breaks the loop, which is the whole reason the graph is built
from source text instead of discovered by executing.

-}
topoSort : Graph -> Result (List String) (List String)
topoSort graph =
    sortStep graph (Set.fromList graph.order) Set.empty []


sortStep : Graph -> Set String -> Set String -> List String -> Result (List String) (List String)
sortStep graph remaining emitted acc =
    if Set.isEmpty remaining then
        Ok (List.reverse acc)

    else
        let
            ready =
                graph.order
                    |> List.filter (\id -> Set.member id remaining)
                    |> List.filter
                        (\id ->
                            dependenciesOf id graph
                                |> Set.toList
                                |> List.all (\d -> Set.member d emitted)
                        )
        in
        case ready of
            [] ->
                Err (List.filter (\id -> Set.member id remaining) graph.order)

            _ ->
                sortStep graph
                    (List.foldl Set.remove remaining ready)
                    (List.foldl Set.insert emitted ready)
                    (List.reverse ready ++ acc)
