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
import Dsl.Ast exposing (Constructor, Definition(..), Literal(..), TypeDecl)
import Chart
import Dsl.Check exposing (Cardinality(..), Display(..))
import Dsl.Compile exposing (Compiled)
import Dsl.Lexer
import Dsl.Schema as Schema exposing (Schema, Type(..))
import Dsl.Input
import Dsl.Source
import Engine exposing (CellState, Shape)
import Element exposing (Element, alignRight, centerX, centerY, column, el, fill, height, maximum, padding, paddingXY, px, row, spacing, text, width)
import Element.Background as Background
import Element.Border as Border
import Element.Events
import Element.Font as Font
import Element.Input as Input
import Html exposing (Html, div, input, pre, span, table, tbody, td, textarea, th, thead, tr)
import Html.Attributes exposing (attribute, class, id, placeholder, rows, spellcheck, value)
import Html.Attributes
import Html.Events exposing (onBlur, onInput)
import Ui
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

    -- Which cells have their generated SQL and Elm on show. elm-ui has no
    -- `details`, and holding it here means the disclosure survives a re-render
    -- rather than being the browser's private business.
    , expanded : Set.Set String

    -- Where each input cell currently sits. The cell's source gives the
    -- control and its default; this is what the reader has moved it to.
    , inputs : Dict String Literal
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
    | ExportNotebook
    | EditProse String
    | KeyEdit String Indent.Edit
    | ToggleArtefacts String
    | InputMoved String Literal
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
    ( load notebook { title = notebook.title, cells = [], states = Dict.empty, baseSchema = Dict.empty, queue = [], current = Nothing, db = Booting, nextId = 1, notice = notice, resetArmed = False, editing = Nothing, expanded = Set.empty, inputs = Dict.empty }
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
                        -- A source reads external data and an input reads
                        -- nothing at all; neither depends on another cell.
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


previewRows : Int
previewRows =
    200


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

                            Input ->
                                "range 0 100 default 50"

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

        InputMoved id literal ->
            let
                updated =
                    { model | inputs = Dict.insert id literal model.inputs }
            in
            withPersist
                (schedule
                    { updated
                        | states = Engine.markStale (Set.singleton id) (graphOf updated) updated.states
                    }
                )

        ToggleArtefacts id ->
            ( { model
                | expanded =
                    if Set.member id model.expanded then
                        Set.remove id model.expanded

                    else
                        Set.insert id model.expanded
              }
            , Cmd.none
            )

        EditProse id ->
            ( { model | editing = Just id }
            , Task.attempt Focused (Browser.Dom.focus (domIdFor id))
            )

        Focused _ ->
            -- Nothing to do either way: if the field could not be focused the
            -- reader can still click it.
            ( model, Cmd.none )

        ExportNotebook ->
            -- Any prose being edited is a textarea rather than rendered
            -- Markdown, and a snapshot would catch it mid-edit.
            ( { model | editing = Nothing }
            , Ports.exportStatic (fileNameFor model.title |> String.replace ".acadia.md" ".html")
            )

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

                            Input ->
                                dispatchInput cell rest model

                            _ ->
                                dispatch cell rest model


{-| An input resolves without touching the database: its value is already
known, and settling it here is what lets the cells downstream compile.
-}
dispatchInput : Cell -> List String -> Model -> ( Model, Cmd Msg )
dispatchInput cell rest model =
    let
        state =
            stateOf cell.id model
    in
    case Dsl.Input.parse cell.source of
        Err message ->
            advance
                { model
                    | queue = rest
                    , states = setStatus cell.id (Invalid message) model.states
                }

        Ok widget ->
            advance
                { model
                    | queue = rest
                    , states =
                        Dict.insert cell.id
                            { state
                                | status = Fresh { cached = False, millis = 0 }
                                , valueHash = Just (literalKey (valueOf cell.id widget model))
                            }
                            model.states
                }


{-| What identifies a source: where it points and how it is read. An option
changes the data as surely as the URI does.
-}
sourceKey : Dsl.Source.Spec -> String
sourceKey spec =
    Dsl.Source.formatName spec.format ++ " " ++ spec.uri ++ Dsl.Source.readerOptions spec


valueOf : String -> Dsl.Input.Spec -> Model -> Literal
valueOf id widget model =
    Dict.get id model.inputs |> Maybe.withDefault (Dsl.Input.defaultLiteral widget)


literalKey : Literal -> String
literalKey literal =
    case literal of
        LFloat f ->
            String.fromFloat f

        LInt n ->
            String.fromInt n

        LString s ->
            "s:" ++ s

        LTimestamp iso ->
            "t:" ++ iso

        LBool b ->
            if b then
                "true"

            else
                "false"


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
                    Engine.valueKeyFor (graphOf model) model.states cell.id (sourceKey spec)
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
                    , options = Dsl.Source.readerOptions spec
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
        (paramsFor graph model cell.id)
        (moduleNameFor cell.id)
        cell.source


{-| The input values a cell may read: those bound by the inputs it depends on,
and no others, for the same reason a cell cannot name a table it never
declared it reads.
-}
paramsFor : Graph -> Model -> String -> Dsl.Check.Params
paramsFor graph model id =
    Dag.dependenciesOf id graph
        |> Set.foldl
            (\dep acc ->
                case findCell dep model of
                    Just upstream ->
                        if upstream.kind == Input then
                            case Dsl.Input.parse upstream.source of
                                Ok widget ->
                                    Dict.insert dep
                                        ( Dsl.Input.valueType widget, valueOf dep widget model )
                                        acc

                                Err _ ->
                                    acc

                        else
                            acc

                    Nothing ->
                        acc
            )
            Dict.empty


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

            -- A chart of the first two hundred points of a series is a
            -- misleading picture rather than a partial one, so it asks for
            -- more than a table would.
            , rowLimit =
                case artefacts.display of
                    AsChart _ ->
                        Chart.rowLimit

                    _ ->
                        previewRows
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
                                    Engine.valueKeyFor (graphOf model) model.states id (sourceKey spec)
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

                Input ->
                    "input_"

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
    Element.layout
        [ Background.color Ui.bg
        , Font.family Ui.sans
        , Font.size 14
        , Font.color Ui.ink
        ]
        (column
            [ width (fill |> maximum 1040)
            , centerX
            , paddingXY 20 24
            , spacing 16
            ]
            (viewHeader model graph
                :: viewNotice model.notice
                ++ List.map (viewCell model graph) model.cells
                ++ [ viewAddRow ]
            )
        )



-- CHROME


viewHeader : Model -> Graph -> Element Msg
viewHeader model graph =
    column [ width fill, spacing 14 ]
        [ Element.wrappedRow [ width fill, spacing 20 ]
            [ column [ spacing 4, width fill ]
                [ titleField model.title
                , el [ Font.size 12, Font.color Ui.muted ]
                    (text "reactive graph · DSL compiled in-browser · DuckDB-wasm")
                ]
            , Element.wrappedRow [ alignRight, spacing 10, Ui.dropOnExport ]
                [ viewExecutionOrder graph
                , viewDbStatus model.db
                , plainButton "Reset" model.resetArmed (Just ResetNotebook)
                , plainButton "Open" False (Just OpenFile)
                , plainButton "Save" False (Just SaveFile)
                , plainButton "Export" False (Just ExportNotebook)
                , plainButton "Run all"
                    False
                    (if model.db == Ready then
                        Just RunAll

                     else
                        Nothing
                    )
                ]
            ]
        , el [ width fill, height (px 1), Background.color Ui.line ] Element.none
        ]


titleField : String -> Element Msg
titleField current =
    Input.text
        [ Font.size 18
        , Font.semiBold
        , Border.width 1
        , Border.color Ui.bg
        , Border.rounded 4
        , Background.color Ui.bg
        , paddingXY 6 2
        , width (px 260)
        , Element.focused [ Border.color Ui.line, Background.color Ui.card ]
        , Element.mouseOver [ Border.color Ui.line ]
        ]
        { onChange = TitleEdited
        , text = current
        , placeholder = Just (Input.placeholder [] (text "Untitled notebook"))
        , label = Input.labelHidden "Notebook title"
        }


{-| Reset is the only button with two states, so armedness is a parameter
rather than a separate constructor.
-}
plainButton : String -> Bool -> Maybe Msg -> Element Msg
plainButton label armed onPress =
    let
        colour =
            if armed then
                Ui.bad

            else if onPress == Nothing then
                Ui.muted

            else
                Ui.ink
    in
    Input.button
        [ Font.size 12
        , Font.color colour
        , Border.width 1
        , Border.color
            (if armed then
                Ui.bad

             else
                Ui.line
            )
        , Border.rounded 5
        , Background.color
            (if armed then
                Element.rgb255 0xFF 0xF6 0xF5

             else
                Ui.card
            )
        , paddingXY 12 6
        , Element.alpha
            (if onPress == Nothing then
                0.45

             else
                1
            )
        , Element.mouseOver
            (if onPress == Nothing then
                []

             else
                [ Border.color Ui.accent, Font.color Ui.accent ]
            )
        ]
        { onPress = onPress
        , label =
            text
                (if armed then
                    "Discard and reset?"

                 else
                    label
                )
        }


viewNotice : Maybe String -> List (Element Msg)
viewNotice notice =
    case notice of
        Nothing ->
            []

        Just message ->
            [ row
                [ width fill
                , spacing 12
                , padding 10
                , Font.size 12
                , Font.color Ui.stale
                , Background.color (Element.rgb255 0xFF 0xFB 0xF0)
                , Border.width 1
                , Border.color (Element.rgb255 0xF0 0xE0 0xB8)
                , Border.rounded 6
                ]
                [ Element.paragraph [ width fill ] [ text message ]
                , Input.button [ alignRight, Font.color Ui.muted, Font.size 16, Ui.dropOnExport ]
                    { onPress = Just DismissNotice, label = text "×" }
                ]
            ]


viewDbStatus : DbStatus -> Element Msg
viewDbStatus db =
    case db of
        Booting ->
            Ui.pill Ui.accent "duckdb booting…"

        Ready ->
            Ui.pill Ui.good "duckdb ready"

        DbFailed _ ->
            Ui.pill Ui.bad "duckdb failed"


viewExecutionOrder : Graph -> Element Msg
viewExecutionOrder graph =
    case Dag.topoSort graph of
        Ok order ->
            column [ spacing 2 ]
                [ Ui.tinyCaps Ui.muted "execution order"
                , el [ Font.family Ui.mono, Font.size 11, Font.color Ui.muted ]
                    (text (String.join " → " order))
                ]

        Err cyclic ->
            el [ Font.family Ui.mono, Font.size 11, Font.color Ui.bad ]
                (text ("cycle: " ++ String.join " ↔ " cyclic))


viewAddRow : Element Msg
viewAddRow =
    row [ spacing 8, Ui.dropOnExport ]
        [ plainButton "+ source" False (Just (AddCell Source))
        , plainButton "+ query cell" False (Just (AddCell Query))
        , plainButton "+ prose cell" False (Just (AddCell Prose))
        ]



-- CELLS


viewCell : Model -> Graph -> Cell -> Element Msg
viewCell model graph cell =
    let
        state =
            stateOf cell.id model

        prose =
            cell.kind == Prose
    in
    column
        [ width fill
        , Background.color
            (if prose then
                Ui.bg

             else
                Ui.card
            )
        , Border.width 1
        , Border.color Ui.line
        , Border.rounded 8
        , if prose then
            Border.dashed

          else
            Border.solid
        ]
        [ viewCellHead model graph cell state
        , el [ width fill ] (Element.html (viewBody model cell))
        , viewOutput model cell state
        , viewArtefacts model cell state
        ]


viewCellHead : Model -> Graph -> Cell -> CellState -> Element Msg
viewCellHead model graph cell state =
    Element.wrappedRow
        [ width fill
        , spacing 10
        , paddingXY 12 8
        , Border.widthEach { top = 0, left = 0, right = 0, bottom = 1 }
        , Border.color
            (if cell.kind == Prose then
                Ui.bg

             else
                Ui.line
            )
        ]
        ([ if cell.kind == Prose then
            Element.none

           else
            nameField cell
         , Ui.tinyCaps Ui.muted (Cell.kindLabel cell.kind)
         ]
            ++ viewStatus cell state.status
            ++ viewSignature state
            ++ [ el [ width fill ] Element.none
               , viewEdges graph cell
               , Input.button [ Font.color Ui.muted, Font.size 16, alignRight, Ui.dropOnExport ]
                    { onPress = Just (DeleteCell cell.id), label = text "×" }
               ]
        )


nameField : Cell -> Element Msg
nameField cell =
    Input.text
        [ Font.family Ui.mono
        , Font.size 13
        , Font.semiBold
        , Font.color Ui.accent
        , Border.width 1
        , Border.color Ui.card
        , Border.rounded 4
        , Background.color Ui.card
        , paddingXY 6 3
        , width (px 130)
        , Element.focused [ Border.color Ui.line, Background.color Ui.bg ]
        , Element.mouseOver [ Border.color Ui.line ]
        , Element.htmlAttribute (Html.Events.onBlur CommitEdit)
        ]
        { onChange = NameEdited cell.id
        , text = cell.id
        , placeholder = Nothing
        , label = Input.labelHidden "Cell name"
        }


viewStatus : Cell -> Status -> List (Element Msg)
viewStatus cell status =
    if cell.kind == Prose then
        []

    else
        case status of
            Fresh { cached, millis } ->
                if cached then
                    [ Ui.pill Ui.accent "cached" ]

                else
                    [ Ui.pill Ui.good ("fresh · " ++ String.fromInt (round millis) ++ "ms") ]

            Running ->
                [ Ui.pill Ui.accent "running" ]

            Stale ->
                [ Ui.pill Ui.stale "stale" ]

            Failed _ ->
                [ Ui.pill Ui.bad "query failed" ]

            Invalid _ ->
                [ Ui.pill Ui.bad "does not compile" ]

            Blocked upstream ->
                [ Ui.pill Ui.bad ("blocked by " ++ upstream) ]

            InCycle _ ->
                [ Ui.pill Ui.bad "cycle" ]

            NeverRun ->
                [ Ui.pill Ui.muted "never run" ]

            Queued ->
                [ Ui.pill Ui.muted "queued" ]


viewSignature : CellState -> List (Element Msg)
viewSignature state =
    case state.compiled of
        Nothing ->
            []

        Just compiled ->
            [ el
                [ Font.family Ui.mono
                , Font.size 11
                , Font.color Ui.muted
                , Element.htmlAttribute (Html.Attributes.title (describeRow compiled.rowType))
                ]
                (text
                    (": "
                        ++ (case compiled.cardinality of
                                One ->
                                    "Maybe Row"

                                Many ->
                                    "List Row"
                           )
                    )
                )
            ]


describeRow : List ( String, Type ) -> String
describeRow rowType =
    rowType
        |> List.map (\( name, t ) -> name ++ " : " ++ Schema.typeName t)
        |> String.join "\n"


viewEdges : Graph -> Cell -> Element Msg
viewEdges graph cell =
    let
        part label items =
            if List.isEmpty items then
                []

            else
                [ row [ spacing 4 ]
                    [ Ui.tinyCaps Ui.muted label
                    , el [ Font.family Ui.mono, Font.size 11, Font.color Ui.muted ]
                        (text (String.join ", " items))
                    ]
                ]
    in
    row [ spacing 12 ]
        (part "reads" (Set.toList (Dag.dependenciesOf cell.id graph))
            ++ part "feeds" (Set.toList (Dag.dependentsOf cell.id graph))
        )



-- THE EDITING SURFACE
--
-- Raw HTML from here down, and deliberately. The coloured layer and the
-- textarea over it have to agree on exact text metrics, which is the one thing
-- elm-ui is built to take away from you.


viewBody : Model -> Cell -> Html Msg
viewBody model cell =
    if cell.kind == Prose && model.editing /= Just cell.id then
        div
            [ class "prose-body"
            , Html.Events.onClick (EditProse cell.id)
            , Html.Attributes.title "Click to edit"
            ]
            [ if String.trim cell.source == "" then
                span [ class "prose-empty" ] [ Html.text "Notes…" ]

              else
                Prose.view cell.source
            ]

    else if cell.kind == Prose then
        editor cell

    else
        div [ class "editor" ]
            [ pre
                [ class "highlight", attribute "aria-hidden" "true" ]
                (List.map viewToken (Dsl.Lexer.tokenize cell.source)
                    -- A zero-width space guarantees a final line box, so the
                    -- two layers agree on their height whether or not the
                    -- source ends in a newline.
                    ++ [ Html.text "\u{200B}" ]
                )
            , editor cell
            ]


viewToken : Dsl.Lexer.Token -> Html Msg
viewToken token =
    span [ class (Dsl.Lexer.className token.kind) ] [ Html.text token.text ]


editor : Cell -> Html Msg
editor cell =
    textarea
        [ class "cell-source"
        , id (domIdFor cell.id)

        -- Browsers spell-check a textarea by default, which underlines source
        -- in red as though it were an error. On prose that is wanted; on code
        -- it is not. The mobile attributes go with it: autocorrect happily
        -- rewrites code.
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

                Input ->
                    "range 0 100 default 50"

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



-- OUTPUT


viewOutput : Model -> Cell -> CellState -> Element Msg
viewOutput model cell state =
    if cell.kind == Prose then
        Element.none

    else if cell.kind == Input then
        case Dsl.Input.parse cell.source of
            Err message ->
                message_ Ui.bad message

            Ok widget ->
                viewControl cell.id widget (valueOf cell.id widget model)

    else
        case state.status of
            Invalid message ->
                message_ Ui.bad message

            Failed err ->
                message_ Ui.bad err

            Blocked upstream ->
                message_ Ui.bad ("Not run: upstream cell `" ++ upstream ++ "` has no usable value.")

            InCycle cyclic ->
                message_ Ui.bad ("Cyclic dependency: " ++ String.join " ↔ " cyclic)

            Stale ->
                case ( state.table, Engine.display state ) of
                    ( Just t, Just shape ) ->
                        column [ width fill ]
                            [ message_ Ui.stale "Stale — showing the previous result until this re-runs."
                            , el [ width fill, Element.alpha 0.45 ] (Element.html (viewTable shape t))
                            ]

                    _ ->
                        message_ Ui.stale "Stale — not yet run."

            NeverRun ->
                message_ Ui.muted "Not run yet."

            _ ->
                case ( state.table, Engine.display state ) of
                    ( Just t, Just shape ) ->
                        el [ width fill ] (Element.html (viewTable shape t))

                    _ ->
                        message_ Ui.muted "Running…"


{-| The control itself. An input's value is the cell's whole output, so this
sits where a table would.
-}
viewControl : String -> Dsl.Input.Spec -> Literal -> Element Msg
viewControl id widget current =
    el
        [ width fill
        , padding 12
        , Border.widthEach { top = 1, left = 0, right = 0, bottom = 0 }
        , Border.color Ui.line
        ]
        (case ( widget, current ) of
            ( Dsl.Input.Range r, LFloat value ) ->
                row [ width fill, spacing 14 ]
                    [ Input.slider
                        [ width fill
                        , height (px 20)
                        , Element.behindContent
                            (el
                                [ width fill
                                , height (px 3)
                                , centerY
                                , Background.color Ui.line
                                , Border.rounded 2
                                ]
                                Element.none
                            )
                        ]
                        { onChange = \f -> InputMoved id (LFloat f)
                        , label = Input.labelHidden id
                        , min = r.min
                        , max = r.max
                        , step = Just r.step
                        , value = value
                        , thumb = Input.thumb [ width (px 14), height (px 14), Border.rounded 7, Background.color Ui.accent ]
                        }
                    , el
                        [ Font.family Ui.mono
                        , Font.size Ui.monoSize
                        , Font.color Ui.accent
                        , width (px 90)
                        , Font.alignRight
                        ]
                        (text (trimFloat value))
                    ]

            ( Dsl.Input.Select s, LString value ) ->
                Element.wrappedRow [ spacing 6 ]
                    (List.map (viewOption id value) s.options)

            ( Dsl.Input.Date d, LTimestamp value ) ->
                -- The browser's own date field: elm-ui has no equivalent, and
                -- a hand-rolled one would be worse than the native picker.
                el [ Font.family Ui.mono, Font.size Ui.monoSize ]
                    (Element.html
                        (Html.input
                            [ Html.Attributes.type_ "date"
                            , Html.Attributes.class "date-input"
                            , Html.Attributes.min d.min
                            , Html.Attributes.max d.max
                            , Html.Attributes.value value
                            , Html.Events.onInput (\iso -> InputMoved id (LTimestamp iso))
                            ]
                            []
                        )
                    )

            _ ->
                message_ Ui.bad "this control does not match its value"
        )


viewOption : String -> String -> String -> Element Msg
viewOption id current option =
    let
        chosen =
            option == current
    in
    Input.button
        [ Font.family Ui.mono
        , Font.size Ui.monoSize
        , Font.color
            (if chosen then
                Ui.card

             else
                Ui.ink
            )
        , Background.color
            (if chosen then
                Ui.accent

             else
                Ui.card
            )
        , Border.width 1
        , Border.color
            (if chosen then
                Ui.accent

             else
                Ui.line
            )
        , Border.rounded 5
        , paddingXY 10 5
        ]
        { onPress = Just (InputMoved id (LString option)), label = text option }


{-| Sliders produce values like 249.99999999999997; the control should not.
-}
trimFloat : Float -> String
trimFloat value =
    let
        rounded =
            toFloat (round (value * 100)) / 100
    in
    if rounded == toFloat (round rounded) then
        String.fromInt (round rounded)

    else
        String.fromFloat rounded


message_ : Element.Color -> String -> Element Msg
message_ colour body =
    Element.paragraph
        [ width fill
        , padding 12
        , Font.family Ui.mono
        , Font.size Ui.monoSize
        , Font.color colour
        , Border.widthEach { top = 1, left = 0, right = 0, bottom = 0 }
        , Border.color Ui.line
        , Background.color
            (if colour == Ui.bad then
                Element.rgb255 0xFF 0xF6 0xF5

             else if colour == Ui.stale then
                Element.rgb255 0xFF 0xFB 0xF0

             else
                Ui.card
            )
        ]
        [ text body ]


{-| A chart if the cell asked for one, the table otherwise. Both keep the
count line above them, because how many rows there are is worth knowing either
way — and for a chart it is the only place a truncation would show.
-}
viewTable : Engine.Shape -> Table -> Html Msg
viewTable shape t =
    if shape.scalar then
        viewScalar shape t

    else
        case shape.chart of
            Just spec ->
                div []
                    [ resultMeta shape t
                    , Html.node "vega-chart"
                        [ Html.Attributes.property "spec" (Chart.spec spec t.rows) ]
                        []
                    ]

            Nothing ->
                viewRows shape t


{-| One number, shown as itself. The column's name is the label, because a
number with no word attached is not worth much.
-}
viewScalar : Engine.Shape -> Table -> Html Msg
viewScalar shape t =
    case ( shape.rowType, t.rows ) of
        ( [ ( name, columnType ) ], firstRow :: _ ) ->
            div [ class "scalar" ]
                [ div [ class "scalar-value" ]
                    [ Html.text (renderValue shape.declarations columnType name firstRow) ]
                , div [ class "scalar-label" ] [ Html.text name ]
                ]

        _ ->
            div [ class "result-meta" ] [ Html.text "no rows" ]


viewRows : Engine.Shape -> Table -> Html Msg
viewRows shape t =
    div []
        [ resultMeta shape t
        , div [ class "table-scroll" ]
            [ table []
                [ thead []
                    [ tr []
                        (shape.rowType
                            |> List.map
                                (\( name, columnType ) ->
                                    th []
                                        [ Html.text name
                                        , span [ class "coltype" ] [ Html.text (Schema.typeName columnType) ]
                                        ]
                                )
                        )
                    ]
                , tbody []
                    (t.rows
                        |> List.map
                            (\rowValue ->
                                tr []
                                    (shape.rowType
                                        |> List.map
                                            (\( name, columnType ) ->
                                                td [] [ Html.text (renderValue shape.declarations columnType name rowValue) ]
                                            )
                                    )
                            )
                    )
                ]
            ]
        ]


resultMeta : Engine.Shape -> Table -> Html Msg
resultMeta shape t =
    div []
        [ div [ class "result-meta" ]
            [ Html.text
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
        ]



{-| Both artefacts, side by side. They are two renderings of one checked
description, and showing them together is the clearest way to make that
visible — and the Elm module is what a hand-written Elm cell will import once
there is a daemon to compile one.
-}
viewArtefacts : Model -> Cell -> CellState -> Element Msg
viewArtefacts model cell state =
    case state.compiled of
        Nothing ->
            Element.none

        Just compiled ->
            let
                open =
                    Set.member cell.id model.expanded
            in
            column
                [ width fill
                , Border.widthEach { top = 1, left = 0, right = 0, bottom = 0 }
                , Border.color Ui.line
                , Background.color (Element.rgb255 0xFC 0xFC 0xFB)
                ]
                (el
                    [ paddingXY 12 7
                    , Element.pointer
                    , Element.Events.onClick (ToggleArtefacts cell.id)
                    , width fill
                    ]
                    (Ui.tinyCaps Ui.muted
                        ((if open then
                            "▾ "

                          else
                            "▸ "
                         )
                            ++ "generated"
                        )
                    )
                    :: (if open then
                            [ Element.wrappedRow
                                [ width fill
                                , spacing 1
                                , Background.color Ui.line
                                , Border.widthEach { top = 1, left = 0, right = 0, bottom = 0 }
                                , Border.color Ui.line
                                ]
                                [ artefact "SQL" compiled.sql
                                , artefact (moduleNameFor cell.id ++ " — Elm") compiled.elmModule
                                ]
                            ]

                        else
                            []
                       )
                )


artefact : String -> String -> Element Msg
artefact label body =
    column
        [ Element.alignTop
        , width (fill |> Element.minimum 300)
        , padding 12
        , spacing 6
        , Background.color Ui.card
        ]
        [ Ui.tinyCaps Ui.accent label
        , el [ width fill, Element.clipX ]
            (Element.html (pre [ class "artefact-pre" ] [ Html.text body ]))
        ]


{-| Rendered against the compiler's row type rather than against whatever JSON
happens to arrive, so a timestamp shows as a date and a custom type shows as
its constructor.
-}
renderValue : List TypeDecl -> Type -> String -> D.Value -> String
renderValue decls columnType column rowValue =
    case columnType of
        TMaybe inner ->
            if isNull column rowValue then
                "—"

            else
                renderValue decls inner column rowValue

        TTimestamp ->
            decodeField column D.float rowValue
                |> Maybe.map (formatDate << Time.millisToPosix << round)
                |> Maybe.withDefault "?"

        TCustom name ->
            case declarationOf name decls of
                -- A wrapper adds no information to show, so the underlying
                -- value is what there is; the column header already names the
                -- type.
                Just (Wraps _ wrapped) ->
                    renderValue decls
                        (Schema.primitive wrapped |> Maybe.withDefault TString)
                        column
                        rowValue

                _ ->
                    decodeField column D.string rowValue
                        |> Maybe.map (renderConstructor decls name rowValue)
                        |> Maybe.withDefault "?"

        _ ->
            Query.cellText column rowValue


{-| Show the constructor the tag stands for, and its payload where it has one.
This is the same reconstruction the generated decoder performs; doing it here
means the table proves the mapping without the generated module having to be
compiled and loaded first.
-}
declarationOf : String -> List TypeDecl -> Maybe Definition
declarationOf name decls =
    decls |> List.filter (\d -> d.name == name) |> List.head |> Maybe.map .definition


renderConstructor : List TypeDecl -> String -> D.Value -> String -> String
renderConstructor decls typeName rowValue tag =
    let
        found =
            decls
                |> List.filter (\d -> d.name == typeName)
                |> List.concatMap
                    (\d ->
                        case d.definition of
                            Enum constructors ->
                                constructors

                            Wraps _ _ ->
                                []
                    )
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
                    decodeField payload D.float rowValue
                        |> Maybe.map (\ms -> ctor.name ++ " " ++ formatDate (Time.millisToPosix (round ms)))
                        |> Maybe.withDefault ctor.name


decodeField : String -> D.Decoder a -> D.Value -> Maybe a
decodeField column decoder rowValue =
    D.decodeValue (D.field column decoder) rowValue |> Result.toMaybe


isNull : String -> D.Value -> Bool
isNull column rowValue =
    D.decodeValue (D.field column (D.null True)) rowValue |> Result.withDefault False


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
