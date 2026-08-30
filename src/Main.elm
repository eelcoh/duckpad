module Main exposing (main)

{-| The notebook shell.

Query cells are written in the DSL and compiled in the browser, so nothing
here needs a daemon. Each edit walks the same path: parse for dependencies,
compile in topological order against the row types of the cells upstream, then
materialise in DuckDB only where a cached value cannot be reused.

-}

import Browser
import Browser.Dom
import Task
import Cell exposing (Cell, Kind(..), Status(..))
import Dag exposing (Graph)
import Dict exposing (Dict)
import Dsl.Ast exposing (Constructor, TypeDecl)
import Dsl.Check exposing (Cardinality(..))
import Dsl.Compile exposing (Compiled)
import Dsl.Schema as Schema exposing (Schema, Type(..))
import Dsl.Source
import Engine exposing (CellState, Shape)
import Html exposing (Html, button, details, div, input, p, pre, section, span, summary, table, tbody, td, text, textarea, th, thead, tr)
import Html.Attributes exposing (attribute, class, classList, disabled, id, placeholder, rows, spellcheck, title, value)
import Html.Events exposing (onBlur, onClick, onInput)
import Indent
import Json.Decode as D
import Notebook exposing (Notebook)
import Seed
import Ports
import Prose
import Query exposing (Outcome(..), Table)
import Set
import Time



-- MODEL


type alias Flags =
    { saved : Maybe String }


