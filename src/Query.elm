module Query exposing
    ( Column
    , Described
    , Outcome(..)
    , Table
    , cellText
    , describedDecoder
    , outcomeDecoder
    , padDecimals
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

    -- How DuckDB describes the materialised result. A query cell already knows
    -- its row type from the compiler and ignores this; a data cell has no
    -- other way to learn one.
    , described : List Described
    }


{-| A column as DuckDB describes it, with nullability observed from the data
rather than read off a declaration that a CREATE TABLE AS never set.
-}
type alias Described =
    { originalName : String
    , name : String
    , sqlType : String
    , nullable : Bool
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
    D.map7 Table
        (D.field "columns" (D.list columnDecoder))
        (D.field "rows" (D.list D.value))
        (D.field "rowCount" D.int)
        (D.field "truncated" D.bool)
        (D.field "hash" D.string)
        (D.field "millis" D.float)
        (D.field "described" describedDecoder)


describedDecoder : Decoder (List Described)
describedDecoder =
    D.list
        (D.map4 Described
            (D.oneOf [ D.field "originalName" D.string, D.field "name" D.string ])
            (D.field "name" D.string)
            (D.field "type" D.string)
            (D.field "nullable" D.bool)
        )


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


{-| Put back the trailing zeros a double cannot hold.

`roundTo 2` asks for two decimal places, but the value returns as a double and
12.50 *is* 12.5 there — so a column comes back a ragged mixture of two places,
one, and none at all where the value landed on a whole number. The places
asked for travel beside the value rather than in it (see
`Dsl.Compile.declaredDecimals`); this pads the rendered number out to them.

Only ever pads. A value with more decimals than were asked for is left alone,
because that means it did not come from the `roundTo` its column was credited
with, and trimming it here would claim a rounding that never happened.
Anything that is not a plain decimal numeral is passed through untouched — a
null's em dash, an exponent. A bare integer *is* padded, which is the point:
a whole number in a two-decimal column should read 8.00. That is safe because
the caller only reaches here for a Float column; the big integers DuckDB
sends as text rather than lose them to a JavaScript number never carry a
decimal place to pad to.

-}
padDecimals : Maybe Int -> String -> String
padDecimals places text =
    case places of
        Nothing ->
            text

        Just wanted ->
            if wanted <= 0 || String.any (\c -> c == 'e' || c == 'E') text || String.toFloat text == Nothing then
                text

            else
                case String.split "." text of
                    [ whole ] ->
                        whole ++ "." ++ String.repeat wanted "0"

                    [ whole, fraction ] ->
                        if String.length fraction >= wanted then
                            text

                        else
                            whole ++ "." ++ String.padRight wanted '0' fraction

                    _ ->
                        text


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
