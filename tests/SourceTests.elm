module SourceTests exposing (checks)

{-| Tests for source cells: the little language that names external data, and
how such a cell appears in the file format.
-}

import Cell exposing (Kind(..))
import Check exposing (Check, assert, equal, isErr)
import Dsl.Source as Source exposing (Format(..), Option(..))
import Notebook


checks : List Check
checks =
    specChecks ++ formatChecks


specChecks : List Check
specChecks =
    [ equal "source: a csv over https"
        (Ok { format = Csv, uri = "https://example.com/a.csv", options = [] })
        (Source.parse "csv \"https://example.com/a.csv\"")
    , equal "source: parquet"
        (Ok { format = Parquet, uri = "https://example.com/a.parquet", options = [] })
        (Source.parse "parquet \"https://example.com/a.parquet\"")
    , equal "source: json"
        (Ok { format = Json, uri = "https://example.com/a.json", options = [] })
        (Source.parse "json \"https://example.com/a.json\"")
    , equal "source: a path relative to the notebook"
        (Ok { format = Csv, uri = "data/orders.csv", options = [] })
        (Source.parse "csv \"data/orders.csv\"")
    , equal "source: surrounding whitespace and comments are ignored"
        (Ok { format = Csv, uri = "data/orders.csv", options = [] })
        (Source.parse "-- where the data lives\n  csv  \"data/orders.csv\"  \n")

    -- The URI is handed to the browser to fetch, so what it may name is
    -- restricted here rather than left to whatever fetch does with it.
    , isErr "source: file: is refused"
        (Source.parse "csv \"file:///etc/passwd\"")
    , isErr "source: data: is refused"
        (Source.parse "csv \"data:text/csv,a,b\"")
    , isErr "source: javascript: is refused"
        (Source.parse "csv \"javascript:alert(1)\"")
    , isErr "source: plain http to an arbitrary host is refused"
        (Source.parse "csv \"http://example.com/a.csv\"")
    , assert "source: http to localhost is allowed, for the notebook's own files"
        (case Source.parse "csv \"http://localhost:8080/data/a.csv\"" of
            Ok _ ->
                True

            Err _ ->
                False
        )
    , isErr "source: a path cannot climb out of the notebook's directory"
        (Source.parse "csv \"../../secrets.csv\"")
    , isErr "source: a protocol-relative URL is refused"
        (Source.parse "csv \"//example.com/a.csv\"")
    , isErr "source: an unknown format is refused"
        (Source.parse "xlsx \"a.xlsx\"")
    , isErr "source: a location is required"
        (Source.parse "csv")
    , isErr "source: an empty location is refused"
        (Source.parse "csv \"\"")
    -- Reader options, for files that are not tidy.
    , equal "source: a null string"
        (Ok { format = Csv, uri = "a.csv", options = [ Nulls "NA" ] })
        (Source.parse "csv \"a.csv\" nulls \"NA\"")
    , equal "source: several options together"
        (Ok { format = Csv, uri = "a.csv", options = [ Delimiter ";", Header False, Skip 2 ] })
        (Source.parse "csv \"a.csv\" delimiter \";\" header false skip 2")
    , equal "source: options render as DuckDB wants them"
        ", nullstr='NA', delim=';'"
        (Source.readerOptions { format = Csv, uri = "a.csv", options = [ Nulls "NA", Delimiter ";" ] })
    , equal "source: a value with a quote in it is escaped"
        ", nullstr='it''s'"
        (Source.readerOptions { format = Csv, uri = "a.csv", options = [ Nulls "it's" ] })
    , isErr "source: options do not apply to parquet, which has none"
        (Source.parse "parquet \"a.parquet\" nulls \"NA\"")
    , isErr "source: an unknown option is refused"
        (Source.parse "csv \"a.csv\" wobble \"NA\"")
    , equal "source: each format names the DuckDB reader for it"
        [ "read_csv_auto", "read_parquet", "read_json_auto" ]
        (List.map Source.reader [ Csv, Parquet, Json ])
    ]


formatChecks : List Check
formatChecks =
    let
        text =
            "```source orders\ncsv \"data/orders.csv\"\n```\n\n```duckpad recent\naccess orders () |> selectAll\n```"
    in
    [ equal "source: a source block round-trips through the file format"
        (Ok [ ( "orders", Source ), ( "recent", Query ) ])
        (Notebook.parse text
            |> Result.map (.cells >> List.map (\c -> ( c.id, c.kind )))
        )
    , equal "source: serializing puts it back under its own fence"
        (Ok True)
        (Notebook.parse text
            |> Result.map (Notebook.serialize >> String.contains "```source orders")
        )
    , equal "source: a source and a query cannot share a name"
        True
        (case Notebook.parse "```source a\ncsv \"x.csv\"\n```\n\n```duckpad a\naccess t () |> selectAll\n```" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    ]