type alias Model =
    { title : String
    , cells : List Cell
    , states : Dict String CellState
    , baseSchema : Schema
    , queue : List String
    , current : Maybe String
    , db : DbStatus
    , nextId : Int
    , notice : Maybe String

    -- Reset discards unsaved work, so it takes two clicks: the first arms it
    -- and the second does it. Any other action disarms it again.
    , resetArmed : Bool

    -- Which prose cell is being edited, if any. Prose shows as rendered
    -- Markdown until it is clicked, which is the only way for a heading to
    -- look like a heading and still be editable in place.
    , editing : Maybe String
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
    | TitleEdited String
    | SaveFile
    | OpenFile
    | FileOpened D.Value
    | DismissNotice
    | ResetNotebook
    | EditProse String
    | KeyEdit String Indent.Edit
    | Focused (Result Browser.Dom.Error ())


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        ( notebook, notice ) =
            restore flags
    in
    ( load notebook { title = notebook.title, cells = [], states = Dict.empty, baseSchema = Dict.empty, queue = [], current = Nothing, db = Booting, nextId = 1, notice = notice, resetArmed = False, editing = Nothing }
    , Cmd.none
    )


{-| A buffer that no longer parses must not be swallowed: the notebook falls
back to the seeded one and says so, rather than silently discarding whatever
the reader had written.
-}
restore : Flags -> ( Notebook, Maybe String )
restore flags =
    case flags.saved of
        Nothing ->
            ( Seed.notebook, Nothing )

        Just text ->
            case Notebook.parse text of
                Ok notebook ->
                    ( notebook, Nothing )

                Err message ->
                    ( Seed.notebook, Just ("The saved notebook could not be read, so this is the starting one instead. " ++ message) )


load : Notebook -> Model -> Model
load notebook model =
    let
        cells =
            nameProse notebook.cells
    in
    { model
        | title = notebook.title
        , cells = cells
        , states = cells |> List.map (\c -> ( c.id, Engine.initialState )) |> Dict.fromList
        , queue = []
        , current = Nothing
    }


{-| Prose has no name in the file, but the model keys cell state by name, so
one is assigned on load. It is never written back out.
-}
nameProse : List Cell -> List Cell
nameProse cells =
    cells
        |> List.indexedMap
            (\i c ->
                if c.kind == Prose then
                    { c | id = "note_" ++ String.fromInt i }

                else
                    c
            )


toNotebook : Model -> Notebook
toNotebook model =
    { title = model.title, cells = model.cells }


-- GRAPH


{-| Dependencies come from parsing alone, which is what makes the ordering
possible: compiling a cell needs its inputs' row types, and those are only
known once the order exists.
-}
graphOf : Model -> Graph
graphOf model =
    model.cells
        |> List.filter (\c -> c.kind /= Prose)
        |> List.map
            (\c ->
                ( c.id
                , case c.kind of
                    Query ->
                        Set.fromList (Dsl.Compile.readsOf c.source)

                    _ ->
                        -- A source reads external data, never another cell.
                        Set.empty
                )
            )
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


domIdFor : String -> String
domIdFor id =
    "source-" ++ id


moduleNameFor : String -> String
moduleNameFor id =
    "Cell_" ++ String.toUpper (String.left 1 id) ++ String.dropLeft 1 id



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    step msg
        (case msg of
            ResetNotebook ->
                model

            _ ->
                { model | resetArmed = False }
        )


step : Msg -> Model -> ( Model, Cmd Msg )
step msg model =
    case msg of
        DbReady payload ->
            case D.decodeValue bootDecoder payload of
                Ok (Ok schema) ->
                    schedule { model | db = Ready, baseSchema = schema }

                Ok (Err err) ->
                    ( { model | db = DbFailed err }, Cmd.none )

                Err err ->
                    ( { model | db = DbFailed (D.errorToString err) }, Cmd.none )

        GotOutcome payload ->
            case D.decodeValue Query.outcomeDecoder payload of
                Ok outcome ->
                    applyOutcome outcome model

                Err err ->
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
                updated =
                    { model
                        | cells =
                            model.cells
                                |> List.map
                                    (\c ->
                                        if c.id == id then
                                            { c | source = newSource }

                                        else
                                            c
                                    )
                    }
            in
            -- Staleness propagates on every keystroke; compiling and running
            -- wait for the edit to be committed.
            withPersist
                ( { updated
                    | states = Engine.markStale (Set.singleton id) (graphOf updated) updated.states
                  }
                , Cmd.none
                )

        NameEdited id newName ->
            renameCell id (sanitiseName newName) model

        CommitEdit ->
            schedule { model | editing = Nothing }

        AddCell kind ->
            let
                fresh =
                    { id = freshName kind model
                    , kind = kind
                    , source =
                        case kind of
                            Query ->
                                "access orders ()\n  |> selectAll"

                            Source ->
                                "csv \"https://cdn.jsdelivr.net/npm/vega-datasets@2/data/seattle-weather.csv\""

                            Prose ->
                                "Notes."
                    }
            in
            withPersist
                ( { model
                    | cells = model.cells ++ [ fresh ]
                    , states = Dict.insert fresh.id Engine.initialState model.states
                    , nextId = model.nextId + 1
                  }
                , Cmd.none
                )

        DeleteCell id ->
            let
                updated =
                    { model
                        | cells = List.filter (\c -> c.id /= id) model.cells
                        , states = Dict.remove id model.states
                    }
            in
            withPersist
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
            schedule { model | states = invalidate model.states }

        TitleEdited title ->
            withPersist ( { model | title = title }, Cmd.none )

        SaveFile ->
            ( model
            , Ports.requestSave
                { name = fileNameFor model.title
                , content = Notebook.serialize (toNotebook model)
                }
            )

        OpenFile ->
            ( model, Ports.requestOpen () )

        FileOpened payload ->
            case D.decodeValue openedDecoder payload of
                Ok (Ok text) ->
                    case Notebook.parse text of
                        Ok notebook ->
                            let
                                loaded =
                                    load notebook { model | notice = Nothing }
                            in
                            withPersist (schedule loaded)

                        Err message ->
                            ( { model | notice = Just ("That file is not a notebook this can read. " ++ message) }
                            , Cmd.none
                            )

                Ok (Err message) ->
                    ( { model | notice = Just message }, Cmd.none )

                Err err ->
                    ( { model | notice = Just (D.errorToString err) }, Cmd.none )

        DismissNotice ->
            ( { model | notice = Nothing }, Cmd.none )

        KeyEdit id edit ->
            let
                ( updated, cmd ) =
                    step (SourceEdited id edit.text) model
            in
            ( updated
            , Cmd.batch [ cmd, Ports.setCaret { id = domIdFor id, pos = edit.caret } ]
            )

        EditProse id ->
            ( { model | editing = Just id }
            , Task.attempt Focused (Browser.Dom.focus (domIdFor id))
            )

        Focused _ ->
            -- Nothing to do either way: if the field could not be focused the
            -- reader can still click it.
            ( model, Cmd.none )

        ResetNotebook ->
            if model.resetArmed then
                withPersist (schedule (load Seed.notebook { model | notice = Nothing, resetArmed = False }))

            else
                ( { model | resetArmed = True }, Cmd.none )


{-| The bridge reports the tables it built, so the checker knows what
`access` may name before a single cell has run.
-}
withPersist : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
withPersist ( model, cmd ) =
    ( model
    , Cmd.batch [ cmd, Ports.persist (Notebook.serialize (toNotebook model)) ]
    )


fileNameFor : String -> String
fileNameFor title =
    (title
        |> String.toLower
        |> String.map
            (\c ->
                if Char.isAlphaNum c then
                    c

                else
                    '-'
            )
        |> String.foldr collapseDashes ""
        |> orDefault "notebook"
    )
        ++ ".acadia.md"


collapseDashes : Char -> String -> String
collapseDashes c acc =
    if c == '-' && String.startsWith "-" acc then
        acc

    else
        String.cons c acc


orDefault : String -> String -> String
orDefault fallback text =
    case String.trim (String.replace "-" " " text) of
        "" ->
            fallback

        _ ->
            text


openedDecoder : D.Decoder (Result String String)
openedDecoder =
    D.field "ok" D.bool
        |> D.andThen
            (\ok ->
                if ok then
                    D.map Ok (D.field "content" D.string)

                else
                    D.map Err (D.field "error" D.string)
            )


bootDecoder : D.Decoder (Result String Schema)
bootDecoder =
    D.field "ok" D.bool
        |> D.andThen
            (\ok ->
                if ok then
                    D.map Ok (D.field "schema" schemaDecoder)

                else
                    D.map Err (D.field "error" D.string)
            )


schemaDecoder : D.Decoder Schema
schemaDecoder =
    D.list tableDecoder |> D.map Dict.fromList


tableDecoder : D.Decoder ( String, List ( String, Type ) )
tableDecoder =
    D.map2 Tuple.pair
        (D.field "name" D.string)
        (D.field "columns" (D.list columnDecoder) |> D.map (List.filterMap identity))


{-| A column whose DuckDB type has no counterpart in the language is dropped
rather than guessed at. It simply will not be nameable from a cell.
-}
columnDecoder : D.Decoder (Maybe ( String, Type ))
columnDecoder =
    D.map3
        (\name rawType nullable ->
            Schema.fromDuckDb rawType
                |> Maybe.map
                    (\t ->
                        ( name
                        , if nullable then
                            TMaybe t

                          else
                            t
                        )
                    )
        )
        (D.field "name" D.string)
        (D.field "type" D.string)
        (D.field "nullable" D.bool)


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
                            |> Dict.insert new s

                    Nothing ->
                        model.states
        in
        withPersist
            ( { model | cells = cells, states = invalidate states }
            , Ports.dropTable old
            )


invalidate : Dict String CellState -> Dict String CellState
invalidate =
    Dict.map
        (\_ s ->
            { s | status = Stale, keyForValue = Nothing, compileKey = Nothing }
        )


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
                        case cell.kind of
                            Source ->
                                dispatchSource cell rest model

                            _ ->
                                dispatch cell rest model


{-| A source is not compiled and not materialised. It becomes a view over the
external data, and its identity is the location it points at rather than the
rows behind it — so re-running does not refetch, and changing the URI
invalidates everything downstream.
-}
dispatchSource : Cell -> List String -> Model -> ( Model, Cmd Msg )
dispatchSource cell rest model =
    case Dsl.Source.parse cell.source of
        Err message ->
            advance
                { model
                    | queue = rest
                    , states = setStatus cell.id (Invalid message) model.states
                }

        Ok spec ->
            let
                state =
                    stateOf cell.id model

                key =
                    Engine.valueKeyFor (graphOf model) model.states cell.id (Dsl.Source.formatName spec.format ++ " " ++ spec.uri)
            in
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
                , Ports.loadSource
                    { cellId = cell.id
                    , format = Dsl.Source.formatName spec.format
                    , uri = spec.uri
                    }
                )


