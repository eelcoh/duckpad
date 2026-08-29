module Main exposing (main)

{-| Phase 1 + 2 spike: a reactive notebook shell over DuckDB-wasm.

The query cells hold raw SQL, which is a stand-in. Phase 3 replaces the cell
body with the pipeline DSL and the hand-written decoder in `Spike.Orders` with
generated code; the engine underneath is meant to survive that swap unchanged,
which is exactly what this spike is for.

-}

import Browser
import Cell exposing (Cell, Kind(..), Status(..))
import Dag exposing (Graph)
import Deps
import Dict exposing (Dict)
import Engine exposing (CellState)
import Html exposing (Html, button, div, h1, h2, input, label, li, ol, p, section, span, table, tbody, td, text, textarea, th, thead, tr, ul)
import Html.Attributes exposing (class, classList, disabled, placeholder, rows, title, value)
import Html.Events exposing (onBlur, onClick, onInput)
import Json.Decode as D
import Ports
import Query exposing (Outcome(..), Table)
import Set exposing (Set)
import Spike.Orders as Orders



-- MODEL


type alias Model =
    { cells : List Cell
    , states : Dict String CellState
    , queue : List String
    , current : Maybe String
    , db : DbStatus
    , nextId : Int
    }


type DbStatus
    = Booting
    | Ready
    | DbFailed String


type Msg
    = DbReady D.Value
    | GotOutcome D.Value
    | SourceEdited String String
    | NameEdited String String
    | CommitEdit
    | AddCell Kind
    | DeleteCell String
    | RunAll


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { cells = seedNotebook
      , states =
            seedNotebook
                |> List.map (\c -> ( c.id, Engine.initialState ))
                |> Dict.fromList
      , queue = []
      , current = Nothing
      , db = Booting
      , nextId = 1
      }
    , Cmd.none
    )


{-| A three-deep chain, so the graph has something to actually order, plus a
prose cell to show that narrative is a first-class part of the file.
-}
seedNotebook : List Cell
seedNotebook =
    [ { id = "intro"
      , kind = Prose
      , source = "Edit any query and blur the field: this cell and everything downstream of it are marked stale, then re-run in dependency order. Cells whose inputs did not actually change come back as `cached` without touching DuckDB."
      }
    , { id = "orders"
      , kind = Query
      , source = "SELECT id, owner, region, status,\n       epoch_ms(delivered_at) AS delivered_at,\n       total\nFROM read_csv_auto('orders.csv')"
      }
    , { id = "delivered"
      , kind = Query
      , source = "SELECT * FROM orders WHERE status = 'delivered'"
      }
    , { id = "by_region"
      , kind = Query
      , source = "SELECT region,\n       count(*) AS n,\n       round(sum(total), 2) AS revenue\nFROM delivered\nGROUP BY region\nORDER BY revenue DESC"
      }
    ]



-- GRAPH


graphOf : Model -> Graph
graphOf model =
    model.cells
        |> List.filter (\c -> c.kind == Query)
        |> List.map (\c -> ( c.id, Deps.identifiers c.source ))
        |> Dag.build


stateOf : String -> Model -> CellState
stateOf id model =
    Dict.get id model.states |> Maybe.withDefault Engine.initialState


findCell : String -> Model -> Maybe Cell
findCell id model =
    model.cells |> List.filter (\c -> c.id == id) |> List.head


setStatus : String -> Status -> Dict String CellState -> Dict String CellState
setStatus id status states =
    Dict.update id
        (\existing ->
            existing
                |> Maybe.withDefault Engine.initialState
                |> (\s -> Just { s | status = status })
        )
        states



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DbReady payload ->
            case D.decodeValue dbReadyDecoder payload of
                Ok Nothing ->
                    schedule { model | db = Ready }

                Ok (Just err) ->
                    ( { model | db = DbFailed err }, Cmd.none )

                Err err ->
                    ( { model | db = DbFailed (D.errorToString err) }, Cmd.none )

        GotOutcome payload ->
            case D.decodeValue Query.outcomeDecoder payload of
                Ok outcome ->
                    applyOutcome outcome model

                Err err ->
                    -- A malformed payload is a bug in the bridge, not in the
                    -- notebook; surface it on the cell that was running.
                    case model.current of
                        Just id ->
                            advance
                                { model
                                    | current = Nothing
                                    , states = setStatus id (Failed (D.errorToString err)) model.states
                                }

                        Nothing ->
                            ( model, Cmd.none )

        SourceEdited id newSource ->
            let
                cells =
                    model.cells
                        |> List.map
                            (\c ->
                                if c.id == id then
                                    { c | source = newSource }

                                else
                                    c
                            )

                updated =
                    { model | cells = cells }
            in
            -- Staleness propagates on every keystroke; execution waits for the
            -- edit to be committed. A debounce timer would go here instead.
            ( { updated
                | states = Engine.markStale (Set.singleton id) (graphOf updated) updated.states
              }
            , Cmd.none
            )

        NameEdited id newName ->
            renameCell id (sanitiseName newName) model

        CommitEdit ->
            schedule model

        AddCell kind ->
            let
                fresh =
                    { id = freshName kind model
                    , kind = kind
                    , source =
                        case kind of
                            Query ->
                                ""

                            Prose ->
                                "Notes."
                    }
            in
            ( { model
                | cells = model.cells ++ [ fresh ]
                , states = Dict.insert fresh.id Engine.initialState model.states
                , nextId = model.nextId + 1
              }
            , Cmd.none
            )

        DeleteCell id ->
            let
                remaining =
                    List.filter (\c -> c.id /= id) model.cells

                updated =
                    { model
                        | cells = remaining
                        , states = Dict.remove id model.states
                    }
            in
            ( { updated
                | states =
                    Engine.markStale
                        (Dag.dependentsOf id (graphOf model))
                        (graphOf updated)
                        updated.states
              }
            , Ports.dropTable id
            )

        RunAll ->
            schedule (invalidateAll model)


