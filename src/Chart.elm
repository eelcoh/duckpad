module Chart exposing (rowLimit, spec)

{-| A Vega-Lite specification, built from a checked chart and its rows.

The reason this is worth generating rather than hand-writing: Vega-Lite needs
every channel annotated as quantitative, nominal or temporal, and those
annotations are normally typed out by a person and quietly wrong — a number
read as a category, a date read as a string, and a chart that renders
something plausible and false. Here the annotation comes from the column type
the compiler already worked out.

-}

import Dsl.Ast exposing (ChartKind(..))
import Dsl.Check exposing (ChartSpec)
import Dsl.Schema exposing (Type(..))
import Json.Decode as D
import Json.Encode as E


{-| How many rows a chart asks the database for.

A table only ever shows a screenful, but a chart of the first two hundred
points of a time series is a misleading picture rather than a partial one.
Still bounded: this runs in a browser tab.

-}
rowLimit : Int
rowLimit =
    5000


spec : ChartSpec -> List D.Value -> E.Value
spec chart rows =
    E.object
        [ ( "$schema", E.string "https://vega.github.io/schema/vega-lite/v5.json" )
        , ( "data", E.object [ ( "values", E.list identity rows ) ] )
        , ( "mark", mark chart.kind )
        , ( "encoding", E.object (List.map encoding chart.channels) )
        , ( "width", E.string "container" )
        , ( "height", E.int 260 )
        , ( "autosize", E.object [ ( "type", E.string "fit" ), ( "contains", E.string "padding" ) ] )
        , ( "config", config )
        ]


mark : ChartKind -> E.Value
mark kind =
    E.object
        [ ( "type"
          , E.string
                (case kind of
                    Bar ->
                        "bar"

                    Line ->
                        "line"

                    Scatter ->
                        "point"
                )
          )
        , ( "tooltip", E.bool True )
        , ( "filled", E.bool True )
        ]


encoding : ( String, String, Type ) -> ( String, E.Value )
encoding ( channel, column, columnType ) =
    ( channel
    , E.object
        [ ( "field", E.string column )
        , ( "type", E.string (vegaType columnType) )
        , ( "title", E.string column )
        ]
    )


{-| The whole point of the exercise: derived, not asserted.
-}
vegaType : Type -> String
vegaType t =
    case t of
        TInt ->
            "quantitative"

        TFloat ->
            "quantitative"

        TTimestamp ->
            "temporal"

        TMaybe inner ->
            vegaType inner

        _ ->
            "nominal"


{-| Enough to stop a chart looking like a different application from the
notebook around it.
-}
config : E.Value
config =
    let
        font =
            E.string "IBM Plex Sans, system-ui, sans-serif"

        muted =
            E.string "#6b7280"
    in
    E.object
        [ ( "background", E.string "transparent" )
        , ( "axis"
          , E.object
                [ ( "labelFont", font )
                , ( "titleFont", font )
                , ( "labelColor", muted )
                , ( "titleColor", muted )
                , ( "labelFontSize", E.int 10 )
                , ( "titleFontSize", E.int 10 )
                , ( "titleFontWeight", E.string "normal" )
                , ( "gridColor", E.string "#eef0f2" )
                , ( "domainColor", E.string "#e3e6ea" )
                , ( "tickColor", E.string "#e3e6ea" )
                ]
          )
        , ( "legend"
          , E.object
                [ ( "labelFont", font )
                , ( "titleFont", font )
                , ( "labelColor", muted )
                , ( "titleColor", muted )
                , ( "labelFontSize", E.int 10 )
                , ( "titleFontSize", E.int 10 )
                ]
          )
        , ( "range", E.object [ ( "category", E.list E.string palette ) ] )
        , ( "view", E.object [ ( "stroke", E.string "transparent" ) ] )
        ]


palette : List String
palette =
    [ "#2f5d8a", "#7a4ea8", "#17706e", "#a3543a", "#2f7a4f", "#b8860b", "#6b7280" ]
