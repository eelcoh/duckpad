module Dsl.Lexer exposing (Kind(..), Token, className, tokenize)

{-| A lossless tokeniser, for colouring a cell.

Separate from `Dsl.Parser` because the two want different things: a parser
discards whitespace and comments and stops at the first error, while a
highlighter has to account for every character and keep going. What they do
share is `Dsl.Keywords`, so a word added to the grammar is coloured without
anyone remembering to.

The losslessness matters mechanically, not just tidily. The coloured text is
rendered underneath a transparent textarea, so if the tokens did not
reconstruct the source exactly — every space, every newline — the two layers
would drift apart and the caret would sit in the wrong place.

-}

import Dsl.Keywords
import Set


type Kind
    = Keyword
    | Callable
    | TypeName
    | Field
    | Str
    | Number
    | Operator
    | Comment
    | Plain


type alias Token =
    { kind : Kind
    , text : String
    }


className : Kind -> String
className kind =
    case kind of
        Keyword ->
            "tok-keyword"

        Callable ->
            "tok-callable"

        TypeName ->
            "tok-type"

        Field ->
            "tok-field"

        Str ->
            "tok-string"

        Number ->
            "tok-number"

        Operator ->
            "tok-operator"

        Comment ->
            "tok-comment"

        Plain ->
            "tok-plain"


tokenize : String -> List Token
tokenize source =
    scan (String.toList source) [] |> List.reverse


scan : List Char -> List Token -> List Token
scan chars acc =
    case chars of
        [] ->
            acc

        '-' :: '-' :: rest ->
            let
                ( body, remaining ) =
                    span (\c -> c /= '\n') rest
            in
            scan remaining (Token Comment ("--" ++ String.fromList body) :: acc)

        '"' :: rest ->
            let
                ( body, remaining ) =
                    span (\c -> c /= '"') rest

                closing =
                    case remaining of
                        '"' :: _ ->
                            "\""

                        _ ->
                            ""
            in
            scan (List.drop 1 remaining)
                (Token Str ("\"" ++ String.fromList body ++ closing) :: acc)

        '.' :: next :: rest ->
            if Char.isLower next || next == '_' then
                let
                    ( body, remaining ) =
                        span isWordChar (next :: rest)
                in
                scan remaining (Token Field ("." ++ String.fromList body) :: acc)

            else
                scan (next :: rest) (Token Plain "." :: acc)

        c :: rest ->
            if Char.isDigit c then
                let
                    ( body, remaining ) =
                        span (\x -> Char.isDigit x || x == '.') (c :: rest)
                in
                scan remaining (Token Number (String.fromList body) :: acc)

            else if Char.isUpper c then
                let
                    ( body, remaining ) =
                        span isWordChar (c :: rest)
                in
                scan remaining (Token TypeName (String.fromList body) :: acc)

            else if Char.isLower c || c == '_' then
                let
                    ( body, remaining ) =
                        span isWordChar (c :: rest)

                    word =
                        String.fromList body
                in
                scan remaining (Token (wordKind word) word :: acc)

            else if isOperator c then
                let
                    ( body, remaining ) =
                        span isOperator (c :: rest)
                in
                scan remaining (Token Operator (String.fromList body) :: acc)

            else
                scan rest (Token Plain (String.fromChar c) :: acc)


wordKind : String -> Kind
wordKind word =
    if Set.member word Dsl.Keywords.reserved || Set.member word Dsl.Keywords.formats then
        Keyword

    else if Set.member word Dsl.Keywords.aggregates || Set.member word Dsl.Keywords.functions || Set.member word Dsl.Keywords.windows then
        Callable

    else
        Plain


isWordChar : Char -> Bool
isWordChar c =
    Char.isAlphaNum c || c == '_'


isOperator : Char -> Bool
isOperator c =
    List.member c [ '|', '>', '<', '=', '-', '+', '*', '/', '&', '\\', '(', ')', '{', '}', ',' ]


span : (Char -> Bool) -> List Char -> ( List Char, List Char )
span keep chars =
    case chars of
        c :: rest ->
            if keep c then
                let
                    ( taken, remaining ) =
                        span keep rest
                in
                ( c :: taken, remaining )

            else
                ( [], chars )

        [] ->
            ( [], [] )