{-| Compile, then decide whether the database has to be touched at all.

Both caches are consulted here: the compile cache can hand back a `Compiled`
without re-running the front end, and the value cache can then skip the query
entirely. Only a genuine miss reaches DuckDB.

-}
dispatch : Cell -> List String -> Model -> ( Model, Cmd Msg )
dispatch cell rest model =
    let
        graph =
            graphOf model

        state =
            stateOf cell.id model
    in
    case Engine.blockingUpstream graph model.states cell.id of
        Just upstream ->
            advance
                { model
                    | queue = rest
                    , states = setStatus cell.id (Blocked upstream) model.states
                }

        Nothing ->
            let
                compileKey =
                    Engine.compileKeyFor graph model.states cell

                compiled =
                    if state.compileKey == Just compileKey then
                        case state.compiled of
                            Just cached ->
                                Ok cached

                            Nothing ->
                                compileCell graph model cell

                    else
                        compileCell graph model cell
            in
            case compiled of
                Err message ->
                    advance
                        { model
                            | queue = rest
                            , states =
                                Dict.insert cell.id
                                    { state
                                        | status = Invalid message
                                        , compiled = Nothing
                                        , compileKey = Nothing
                                    }
                                    model.states
                        }

                Ok artefacts ->
                    runOrReuse cell rest model graph state compileKey artefacts


