module ChartTests exposing (checks)

import Check exposing (Check, equal)
import Dsl.Ast exposing (ChartKind(..))
import Dsl.Check exposing (ChartSpec)
import Dsl.Schema exposing (Type(..))
import ElmChart
import Json.Encode as E


checks : List Check
checks =
    [ equal "elm chart: categories keep row order and null y values are omitted"
        (Just
            { points =
                [ { x = 1, y = 3, xLabel = "Ajax", colorLabel = "" }
                , { x = 3, y = 5.5, xLabel = "PSV", colorLabel = "" }
                ]
            , groups = [ "" ]
            }
        )
        (ElmChart.plot categorical
            [ row [ ( "club", E.string "Ajax" ), ( "goals", E.int 3 ) ]
            , row [ ( "club", E.string "Feyenoord" ), ( "goals", E.null ) ]
            , row [ ( "club", E.string "PSV" ), ( "goals", E.float 5.5 ) ]
            ]
        )
    , equal "elm chart: numeric axes retain their values"
        (Just
            { points = [ { x = 0.25, y = 1.75, xLabel = "0.25", colorLabel = "" } ]
            , groups = [ "" ]
            }
        )
        (ElmChart.plot numeric [ row [ ( "xg", E.float 0.25 ), ( "npxg", E.float 1.75 ) ] ])
    , equal "elm chart: timestamp labels use the notebook date spelling"
        (Just
            { points = [ { x = 0, y = 12, xLabel = "1970-01-01", colorLabel = "" } ]
            , groups = [ "" ]
            }
        )
        (ElmChart.plot timeline [ row [ ( "day", E.int 0 ), ( "flights", E.int 12 ) ] ])
    , equal "elm chart: color channels form stable first-seen groups"
        (Just
            { points =
                [ { x = 1, y = 1, xLabel = "1", colorLabel = "north" }
                , { x = 2, y = 2, xLabel = "2", colorLabel = "south" }
                , { x = 3, y = 3, xLabel = "3", colorLabel = "north" }
                ]
            , groups = [ "north", "south" ]
            }
        )
        (ElmChart.plot colored
            [ row [ ( "x", E.int 1 ), ( "y", E.int 1 ), ( "region", E.string "north" ) ]
            , row [ ( "x", E.int 2 ), ( "y", E.int 2 ), ( "region", E.string "south" ) ]
            , row [ ( "x", E.int 3 ), ( "y", E.int 3 ), ( "region", E.string "north" ) ]
            ]
        )
    ]


categorical : ChartSpec
categorical =
    { kind = Bar, channels = [ ( "x", "club", TString ), ( "y", "goals", TInt ) ] }


numeric : ChartSpec
numeric =
    { kind = Scatter, channels = [ ( "x", "xg", TFloat ), ( "y", "npxg", TFloat ) ] }


timeline : ChartSpec
timeline =
    { kind = Line, channels = [ ( "x", "day", TTimestamp ), ( "y", "flights", TInt ) ] }


colored : ChartSpec
colored =
    { kind = Line
    , channels = [ ( "x", "x", TInt ), ( "y", "y", TInt ), ( "color", "region", TString ) ]
    }


row : List ( String, E.Value ) -> E.Value
row =
    E.object
