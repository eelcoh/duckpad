module Dsl.Source exposing (Format(..), Spec, extension, formatName, parse, reader)

{-| The tiny language a source cell is written in.

    csv "https://cdn.jsdelivr.net/npm/vega-datasets@2/data/seattle-weather.csv"

A source names external data; it does not compute anything. That distinction
runs through the whole design: a source becomes a view rather than a
materialised table, and its identity is the URI it points at rather than the
rows behind it.

-}

import Parser exposing ((|.), (|=), Parser)


type Format
    = Csv
    | Parquet
    | Json


type alias Spec =
    { format : Format
    , uri : String
    }


parse : String -> Result String Spec
parse source =
    case Parser.run spec source of
        Ok parsed ->
            validate parsed

        Err _ ->
            Err "a source reads `csv \"…\"`, `parquet \"…\"` or `json \"…\"`"


spec : Parser Spec
spec =
    Parser.succeed Spec
        |. ws
        |= format
        |. ws
        |= quoted
        |. ws
        |. Parser.end


format : Parser Format
format =
    Parser.oneOf
        [ Parser.succeed Csv |. Parser.keyword "csv"
        , Parser.succeed Parquet |. Parser.keyword "parquet"
        , Parser.succeed Json |. Parser.keyword "json"
        ]


quoted : Parser String
quoted =
    Parser.succeed identity
        |. Parser.symbol "\""
        |= Parser.getChompedString (Parser.chompWhile (\c -> c /= '"'))
        |. Parser.symbol "\""


ws : Parser ()
ws =
    Parser.loop () <|
        \_ ->
            Parser.oneOf
                [ Parser.succeed (Parser.Loop ()) |. Parser.lineComment "--"
                , Parser.succeed (Parser.Loop ())
                    |. Parser.chompIf isSpace
                    |. Parser.chompWhile isSpace
                , Parser.succeed (Parser.Done ())
                ]


isSpace : Char -> Bool
isSpace c =
    c == ' ' || c == '\n' || c == '\r' || c == '\t'


{-| Only https and paths relative to the notebook are allowed.

The URI is handed to the browser to fetch, so the schemes that can reach
somewhere unexpected — `file:`, `data:`, `javascript:` — are refused here
rather than left to whatever the fetch does with them. Plain `http` is
refused too, except on localhost, where it is how the notebook serves its own
sample data during development.

-}
validate : Spec -> Result String Spec
validate parsed =
    let
        uri =
            String.trim parsed.uri
    in
    if uri == "" then
        Err "this source has no location"

    else if String.startsWith "https://" uri then
        Ok { parsed | uri = uri }

    else if String.startsWith "http://localhost" uri || String.startsWith "http://127.0.0.1" uri then
        Ok { parsed | uri = uri }

    else if hasScheme uri || String.startsWith "//" uri then
        Err ("`" ++ scheme uri ++ "` is not a location this can read. Use https, or a path next to the notebook.")

    else if String.startsWith "/" uri then
        Ok { parsed | uri = uri }

    else if String.contains ".." uri then
        Err "a source path cannot climb out of the notebook's directory"

    else
        Ok { parsed | uri = uri }


{-| Whether the URI names a scheme at all.

Testing for `://` is not enough: `data:` and `javascript:` carry no slashes
before their payload, so they would slip through as relative paths. A scheme
is a colon that appears before any slash.

-}
hasScheme : String -> Bool
hasScheme uri =
    case ( String.indexes ":" uri, String.indexes "/" uri ) of
        ( [], _ ) ->
            False

        ( colon :: _, [] ) ->
            colon >= 0

        ( colon :: _, slash :: _ ) ->
            colon < slash


scheme : String -> String
scheme uri =
    case String.indexes ":" uri of
        colon :: _ ->
            String.left colon uri

        [] ->
            uri


formatName : Format -> String
formatName f =
    case f of
        Csv ->
            "csv"

        Parquet ->
            "parquet"

        Json ->
            "json"


{-| The DuckDB function that reads this format.
-}
reader : Format -> String
reader f =
    case f of
        Csv ->
            "read_csv_auto"

        Parquet ->
            "read_parquet"

        Json ->
            "read_json_auto"


{-| Registered files keep their extension: DuckDB's readers sniff it.
-}
extension : Format -> String
extension =
    formatName