dbReadyDecoder : D.Decoder (Maybe String)
dbReadyDecoder =
    D.field "ok" D.bool
        |> D.andThen
            (\ok ->
                if ok then
                    D.succeed Nothing

                else
                    D.map Just (D.field "error" D.string)
            )


{-| Renaming is an identity change: the old table has to go, and every cell has
to be reconsidered because an edge may have appeared or vanished.
-}
renameCell : String -> String -> Model -> ( Model, Cmd Msg )
renameCell old new model =
    if new == old || new == "" || List.any (\c -> c.id == new) model.cells then
        ( model, Cmd.none )

    else
        let
            cells =
                model.cells
                    |> List.map
                        (\c ->
                            if c.id == old then
                                { c | id = new }

                            else
                                c
                        )

            states =
                case Dict.get old model.states of
                    Just s ->
                        model.states
                            |> Dict.remove old
                            |> Dict.insert new { s | status = Stale, keyForValue = Nothing }

                    Nothing ->
                        model.states

            updated =
                { model | cells = cells, states = states }
        in
        ( { updated | states = invalidate updated.states }
        , Ports.dropTable old
        )


invalidateAll : Model -> Model
invalidateAll model =
    { model | states = invalidate model.states }


invalidate : Dict String CellState -> Dict String CellState
invalidate =
    Dict.map (\_ s -> { s | status = Stale, keyForValue = Nothing })


{-| Rebuild the run queue in topological order and start walking it.
-}
schedule : Model -> ( Model, Cmd Msg )
schedule model =
    if model.db /= Ready then
        ( model, Cmd.none )

    else
        case Dag.topoSort (graphOf model) of
            Err cyclic ->
                ( { model
                    | queue = []
                    , current = Nothing
                    , states =
                        List.foldl (\id acc -> setStatus id (InCycle cyclic) acc)
                            model.states
                            cyclic
                  }
                , Cmd.none
                )

            Ok order ->
                advance { model | queue = order, current = Nothing }


{-| Walk the queue until something has to actually hit the database.

Cache hits and blocked cells are resolved inline, so a run where nothing
changed completes without a single round trip.

-}
advance : Model -> ( Model, Cmd Msg )
advance model =
    case model.queue of
        [] ->
            ( { model | current = Nothing }, Cmd.none )

        id :: rest ->
            case findCell id model of
                Nothing ->
                    advance { model | queue = rest }

                Just cell ->
                    if not (Cell.isRunnable cell) then
                        advance { model | queue = rest }

                    else
                        dispatch cell rest model


dispatch : Cell -> List String -> Model -> ( Model, Cmd Msg )
dispatch cell rest model =
    let
        graph =
            graphOf model

        state =
            stateOf cell.id model

        key =
            Engine.cacheKeyFor graph model.states cell
    in
    case Engine.blockingUpstream graph model.states cell.id of
        Just upstream ->
            advance
                { model
                    | queue = rest
                    , states = setStatus cell.id (Blocked upstream) model.states
                }

        Nothing ->
            if state.keyForValue == Just key && Engine.hasValue state then
                advance
                    { model
                        | queue = rest
                        , states =
                            setStatus cell.id
                                (Fresh
                                    { cached = True
                                    , millis = state.table |> Maybe.map .millis |> Maybe.withDefault 0
                                    }
                                )
                                model.states
                    }

            else
                ( { model
                    | queue = rest
                    , current = Just cell.id
                    , states = setStatus cell.id Running model.states
                  }
                , Ports.materialize { cellId = cell.id, sql = cell.source }
                )


