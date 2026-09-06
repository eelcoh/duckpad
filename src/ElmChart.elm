module ElmChart exposing (Hover, Plot, empty, plot, rowLimit, view)

{-| Render a checked Duckpad chart with elm-charts.

Duckpad rows arrive as dynamic JSON, while elm-charts deliberately works with
ordinary Elm records. This module is the narrow adapter between them: channel
types still come from the DSL checker, invalid or null plotting values are
omitted, and everything after that boundary is typed Elm-owned SVG.

-}

import Chart as C
import Chart.Attributes as CA
import Chart.Events as CE
import Chart.Item as CI
import Dsl.Ast exposing (ChartKind(..))
import Dsl.Check exposing (ChartSpec)
import Dsl.Schema exposing (Type(..))
import Html exposing (Html, div, text)
import Html.Attributes exposing (class, style)
import Json.Decode as D
import Svg
import Time


rowLimit : Int
rowLimit =
    5000


type Hover
    = NoHover
    | HoverBars (List (CI.One Datum CI.Bar))
    | HoverDots (List (CI.One Datum CI.Dot))


empty : Hover
empty =
    NoHover


type alias Datum =
    { x : Float
    , y : Float
    , xLabel : String
    , colorLabel : String
    }


type alias Prepared =
    { kind : ChartKind
    , xType : Type
    , xName : String
    , yName : String
    , groups : List Group
    , all : List Datum
    }


type alias Group =
    { name : String
    , color : String
    , data : List Datum
    }


type alias Plot =
    { points : List { x : Float, y : Float, xLabel : String, colorLabel : String }
    , groups : List String
    }


plot : ChartSpec -> List D.Value -> Maybe Plot
plot spec rows =
    prepare spec rows
        |> Maybe.map
            (\prepared ->
                { points =
                    List.map
                        (\point ->
                            { x = point.x
                            , y = point.y
                            , xLabel = point.xLabel
                            , colorLabel = point.colorLabel
                            }
                        )
                        prepared.all
                , groups = List.map .name prepared.groups
                }
            )


view : (Hover -> msg) -> Hover -> ChartSpec -> List D.Value -> Html msg
view onHover hovering spec rows =
    case prepare spec rows of
        Nothing ->
            div [ class "elm-chart elm-chart-error" ] [ text "chart data could not be decoded" ]

        Just chart ->
            div [ class "elm-chart" ]
                [ C.chart
                    [ CA.width 920
                    , CA.height 270
                    , CA.margin { top = 12, right = 20, bottom = 42, left = 58 }
                    , CA.htmlAttrs [ style "width" "100%", style "height" "100%" ]
                    , hoverMove onHover chart.kind
                    , CE.onMouseLeave (onHover NoHover)
                    ]
                    (axes chart ++ marks hovering chart)
                ]


hoverMove onHover kind =
    case kind of
        Bar ->
            CE.onMouseMove (onHover << HoverBars) (CE.getNearest CI.bars)

        Line ->
            CE.onMouseMove (onHover << HoverDots) (CE.getNearestWithin 18 CI.dots)

        Scatter ->
            CE.onMouseMove (onHover << HoverDots) (CE.getNearestWithin 18 CI.dots)


axes : Prepared -> List (C.Element Datum msg)
axes chart =
    [ C.yLabels [ CA.withGrid, CA.color muted, CA.fontSize 10 ] ]
        ++ (case primitive chart.xType of
                TInt ->
                    [ C.xLabels [ CA.color muted, CA.fontSize 10, CA.ints ] ]

                TFloat ->
                    [ C.xLabels [ CA.color muted, CA.fontSize 10 ] ]

                TTimestamp ->
                    [ C.xLabels [ CA.color muted, CA.fontSize 10, CA.times Time.utc ] ]

                _ ->
                    List.map categoryLabel chart.all
           )
        ++ (if List.length chart.groups > 1 then
                [ C.legendsAt .max .max
                    [ CA.column, CA.alignRight, CA.moveLeft 8, CA.moveDown 8, CA.spacing 6 ]
                    [ CA.fontSize 10, CA.color muted, CA.width 12, CA.height 3, CA.spacing 5 ]
                ]

            else
                []
           )


categoryLabel : Datum -> C.Element Datum msg
categoryLabel datum =
    C.xLabel
        [ CA.x datum.x, CA.color muted, CA.fontSize 10, CA.ellipsis 72 16 ]
        [ Svg.text datum.xLabel ]


marks : Hover -> Prepared -> List (C.Element Datum msg)
marks hovering chart =
    let
        tooltip =
            case ( chart.kind, hovering ) of
                ( Bar, HoverBars items ) ->
                    [ C.each items (\_ item -> [ C.tooltip item [] [] [] ]) ]

                ( Line, HoverDots items ) ->
                    [ C.each items (\_ item -> [ C.tooltip item [] [] [] ]) ]

                ( Scatter, HoverDots items ) ->
                    [ C.each items (\_ item -> [ C.tooltip item [] [] [] ]) ]

                _ ->
                    []
    in
    List.indexedMap (mark chart.kind chart.yName) chart.groups ++ tooltip


