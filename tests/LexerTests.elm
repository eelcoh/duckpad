module LexerTests exposing (checks)

{-| Tests for the highlighter's tokeniser.

The first of these is the one that matters. The coloured text sits underneath
a transparent textarea, so if the tokens do not reconstruct the source exactly
the two layers drift and the caret lands in the wrong place.
-}

import Check exposing (Check, assert, equal)
import Dsl.Lexer as Lexer exposing (Kind(..))


checks : List Check
checks =
    losslessChecks ++ classifyChecks


samples : List String
samples =
    [ "access orders () |> selectAll"
    , "access orders ()\n  |> filter (\\o -> o.total > 100.5)\n  |> selectAll"
    , "type Status\n  = Submitted \"submitted\"\n  | Delivered \"delivered\" from .at"
    , "csv \"https://example.com/a.csv\""
    , "  |> reduce (\\g -> { n = count g, revenue = sum g.total })"
    , "-- a comment\naccess t () -- trailing\n"
    , "\n\n   \n\t"
    , ""
    , "unterminated \"string"
    , "o.from == \"x\" && not o.flag"
    ]


{-| Concatenating every token has to give the source back, character for
character.
-}
losslessChecks : List Check
losslessChecks =
    samples
        |> List.indexedMap
            (\i source ->
                equal ("lexer: sample " ++ String.fromInt i ++ " round-trips exactly")
                    source
                    (Lexer.tokenize source |> List.map .text |> String.concat)
            )


kindsOf : String -> List ( Kind, String )
kindsOf source =
    Lexer.tokenize source
        |> List.filter (\t -> String.trim t.text /= "")
        |> List.map (\t -> ( t.kind, t.text ))


classifyChecks : List Check
classifyChecks =
    [ equal "lexer: a stage word is a keyword and a bare name is not"
        [ ( Keyword, "access" ), ( Plain, "orders" ), ( Operator, "()" ), ( Operator, "|>" ), ( Keyword, "selectAll" ) ]
        (kindsOf "access orders () |> selectAll")
    , equal "lexer: an accessor is one token including the dot"
        [ ( Field, ".origin" ) ]
        (kindsOf ".origin")
    , equal "lexer: a float is not read as a field access"
        [ ( Number, "100.5" ) ]
        (kindsOf "100.5")
    , equal "lexer: an uppercase word is a type"
        [ ( Keyword, "type" ), ( TypeName, "Status" ) ]
        (kindsOf "type Status")
    , equal "lexer: aggregates are their own kind, since they are not reserved"
        [ ( Aggregate, "count" ), ( Plain, "g" ) ]
        (kindsOf "count g")
    , equal "lexer: a comment runs to the end of the line, not past it"
        [ ( Comment, "-- note" ), ( Keyword, "access" ) ]
        (kindsOf "-- note\naccess")
    , equal "lexer: a string keeps its quotes and swallows what is inside"
        [ ( Keyword, "csv" ), ( Str, "\"a -- b\"" ) ]
        (kindsOf "csv \"a -- b\"")
    , equal "lexer: an unterminated string still ends at the end of input"
        [ ( Str, "\"abc" ) ]
        (kindsOf "\"abc")
    , equal "lexer: a source format is highlighted like any other keyword"
        [ ( Keyword, "parquet" ) ]
        (kindsOf "parquet")
    , assert "lexer: nothing in a comment is tokenised separately"
        (kindsOf "-- access orders () |> selectAll" |> List.length |> (==) 1)
    ]
