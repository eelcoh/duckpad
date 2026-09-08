module ElmChartsSpike exposing (main)

{-| A deliberately separate elm-charts proving ground.

It exercises the three chart shapes Duckpad supports independently of the
dynamic production adapter. Keeping it executable makes the original parity
decision repeatable instead of leaving it as a throwaway experiment.

-}

import Browser
import Chart as C
import Chart.Attributes as CA
import Chart.Events as CE
import Chart.Item as CI
import Html exposing (Html, div, h2, p, text)
import Html.Attributes exposing (style)
import Svg


type alias Datum =
    { x : Float
    , y : Float
    , label : String
    }


type alias Model =
    { bars : List (CI.One Datum CI.Bar)
    , line : List (CI.One Datum CI.Dot)
    , points : List (CI.One Datum CI.Dot)
    }


type Msg
    = HoverBars (List (CI.One Datum CI.Bar))
    | HoverLine (List (CI.One Datum CI.Dot))
    | HoverPoints (List (CI.One Datum CI.Dot))


main : Program () Model Msg
main =
    Browser.sandbox
        { init = { bars = [], line = [], points = [] }
        , update = update
        , view = view
        }


update : Msg -> Model -> Model
update msg model =
    case msg of
        HoverBars hovered ->
            { model | bars = hovered }

        HoverLine hovered ->
            { model | line = hovered }

        HoverPoints hovered ->
            { model | points = hovered }


view : Model -> Html Msg
view model =
    div
        [ style "max-width" "960px"
        , style "margin" "24px auto"
        , style "font-family" "IBM Plex Sans, system-ui, sans-serif"
        , style "color" "#1f2933"
        ]
        [ h2 [] [ text "Duckpad · elm-charts parity spike" ]
        , p [] [ text "Bar, line and point rendering are Elm-owned SVG; hover each mark for its library tooltip." ]
        , sample "Categorical bar" (barChart model.bars)
        , sample "Ordered line" (lineChart model.line)
        , sample "Numeric scatter" (scatterChart model.points)
        ]


sample : String -> Html Msg -> Html Msg
sample label chart =
    div [ style "margin" "28px 0" ]
        [ h2 [ style "font-size" "14px" ] [ text label ]
        , div [ style "width" "100%", style "height" "280px" ] [ chart ]
        ]


barChart : List (CI.One Datum CI.Bar) -> Html Msg
barChart hovered =
    C.chart
        (container (HoverBars []) HoverBars (CE.getNearest CI.bars))
        ([ C.yLabels [ CA.withGrid, CA.color "#6b7280", CA.fontSize 10 ]
         , C.bars [ CA.x1 .x, CA.margin 0.18 ]
            [ C.bar .y [ CA.color "#2f5d8a", CA.roundTop 0.12 ]
                |> C.named "departures"
            ]
            barData
         , C.each hovered (\_ item -> [ C.tooltip item [] [] [] ])
         ]
            ++ categoryLabels barData
        )


lineChart : List (CI.One Datum CI.Dot) -> Html Msg
lineChart hovered =
    C.chart
        (container (HoverLine []) HoverLine (CE.getNearestWithin 18 CI.dots))
        [ C.xLabels [ CA.color "#6b7280", CA.fontSize 10 ]
        , C.yLabels [ CA.withGrid, CA.color "#6b7280", CA.fontSize 10 ]
        , C.series .x
            [ C.interpolated .y [ CA.color "#2f5d8a", CA.width 2 ] [ CA.color "#2f5d8a", CA.size 4 ]
                |> C.named "flights"
            ]
            lineData
        , C.each hovered (\_ item -> [ C.tooltip item [] [] [] ])
        ]


scatterChart : List (CI.One Datum CI.Dot) -> Html Msg
scatterChart hovered =
    C.chart
        (container (HoverPoints []) HoverPoints (CE.getNearestWithin 18 CI.dots))
        [ C.xLabels [ CA.withGrid, CA.color "#6b7280", CA.fontSize 10 ]
        , C.yLabels [ CA.withGrid, CA.color "#6b7280", CA.fontSize 10 ]
        , C.series .x
            [ C.scatter .y [ CA.color "#17706e", CA.size 7 ]
                |> C.named "players"
            ]
            scatterData
        , C.each hovered (\_ item -> [ C.tooltip item [] [] [] ])
        ]


container leave hover decoder =
    [ CA.width 920
    , CA.height 260
    , CA.margin { top = 10, right = 20, bottom = 35, left = 55 }
    , CA.htmlAttrs [ style "width" "100%", style "height" "100%" ]
    , CE.onMouseMove hover decoder
    , CE.onMouseLeave leave
    ]


categoryLabels : List Datum -> List (C.Element Datum Msg)
categoryLabels data =
    List.map
        (\datum ->
            C.xLabel
                [ CA.x datum.x, CA.color "#6b7280", CA.fontSize 10 ]
                [ Svg.text datum.label ]
        )
        data


barData : List Datum
barData =
    [ Datum 1 42 "NH"
    , Datum 2 31 "ZH"
    , Datum 3 24 "NB"
    , Datum 4 19 "UT"
    , Datum 5 13 "GE"
    ]


lineData : List Datum
lineData =
    [ Datum 1 18 "Mon"
    , Datum 2 24 "Tue"
    , Datum 3 21 "Wed"
    , Datum 4 32 "Thu"
    , Datum 5 29 "Fri"
    ]


scatterData : List Datum
scatterData =
    [ Datum 0.2 0.6 "A"
    , Datum 0.5 1.4 "B"
    , Datum 0.8 1.1 "C"
    , Datum 1.1 2.3 "D"
    , Datum 1.5 2.0 "E"
    ]