compileCell : Graph -> Model -> Cell -> Result String Compiled
compileCell graph model cell =
    Dsl.Compile.compile
        (Engine.schemaFor model.baseSchema graph model.states cell.id)
        (moduleNameFor cell.id)
        cell.source


runOrReuse : Cell -> List String -> Model -> Graph -> CellState -> String -> Compiled -> ( Model, Cmd Msg )
runOrReuse cell rest model graph state compileKey artefacts =
    let
        valueKey =
            Engine.valueKeyFor graph model.states cell.id artefacts.sql

        remembered =
            { state
                | compiled = Just artefacts
                , rowType = Just artefacts.rowType
                , compileKey = Just compileKey
            }
    in
    if state.keyForValue == Just valueKey && Engine.hasValue state then
        advance
            { model
                | queue = rest
                , states =
                    Dict.insert cell.id
                        { remembered
                            | status =
                                Fresh
                                    { cached = True
                                    , millis = state.table |> Maybe.map .millis |> Maybe.withDefault 0
                                    }
                        }
                        model.states
            }

    else
        ( { model
            | queue = rest
            , current = Just cell.id
            , states = Dict.insert cell.id { remembered | status = Running } model.states
          }
        , Ports.materialize
            { cellId = cell.id
            , sql = artefacts.sql

            -- Only a cell that asked for an order needs the stricter,
            -- order-sensitive content hash.
            , orderSignificant = artefacts.orderSignificant
            }
        )


applyOutcome : Outcome -> Model -> ( Model, Cmd Msg )
applyOutcome outcome model =
    case outcome of
        Success id result ->
            let
                state =
                    stateOf id model

                isSource =
                    findCell id model |> Maybe.map (\c -> c.kind == Source) |> Maybe.withDefault False

                valueKey =
                    if isSource then
                        findCell id model
                            |> Maybe.andThen (\c -> Dsl.Source.parse c.source |> Result.toMaybe)
                            |> Maybe.map
                                (\spec ->
                                    Engine.valueKeyFor (graphOf model) model.states id
                                        (Dsl.Source.formatName spec.format ++ " " ++ spec.uri)
                                )

                    else
                        state.compiled
                            |> Maybe.map
                                (\c -> Engine.valueKeyFor (graphOf model) model.states id c.sql)

                rowType =
                    if isSource then
                        Just (fromDescribed result.described)

                    else
                        state.compiled |> Maybe.map .rowType
            in
            advance
                { model
                    | current = Nothing
                    , states =
                        Dict.insert id
                            { state
                                | status = Fresh { cached = False, millis = result.millis }
                                , table = Just result
                                , rowType = rowType
                                , valueHash = Just result.hash
                                , keyForValue = valueKey
                            }
                            model.states
                }

        Failure id err ->
            advance
                { model
                    | current = Nothing
                    , states = setStatus id (Failed err) model.states
                }


