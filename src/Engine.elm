module Engine exposing
    ( CellState
    , Shape
    , blockingUpstream
    , display
    , compileKeyFor
    , hasValue
    , initialState
    , markStale
    , schemaFor
    , valueKeyFor
    )

{-| The pure half of the reactive engine: what is stale, what may run, and
whether either half of the work can be skipped.

There are two caches, and they answer different questions. The compile cache
asks "could this cell's SQL have changed?", which depends on the cell's source
and on the *row types* of its inputs. The value cache asks "could this cell's
rows have changed?", which depends on the generated SQL and on the *values* of
its inputs. An upstream edit that alters rows but not the shape of them
invalidates the second and not the first.

-}

import Cell exposing (Cell, Status(..))
import Dsl.Ast exposing (TypeDecl)
import Dag exposing (Graph)
import Dict exposing (Dict)
import Dsl.Check exposing (ChartSpec, Display(..))
import Dsl.Compile exposing (Compiled)
import Dsl.Schema as Schema exposing (Schema, Type)
import Hash
import Query exposing (Table)
import Set


type alias CellState =
    { status : Status
    , compiled : Maybe Compiled

    -- What downstream cells compile against. A query cell gets this from its
    -- own compilation; a source cell gets it from DuckDB, which is the only
    -- thing that knows what is actually in the file.
    , rowType : Maybe (List ( String, Type ))
    , compileKey : Maybe String
    , table : Maybe Table
    , valueHash : Maybe String
    , keyForValue : Maybe String
    }


initialState : CellState
initialState =
    { status = NeverRun
    , compiled = Nothing
    , rowType = Nothing
    , compileKey = Nothing
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


{-| The schema a cell compiles against: the database's own tables, plus the row
type of every cell upstream of it.

Only direct dependencies are added. A cell cannot name a table it never
declared it reads, so exposing the whole notebook here would let a typo
silently resolve against an unrelated cell.

-}
schemaFor : Schema -> Graph -> Dict String CellState -> String -> Schema
schemaFor base graph states id =
    Dag.dependenciesOf id graph
        |> Set.foldl
            (\dep acc ->
                case Dict.get dep states |> Maybe.andThen .rowType of
                    Just rowType ->
                        Dict.insert dep rowType acc

                    Nothing ->
                        acc
            )
            base


{-| Keyed on the source and on the shape of the inputs, because those are the
only things the generated SQL can depend on.
-}
compileKeyFor : Graph -> Dict String CellState -> Cell -> String
compileKeyFor graph states cell =
    (cell.id :: cell.source :: upstream signatureOf graph states cell.id)
        |> join
        |> Hash.toString


{-| Keyed on the generated SQL rather than the source: two different sources
that compile to the same query really do have the same value, and an upstream
whose row type changed shows up here through the SQL as well as through the
value hashes.
-}
valueKeyFor : Graph -> Dict String CellState -> String -> String -> String
valueKeyFor graph states id sql =
    (id :: sql :: upstream valueHashOf graph states id)
        |> join
        |> Hash.toString


upstream : (CellState -> String) -> Graph -> Dict String CellState -> String -> List String
upstream extract graph states id =
    Dag.dependenciesOf id graph
        |> Set.toList
        |> List.map
            (\dep ->
                Dict.get dep states
                    |> Maybe.map extract
                    |> Maybe.withDefault "?"
            )


join : List String -> Hash.Hash
join parts =
    Hash.ofString (String.join "\u{0000}" parts)


{-| What a dependent cell's *compilation* can depend on.

For a query or a source that is the shape of the rows. For an input it is the
value itself, because an input's value is inlined into the SQL — so moving a
control really does change what its dependents compile to, and a signature
that ignored it would hand back a stale query from the compile cache.

-}
signatureOf : CellState -> String
signatureOf state =
    case state.rowType of
        Just rowType ->
            rowType
                |> List.map (\( name, t ) -> name ++ ":" ++ Schema.typeName t)
                |> String.join ","

        Nothing ->
            Maybe.withDefault "?" state.valueHash


valueHashOf : CellState -> String
valueHashOf state =
    Maybe.withDefault "?" state.valueHash


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

The previous value and compilation are deliberately kept: they are what the
caches may still be able to reuse. The `Stale` status is what stops the UI from
presenting the value as current.

-}
markStale : Set.Set String -> Graph -> Dict String CellState -> Dict String CellState
markStale seeds graph states =
    Dag.downstreamClosure seeds graph
        |> Set.foldl
            (\id acc ->
                Dict.update id (Maybe.map (\s -> { s | status = Stale })) acc
            )
            states


{-| What is needed to render a cell's result: the row type, whatever declared
types its columns refer to, and whether the order means anything.

A query cell has all of that on its compilation. A source cell is never
compiled — DuckDB reports its row type instead — so it has to be handled
separately. Forgetting that is why a source used to show "Running…" under a
pill that already said it was fresh.

-}
type alias Shape =
    { rowType : List ( String, Type )
    , declarations : List TypeDecl
    , ordered : Bool
    , chart : Maybe ChartSpec
    , scalar : Bool
    }


display : CellState -> Maybe Shape
display state =
    case state.compiled of
        Just compiled ->
            Just
                { rowType = compiled.rowType
                , declarations = compiled.declarations
                , ordered = compiled.orderSignificant
                , chart =
                    case compiled.display of
                        AsChart spec ->
                            Just spec

                        _ ->
                            Nothing
                , scalar = compiled.display == AsScalar
                }

        Nothing ->
            state.rowType
                |> Maybe.map
                    (\rowType ->
                        { rowType = rowType
                        , declarations = []
                        , ordered = False
                        , chart = Nothing
                        , scalar = False
                        }
                    )