mark : ChartKind -> String -> Int -> Group -> C.Element Datum msg
mark kind yName _ group =
    case kind of
        Bar ->
            C.bars [ CA.x1 .x, CA.margin 0.16 ]
                [ C.bar .y [ CA.color group.color, CA.roundTop 0.1 ]
                    |> C.named (seriesName yName group.name)
                    |> C.format trimFloat
                ]
                group.data

        Line ->
            C.series .x
                [ C.interpolated .y [ CA.color group.color, CA.width 2 ] [ CA.color group.color, CA.size 4 ]
                    |> C.named (seriesName yName group.name)
                    |> C.format trimFloat
                ]
                group.data

        Scatter ->
            C.series .x
                [ C.scatter .y [ CA.color group.color, CA.size 7 ]
                    |> C.named (seriesName yName group.name)
                    |> C.format trimFloat
                ]
                group.data


seriesName : String -> String -> String
seriesName yName group =
    if group == "" then
        yName

    else
        group


prepare : ChartSpec -> List D.Value -> Maybe Prepared
prepare spec rows =
    case ( channel "x" spec, channel "y" spec ) of
        ( Just ( xName, xType ), Just ( yName, _ ) ) ->
            let
                colorChannel =
                    channel "color" spec

                data =
                    rows
                        |> List.indexedMap (decodeDatum xName xType yName colorChannel)
                        |> List.filterMap identity
            in
            Just
                { kind = spec.kind
                , xType = xType
                , xName = xName
                , yName = yName
                , groups = groupData colorChannel data
                , all = data
                }

        _ ->
            Nothing


channel : String -> ChartSpec -> Maybe ( String, Type )
channel wanted spec =
    spec.channels
        |> List.filterMap
            (\( name, field, fieldType ) ->
                if name == wanted then
                    Just ( field, fieldType )

                else
                    Nothing
            )
        |> List.head


decodeDatum : String -> Type -> String -> Maybe ( String, Type ) -> Int -> D.Value -> Maybe Datum
decodeDatum xName xType yName colorChannel index row =
    Maybe.map2
        (\x y ->
            { x = x
            , y = y
            , xLabel = fieldLabel xType xName row
            , colorLabel = colorChannel |> Maybe.map (\( name, fieldType ) -> fieldLabel fieldType name row) |> Maybe.withDefault ""
            }
        )
        (xValue xType xName index row)
        (numberField yName row)


xValue : Type -> String -> Int -> D.Value -> Maybe Float
xValue fieldType name index row =
    case primitive fieldType of
        TInt ->
            numberField name row

        TFloat ->
            numberField name row

        TTimestamp ->
            numberField name row

        _ ->
            nonNullField name row |> Maybe.map (always (toFloat (index + 1)))


numberField : String -> D.Value -> Maybe Float
numberField name row =
    D.decodeValue (D.field name (D.nullable D.float)) row
        |> Result.toMaybe
        |> Maybe.andThen identity


nonNullField : String -> D.Value -> Maybe D.Value
nonNullField name row =
    D.decodeValue (D.field name (D.nullable D.value)) row
        |> Result.toMaybe
        |> Maybe.andThen identity


fieldLabel : Type -> String -> D.Value -> String
fieldLabel fieldType name row =
    case primitive fieldType of
        TInt ->
            numberField name row |> Maybe.map (String.fromInt << round) |> Maybe.withDefault "—"

        TFloat ->
            numberField name row |> Maybe.map trimFloat |> Maybe.withDefault "—"

        TTimestamp ->
            numberField name row |> Maybe.map (formatDate << Time.millisToPosix << round) |> Maybe.withDefault "—"

        TBool ->
            decodeField name D.bool row |> Maybe.map (\value -> if value then "true" else "false") |> Maybe.withDefault "—"

        _ ->
            decodeField name D.string row |> Maybe.withDefault "—"


decodeField : String -> D.Decoder a -> D.Value -> Maybe a
decodeField name decoder row =
    D.decodeValue (D.field name decoder) row |> Result.toMaybe


primitive : Type -> Type
primitive fieldType =
    case fieldType of
        TMaybe inner ->
            primitive inner

        _ ->
            fieldType


groupData : Maybe ( String, Type ) -> List Datum -> List Group
groupData colorChannel data =
    case colorChannel of
        Nothing ->
            [ Group "" (palette 0) data ]

        Just _ ->
            data
                |> List.foldl addToGroup []
                |> List.indexedMap (\index group -> { group | color = palette index })


addToGroup : Datum -> List Group -> List Group
addToGroup datum groups =
    case groups of
        [] ->
            [ Group datum.colorLabel "" [ datum ] ]

        group :: rest ->
            if group.name == datum.colorLabel then
                { group | data = group.data ++ [ datum ] } :: rest

            else
                group :: addToGroup datum rest


palette : Int -> String
palette index =
    [ "#2f5d8a", "#7a4ea8", "#17706e", "#a3543a", "#2f7a4f", "#b8860b", "#6b7280" ]
        |> List.drop (modBy 7 index)
        |> List.head
        |> Maybe.withDefault "#2f5d8a"


muted : String
muted =
    "#6b7280"


trimFloat : Float -> String
trimFloat value =
    String.fromFloat value


formatDate : Time.Posix -> String
formatDate posix =
    let
        pad number =
            String.padLeft 2 '0' (String.fromInt number)
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
