module Deps exposing (identifiers)

{-| Extract the bare identifiers mentioned by a cell's source.

This is deliberately syntactic rather than a real parse: the engine intersects
whatever comes back with the set of known cell names to derive graph edges, so
over-collecting (`select`, `from`) is harmless because no cell is named that,
while *under*-collecting would silently drop an edge and let a cell read a
stale table. When in doubt, collect it.

Comments and single-quoted string literals are skipped so that prose or data
mentioning a cell's name cannot invent a dependency. Double-quoted spans are
collected, because in SQL those are quoted identifiers.

-}

import Set exposing (Set)


type Scan
    = Normal
    | LineComment
    | BlockComment
    | InString
    | InQuotedIdent


identifiers : String -> Set String
identifiers src =
    scan (String.toList src) Normal [] Set.empty


scan : List Char -> Scan -> List Char -> Set String -> Set String
scan chars state current acc =
    case state of
        Normal ->
            case chars of
                [] ->
                    flush current acc

                '-' :: '-' :: rest ->
                    scan rest LineComment [] (flush current acc)

                '/' :: '*' :: rest ->
                    scan rest BlockComment [] (flush current acc)

                '\'' :: rest ->
                    scan rest InString [] (flush current acc)

                '"' :: rest ->
                    scan rest InQuotedIdent [] (flush current acc)

                c :: rest ->
                    if isIdentChar c then
                        scan rest Normal (c :: current) acc

                    else
                        scan rest Normal [] (flush current acc)

        LineComment ->
            case chars of
                [] ->
                    acc

                '\n' :: rest ->
                    scan rest Normal [] acc

                _ :: rest ->
                    scan rest LineComment [] acc

        BlockComment ->
            case chars of
                [] ->
                    acc

                '*' :: '/' :: rest ->
                    scan rest Normal [] acc

                _ :: rest ->
                    scan rest BlockComment [] acc

        InString ->
            case chars of
                [] ->
                    acc

                '\'' :: '\'' :: rest ->
                    scan rest InString [] acc

                '\'' :: rest ->
                    scan rest Normal [] acc

                _ :: rest ->
                    scan rest InString [] acc

        InQuotedIdent ->
            case chars of
                [] ->
                    flush current acc

                '"' :: rest ->
                    scan rest Normal [] (flush current acc)

                c :: rest ->
                    scan rest InQuotedIdent (c :: current) acc


flush : List Char -> Set String -> Set String
flush current acc =
    if List.isEmpty current then
        acc

    else
        Set.insert (String.fromList (List.reverse current)) acc


isIdentChar : Char -> Bool
isIdentChar c =
    Char.isAlphaNum c || c == '_'
