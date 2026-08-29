module Query exposing
    ( Column
    , Outcome(..)
    , Table
    , cellText
    , outcomeDecoder
    )

{-| What comes back across the port from DuckDB-wasm.

Rows arrive as JSON objects keyed by column name rather than as positional
tuples, for one reason: the generic table view and the typed decoder in
`Spike.Orders` then read the *same* payload, the latter with ordinary
`Json.Decode.field`. That is the shape the eventual query compiler has to
generate, so the spike should prove it works.

-}

import Json.Decode as D exposing (Decoder)


type alias Column =
    { name : String
    , sqlType : String
    }


type alias Table =
    { columns : List Column
    , rows : List D.Value
    , rowCount : Int
    , truncated : Bool
    , hash : String
    , millis : Float
    }


type Outcome
    = Success String Table
    | Failure String String


outcomeDecoder : Decoder Outcome
outcomeDecoder =
    D.field "ok" D.bool
        |> D.andThen
            (\ok ->
                if ok then
                    D.map2 Success (D.field "cellId" D.string) tableDecoder

                else
                    D.map2 Failure (D.field "cellId" D.string) (D.field "error" D.string)
            )


tableDecoder : Decoder Table
tableDecoder =
    D.map6 Table
        (D.field "columns" (D.list columnDecoder))
        (D.field "rows" (D.list D.value))
        (D.field "rowCount" D.int)
        (D.field "truncated" D.bool)
        (D.field "hash" D.string)
        (D.field "millis" D.float)


columnDecoder : Decoder Column
columnDecoder =
    D.map2 Column
        (D.field "name" D.string)
        (D.field "type" D.string)


{-| Render one field of one row for the generic table view, without knowing
anything about its type. The typed path never goes through here.
-}
cellText : String -> D.Value -> String
cellText column row =
    D.decodeValue (D.field column looseString) row
        |> Result.withDefault "?"


looseString : Decoder String
looseString =
    D.oneOf
        [ D.string
        , D.map String.fromFloat D.float
        , D.map String.fromInt D.int
        , D.map
            (\b ->
                if b then
                    "true"

                else
                    "false"
            )
            D.bool
        , D.null "NULL"
        , D.map (\_ -> "…") D.value
        ]