{-| A column whose DuckDB type has no counterpart in the language is dropped
rather than guessed at. It simply will not be nameable from a cell.
-}
fromDescribed : List Query.Described -> List ( String, Type )
fromDescribed described =
    described
        |> List.filterMap
            (\c ->
                Schema.fromDuckDb c.sqlType
                    |> Maybe.map
                        (\t ->
                            ( c.name
                            , if c.nullable then
                                TMaybe t

                              else
                                t
                            )
                        )
            )


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

                Source ->
                    "data_"

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
        , Ports.fileOpened FileOpened
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
        , viewNotice model.notice
        , div [ class "cells" ] (List.map (viewCell model graph) model.cells)
        , div [ class "add-row" ]
            [ button [ onClick (AddCell Source) ] [ text "+ source" ]
            , button [ onClick (AddCell Query) ] [ text "+ query cell" ]
            , button [ onClick (AddCell Prose) ] [ text "+ prose cell" ]
            ]
        ]


viewHeader : Model -> Graph -> Html Msg
viewHeader model graph =
    div [ class "topbar" ]
        [ div []
            [ input
                [ class "notebook-title"
                , value model.title
                , onInput TitleEdited
                , placeholder "Untitled notebook"
                ]
                []
            , p [ class "sub" ] [ text "reactive graph · DSL compiled in-browser · DuckDB-wasm" ]
            ]
        , div [ class "topbar-right" ]
            [ viewExecutionOrder graph
            , viewDbStatus model.db
            , button
                [ onClick ResetNotebook
                , classList [ ( "armed", model.resetArmed ) ]
                , title "Replace this notebook with the one it starts from"
                ]
                [ text
                    (if model.resetArmed then
                        "Discard and reset?"

                     else
                        "Reset"
                    )
                ]
            , button [ onClick OpenFile, title "Open a notebook file" ] [ text "Open" ]
            , button [ onClick SaveFile, title "Save this notebook as Markdown" ] [ text "Save" ]
            , button
                [ onClick RunAll
                , disabled (model.db /= Ready)
                , title "Discard every cached value and re-run the whole graph"
                ]
                [ text "Run all" ]
            ]
        ]


viewNotice : Maybe String -> Html Msg
viewNotice notice =
    case notice of
        Nothing ->
            text ""

        Just message ->
            div [ class "notice" ]
                [ span [] [ text message ]
                , button [ class "danger", onClick DismissNotice ] [ text "×" ]
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
            [ -- Prose has no name in the file, so it is not offered one here.
              if cell.kind == Prose then
                text ""

              else
                input
                    [ class "cell-name"
                    , value cell.id
                    , onInput (NameEdited cell.id)
                    , onBlur CommitEdit
                    ]
                    []
            , span [ class "kind" ] [ text (Cell.kindLabel cell.kind) ]
            , viewStatus cell state.status
            , viewSignature state
            , span [ class "spacer" ] []
            , viewEdges graph cell
            , button [ class "danger", onClick (DeleteCell cell.id) ] [ text "×" ]
            ]
        , viewBody model cell
        , viewOutput cell state
        , viewArtefacts state
        ]


{-| The compiler's view of the cell: what it evaluates to, and in what shape.
-}
viewSignature : CellState -> Html Msg
viewSignature state =
    case state.compiled of
        Nothing ->
            text ""

        Just compiled ->
            let
                shape =
                    case compiled.cardinality of
                        One ->
                            "Maybe Row"

                        Many ->
                            "List Row"
            in
            span [ class "signature", title (describeRow compiled.rowType) ]
                [ text (": " ++ shape) ]


describeRow : List ( String, Type ) -> String
describeRow row =
    row
        |> List.map (\( name, t ) -> name ++ " : " ++ Schema.typeName t)
        |> String.join "\n"