applyOutcome : Outcome -> Model -> ( Model, Cmd Msg )
applyOutcome outcome model =
    case outcome of
        Success id result ->
            let
                key =
                    findCell id model
                        |> Maybe.map (Engine.cacheKeyFor (graphOf model) model.states)
            in
            advance
                { model
                    | current = Nothing
                    , states =
                        Dict.insert id
                            { status = Fresh { cached = False, millis = result.millis }
                            , table = Just result
                            , valueHash = Just result.hash
                            , keyForValue = key
                            }
                            model.states
                }

        Failure id err ->
            -- Downstream cells are not marked here: `advance` reaches them in
            -- topological order and blocks them through `blockingUpstream`,
            -- so there is one code path for "an input is unusable".
            advance
                { model
                    | current = Nothing
                    , states = setStatus id (Failed err) model.states
                }


sanitiseName : String -> String
sanitiseName raw =
    raw
        |> String.toLower
        |> String.filter (\c -> Char.isAlphaNum c || c == '_')


freshName : Kind -> Model -> String
freshName kind model =
    let
        stem =
            case kind of
                Query ->
                    "cell_"

                Prose ->
                    "note_"

        candidate n =
            stem ++ String.fromInt n
    in
    if List.any (\c -> c.id == candidate model.nextId) model.cells then
        candidate (model.nextId + List.length model.cells)

    else
        candidate model.nextId



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Ports.queryOutcome GotOutcome
        , Ports.dbReady DbReady
        ]



-- VIEW


view : Model -> Html Msg
view model =
    let
        graph =
            graphOf model
    in
    div [ class "app" ]
        [ viewHeader model graph
        , div [ class "cells" ] (List.map (viewCell model graph) model.cells)
        , div [ class "add-row" ]
            [ button [ onClick (AddCell Query) ] [ text "+ query cell" ]
            , button [ onClick (AddCell Prose) ] [ text "+ prose cell" ]
            ]
        ]


viewHeader : Model -> Graph -> Html Msg
viewHeader model graph =
    div [ class "topbar" ]
        [ div []
            [ h1 [] [ text "Acadia notebook" ]
            , p [ class "sub" ] [ text "Phase 1+2 spike — reactive graph over DuckDB-wasm" ]
            ]
        , div [ class "topbar-right" ]
            [ viewExecutionOrder graph
            , viewDbStatus model.db
            , button
                [ onClick RunAll
                , disabled (model.db /= Ready)
                , title "Discard every cached value and re-run the whole graph"
                ]
                [ text "Run all" ]
            ]
        ]


viewDbStatus : DbStatus -> Html Msg
viewDbStatus db =
    case db of
        Booting ->
            span [ class "pill pill-running" ] [ text "duckdb booting…" ]

        Ready ->
            span [ class "pill pill-fresh" ] [ text "duckdb ready" ]

        DbFailed err ->
            span [ class "pill pill-failed", title err ] [ text "duckdb failed" ]


viewExecutionOrder : Graph -> Html Msg
viewExecutionOrder graph =
    case Dag.topoSort graph of
        Ok order ->
            span [ class "order" ]
                [ span [ class "order-label" ] [ text "execution order" ]
                , text (String.join " → " order)
                ]

        Err cyclic ->
            span [ class "order order-bad" ]
                [ text ("cycle: " ++ String.join " ↔ " cyclic) ]


viewCell : Model -> Graph -> Cell -> Html Msg
viewCell model graph cell =
    let
        state =
            stateOf cell.id model
    in
    section [ class "cell", classList [ ( "cell-prose", cell.kind == Prose ) ] ]
        [ div [ class "cell-head" ]
            [ input
                [ class "cell-name"
                , value cell.id
                , onInput (NameEdited cell.id)
                , onBlur CommitEdit
                ]
                []
            , span [ class "kind" ] [ text (Cell.kindLabel cell.kind) ]
            , viewStatus cell state.status
            , span [ class "spacer" ] []
            , viewEdges graph cell
            , button [ class "danger", onClick (DeleteCell cell.id) ] [ text "×" ]
            ]
        , textarea
            [ class "cell-source"
            , value cell.source
            , rows (max 3 (List.length (String.lines cell.source)))
            , placeholder
                (case cell.kind of
                    Query ->
                        "SELECT …"

                    Prose ->
                        "Notes…"
                )
            , onInput (SourceEdited cell.id)
            , onBlur CommitEdit
            ]
            []
        , viewOutput cell state
        ]


viewEdges : Graph -> Cell -> Html Msg
viewEdges graph cell =
    let
        deps =
            Dag.dependenciesOf cell.id graph |> Set.toList

        users =
            Dag.dependentsOf cell.id graph |> Set.toList

        part name items =
            if List.isEmpty items then
                []

            else
                [ span [ class "edge" ]
                    [ span [ class "edge-label" ] [ text name ]
                    , text (String.join ", " items)
                    ]
                ]
    in
    span [ class "edges" ] (part "reads" deps ++ part "feeds" users)