viewBody : Model -> Cell -> Html Msg
viewBody model cell =
    if cell.kind == Prose && model.editing /= Just cell.id then
        div
            [ class "prose-body"
            , onClick (EditProse cell.id)
            , title "Click to edit"
            ]
            [ if String.trim cell.source == "" then
                span [ class "prose-empty" ] [ text "Notes…" ]

              else
                Prose.view cell.source
            ]

    else
        textarea
            [ class "cell-source"
            , id (domIdFor cell.id)

            -- Browsers spell-check a textarea by default, which underlines
            -- source in red as though it were an error. The mobile
            -- attributes go with it: autocorrect happily rewrites code.
            , spellcheck (cell.kind == Prose)
            , attribute "autocorrect" "off"
            , attribute "autocapitalize" "off"
            , attribute "autocomplete" "off"
            , value cell.source
            , rows (max 3 (List.length (String.lines cell.source)))
            , placeholder
                (case cell.kind of
                    Query ->
                        "access orders () |> selectAll"

                    Source ->
                        "csv \"https://…\""

                    Prose ->
                        "Notes…"
                )
            , onInput (SourceEdited cell.id)
            , onBlur CommitEdit
            , onKeyDown cell.id
            ]
            []


{-| Enter and Tab, handled here rather than left to the browser.

A textarea's own Enter goes to column zero, which loses the indentation on
every line of a pipeline, and its own Tab leaves the field entirely. Both are
intercepted; every other key falls through untouched, because the decoder
fails and a failed decoder neither dispatches nor prevents the default.

-}
onKeyDown : String -> Html.Attribute Msg
onKeyDown cellId =
    Html.Events.custom "keydown" (D.andThen (keyEdit cellId) keyContext)


type alias KeyContext =
    { key : String
    , shift : Bool
    , value : String
    , start : Int
    , end : Int
    }


keyContext : D.Decoder KeyContext
keyContext =
    D.map5 KeyContext
        (D.field "key" D.string)
        (D.field "shiftKey" D.bool)
        (D.at [ "target", "value" ] D.string)
        (D.at [ "target", "selectionStart" ] D.int)
        (D.at [ "target", "selectionEnd" ] D.int)


keyEdit : String -> KeyContext -> D.Decoder { message : Msg, stopPropagation : Bool, preventDefault : Bool }
keyEdit cellId ctx =
    let
        handled edit =
            D.succeed
                { message = KeyEdit cellId edit
                , stopPropagation = False
                , preventDefault = True
                }
    in
    case ( ctx.key, ctx.shift ) of
        ( "Enter", False ) ->
            handled (Indent.enter ctx.value ctx.start ctx.end)

        ( "Tab", False ) ->
            handled (Indent.tab ctx.value ctx.start ctx.end)

        ( "Tab", True ) ->
            handled (Indent.shiftTab ctx.value ctx.start ctx.end)

        _ ->
            D.fail "not an editing key"


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
                    , if cached then
                        "cached"

                      else
                        "fresh · " ++ String.fromInt (round millis) ++ "ms"
                    )

                Running ->
                    ( "pill-running", "running" )

                Stale ->
                    ( "pill-stale", "stale" )

                Failed _ ->
                    ( "pill-failed", "query failed" )

                Invalid _ ->
                    ( "pill-failed", "does not compile" )

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
            Invalid message ->
                div [ class "out out-error" ] [ text message ]

            Failed err ->
                div [ class "out out-error" ] [ text err ]

            Blocked upstream ->
                div [ class "out out-blocked" ]
                    [ text ("Not run: upstream cell `" ++ upstream ++ "` has no usable value.") ]

            InCycle cyclic ->
                div [ class "out out-error" ]
                    [ text ("Cyclic dependency: " ++ String.join " ↔ " cyclic) ]

            Stale ->
                case ( state.table, Engine.display state ) of
                    ( Just t, Just shape ) ->
                        div [ class "stale-wrap" ]
                            [ div [ class "out out-stale" ] [ text "Stale — showing the previous result until this re-runs." ]
                            , viewTable shape t
                            ]

                    _ ->
                        div [ class "out out-stale" ] [ text "Stale — not yet run." ]

            NeverRun ->
                div [ class "out out-idle" ] [ text "Not run yet." ]

            _ ->
                case ( state.table, Engine.display state ) of
                    ( Just t, Just shape ) ->
                        viewTable shape t

                    _ ->
                        div [ class "out out-idle" ] [ text "Running…" ]