viewStatus : Cell -> Status -> Html Msg
viewStatus cell status =
    let
        ( cls, label ) =
            case status of
                Fresh { cached, millis } ->
                    ( if cached then
                        "pill-cached"

                      else
                        "pill-fresh"
                    , Cell.statusLabel status
                        ++ (if cached then
                                ""

                            else
                                " · " ++ String.fromInt (round millis) ++ "ms"
                           )
                    )

                Running ->
                    ( "pill-running", "running" )

                Stale ->
                    ( "pill-stale", "stale" )

                Failed _ ->
                    ( "pill-failed", "failed" )

                Blocked _ ->
                    ( "pill-blocked", Cell.statusLabel status )

                InCycle _ ->
                    ( "pill-failed", "cycle" )

                _ ->
                    ( "pill-idle", Cell.statusLabel status )
    in
    if cell.kind == Prose then
        text ""

    else
        span [ class ("pill " ++ cls) ] [ text label ]


viewOutput : Cell -> CellState -> Html Msg
viewOutput cell state =
    if cell.kind == Prose then
        text ""

    else
        case state.status of
            Failed err ->
                div [ class "out out-error" ] [ text err ]

            Blocked upstream ->
                div [ class "out out-blocked" ]
                    [ text ("Not run: upstream cell `" ++ upstream ++ "` has no usable value.") ]

            InCycle cyclic ->
                div [ class "out out-error" ]
                    [ text ("Cyclic dependency: " ++ String.join " ↔ " cyclic) ]

            Stale ->
                case state.table of
                    Just t ->
                        div [ class "stale-wrap" ]
                            [ div [ class "out out-stale" ] [ text "Stale — showing the previous result, dimmed, until this re-runs." ]
                            , viewTable cell t
                            ]

                    Nothing ->
                        div [ class "out out-stale" ] [ text "Stale — not yet run." ]

            NeverRun ->
                div [ class "out out-idle" ] [ text "Not run yet." ]

            _ ->
                case state.table of
                    Just t ->
                        viewTable cell t

                    Nothing ->
                        div [ class "out out-idle" ] [ text "Running…" ]


viewTable : Cell -> Table -> Html Msg
viewTable cell t =
    div []
        [ div [ class "result-meta" ]
            [ text
                (String.fromInt t.rowCount
                    ++ " rows"
                    ++ (if t.truncated then
                            " (showing first " ++ String.fromInt (List.length t.rows) ++ ")"

                        else
                            ""
                       )
                )
            ]
        , div [ class "table-scroll" ]
            [ table []
                [ thead []
                    [ tr []
                        (t.columns
                            |> List.map
                                (\c ->
                                    th [ title c.sqlType ]
                                        [ text c.name
                                        , span [ class "coltype" ] [ text c.sqlType ]
                                        ]
                                )
                        )
                    ]
                , tbody []
                    (t.rows
                        |> List.map
                            (\row ->
                                tr []
                                    (t.columns
                                        |> List.map
                                            (\c -> td [] [ text (Query.cellText c.name row) ])
                                    )
                            )
                    )
                ]
            ]
        , viewTypedPanel cell t
        ]


{-| The Phase 2 payoff, and the only place `Spike.Orders` is used.

For one designated cell the same rows are also run through a hand-written
decoder into real Elm values — opaque id, custom `Status` type, `Time.Posix`
timestamp — to prove that the JS/Arrow boundary can be crossed into types
rather than into stringly-typed maps. The `orders` special case is a stand-in
for Phase 3, where the compiler emits one of these per query cell.

-}
viewTypedPanel : Cell -> Table -> Html Msg
viewTypedPanel cell t =
    if cell.id /= "orders" then
        text ""

    else
        let
            decoded =
                t.rows
                    |> List.take 5
                    |> List.map (D.decodeValue Orders.decoder)
        in
        div [ class "typed" ]
            [ h2 [] [ text "typed handoff · Spike.Orders.Order" ]
            , ol []
                (decoded
                    |> List.map
                        (\r ->
                            case r of
                                Ok order ->
                                    li [ class "typed-ok" ] [ text (describe order) ]

                                Err err ->
                                    li [ class "typed-err" ] [ text (D.errorToString err) ]
                        )
                )
            ]


describe : Orders.Order -> String
describe order =
    let
        (Orders.OrderId n) =
            order.id
    in
    "OrderId "
        ++ String.fromInt n
        ++ " · "
        ++ order.owner
        ++ " · "
        ++ Orders.statusLabel order.status
        ++ " · "
        ++ String.fromFloat order.total