viewTable : Shape -> Table -> Html Msg
viewTable shape t =
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
                    ++ (if shape.ordered then
                            " · ordered"

                        else
                            ""
                       )
                )
            ]
        , div [ class "table-scroll" ]
            [ table []
                [ thead []
                    [ tr []
                        (shape.rowType
                            |> List.map
                                (\( name, columnType ) ->
                                    th []
                                        [ text name
                                        , span [ class "coltype" ] [ text (Schema.typeName columnType) ]
                                        ]
                                )
                        )
                    ]
                , tbody []
                    (t.rows
                        |> List.map
                            (\row ->
                                tr []
                                    (shape.rowType
                                        |> List.map
                                            (\( name, columnType ) ->
                                                td [] [ text (renderValue shape.declarations columnType name row) ]
                                            )
                                    )
                            )
                    )
                ]
            ]
        ]


renderValue : List TypeDecl -> Type -> String -> D.Value -> String
renderValue decls columnType column row =
    case columnType of
        TMaybe inner ->
            if isNull column row then
                "—"

            else
                renderValue decls inner column row

        TTimestamp ->
            decodeField column D.float row
                |> Maybe.map (formatDate << Time.millisToPosix << round)
                |> Maybe.withDefault "?"

        TCustom name ->
            decodeField column D.string row
                |> Maybe.map (renderConstructor decls name row)
                |> Maybe.withDefault "?"

        _ ->
            Query.cellText column row


{-| Show the constructor the tag stands for, and its payload where it has one.
This is the same reconstruction the generated decoder performs; doing it here
means the table proves the mapping without the generated module having to be
compiled and loaded first.
-}
renderConstructor : List TypeDecl -> String -> D.Value -> String -> String
renderConstructor decls typeName row tag =
    let
        found =
            decls
                |> List.filter (\d -> d.name == typeName)
                |> List.concatMap .constructors
                |> List.filter (\c -> c.tag == tag)
                |> List.head
    in
    case found of
        Nothing ->
            "?" ++ tag

        Just ctor ->
            case ctor.payloadColumn of
                Nothing ->
                    ctor.name

                Just payload ->
                    decodeField payload D.float row
                        |> Maybe.map (\ms -> ctor.name ++ " " ++ formatDate (Time.millisToPosix (round ms)))
                        |> Maybe.withDefault ctor.name


decodeField : String -> D.Decoder a -> D.Value -> Maybe a
decodeField column decoder row =
    D.decodeValue (D.field column decoder) row |> Result.toMaybe


isNull : String -> D.Value -> Bool
isNull column row =
    D.decodeValue (D.field column (D.null True)) row |> Result.withDefault False


formatDate : Time.Posix -> String
formatDate posix =
    let
        pad n =
            String.padLeft 2 '0' (String.fromInt n)
    in
    String.fromInt (Time.toYear Time.utc posix)
        ++ "-"
        ++ pad (monthNumber (Time.toMonth Time.utc posix))
        ++ "-"
        ++ pad (Time.toDay Time.utc posix)


monthNumber : Time.Month -> Int
monthNumber month =
    case month of
        Time.Jan ->
            1

        Time.Feb ->
            2

        Time.Mar ->
            3

        Time.Apr ->
            4

        Time.May ->
            5

        Time.Jun ->
            6

        Time.Jul ->
            7

        Time.Aug ->
            8

        Time.Sep ->
            9

        Time.Oct ->
            10

        Time.Nov ->
            11

        Time.Dec ->
            12


{-| Both artefacts, side by side. They are two renderings of one checked
description, and showing them together is the clearest way to make that
visible — and the Elm module is what a hand-written Elm cell will import once
there is a daemon to compile one.
-}
viewArtefacts : CellState -> Html Msg
viewArtefacts state =
    case state.compiled of
        Nothing ->
            text ""

        Just compiled ->
            details [ class "artefacts" ]
                [ summary [] [ text "generated" ]
                , div [ class "artefact-pair" ]
                    [ div [ class "artefact" ]
                        [ div [ class "artefact-label" ] [ text "SQL" ]
                        , pre [] [ text compiled.sql ]
                        ]
                    , div [ class "artefact" ]
                        [ div [ class "artefact-label" ] [ text (moduleNameFor "…" ++ " — Elm") ]
                        , pre [] [ text compiled.elmModule ]
                        ]
                    ]
                ]
