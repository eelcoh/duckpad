module Indent exposing (Edit, enter, shiftTab, tab)

{-| Keyboard editing for the cell textarea: what Enter and Tab should do.

Deliberately not an auto-formatter. The layout these cells are conventionally
written in is hand-aligned in the Elm style — the `{` of a record lines up
under the thing it belongs to, not at a multiple of two — and a rule that
tried to reproduce that would be wrong more often than it was right, and would
fight the author when it was.

What it does instead is never lose ground: a new line starts where the last
one did, one step deeper after a line that opens something, and Tab indents
instead of leaving the field. Going back out is Shift-Tab, which is explicit
rather than guessed.

-}

import Set


type alias Edit =
    { text : String
    , caret : Int
    }


step : Int
step =
    2



-- ENTER


{-| A new line at the caret, indented to match the line it came from, plus one
step if that line opened a bracket or ended in a lambda arrow.

Takes a range rather than a point because Enter with something selected
replaces it, the same as typing any other character would.

-}
enter : String -> Int -> Int -> Edit
enter original start end =
    let
        text =
            String.left start original ++ String.dropLeft end original

        caret =
            start

        before =
            String.left caret text

        line =
            currentLine before

        indent =
            case lastOpenColumn line of
                -- Elm puts the separators at the start of the line, so a
                -- record's `{`, its `,`s and its `}` all sit in the same
                -- column. Aligning to the opener is what makes the next line
                -- ready for a comma; the two characters of `, ` then carry the
                -- content across on their own.
                Just column ->
                    column

                Nothing ->
                    leading line
                        + (if endsWithArrow line then
                            step

                           else
                            0
                          )

        inserted =
            "\n" ++ String.repeat indent " "
    in
    { text = before ++ inserted ++ String.dropLeft caret text
    , caret = caret + String.length inserted
    }


currentLine : String -> String
currentLine before =
    case List.reverse (String.split "\n" before) of
        last :: _ ->
            last

        [] ->
            ""


leading : String -> Int
leading line =
    String.length line - String.length (String.trimLeft line)


endsWithArrow : String -> Bool
endsWithArrow line =
    String.endsWith "->" (String.trimRight (withoutStrings line))


withoutStrings : String -> String
withoutStrings line =
    String.foldl
        (\c ( acc, inString ) ->
            if c == '"' then
                ( acc, not inString )

            else if inString then
                ( acc, inString )

            else
                ( acc ++ String.fromChar c, inString )
        )
        ( "", False )
        line
        |> Tuple.first


{-| The column of the innermost bracket this line leaves open, if any.

Columns rather than a count, because the indent that follows is an alignment
and not a depth. Brackets inside string literals are skipped, or a URI with a
brace in it would drag everything after it sideways.

-}
lastOpenColumn : String -> Maybe Int
lastOpenColumn line =
    String.toList line
        |> List.foldl
            (\c ( column, inString, open ) ->
                if c == '"' then
                    ( column + 1, not inString, open )

                else if inString then
                    ( column + 1, inString, open )

                else if Set.member c openers then
                    ( column + 1, inString, column :: open )

                else if Set.member c closers then
                    ( column + 1, inString, List.drop 1 open )

                else
                    ( column + 1, inString, open )
            )
            ( 0, False, [] )
        |> (\( _, _, open ) -> List.head open)


openers : Set.Set Char
openers =
    Set.fromList [ '(', '{', '[' ]


closers : Set.Set Char
closers =
    Set.fromList [ ')', '}', ']' ]



-- TAB


{-| Tab indents. With a selection that covers more than one line it shifts the
whole block, which is the only reason to press it there.
-}
tab : String -> Int -> Int -> Edit
tab text start end =
    if spansLines text start end then
        shiftBlock indentLine text start end

    else
        { text = String.left start text ++ String.repeat step " " ++ String.dropLeft end text
        , caret = start + step
        }


shiftTab : String -> Int -> Int -> Edit
shiftTab text start end =
    shiftBlock outdentLine text start end


indentLine : String -> String
indentLine line =
    String.repeat step " " ++ line


outdentLine : String -> String
outdentLine line =
    let
        removable =
            min step (leading line)
    in
    String.dropLeft removable line


spansLines : String -> Int -> Int -> Bool
spansLines text start end =
    start /= end && String.contains "\n" (String.slice start end text)


{-| Apply a transformation to every line the selection touches, and keep the
selection covering the same lines afterwards.
-}
shiftBlock : (String -> String) -> String -> Int -> Int -> Edit
shiftBlock transform text start end =
    let
        blockStart =
            lineStart text start

        blockEnd =
            lineEnd text end

        shifted =
            String.slice blockStart blockEnd text
                |> String.split "\n"
                |> List.map transform
                |> String.join "\n"
    in
    { text = String.left blockStart text ++ shifted ++ String.dropLeft blockEnd text
    , caret = blockStart + String.length shifted
    }


lineStart : String -> Int -> Int
lineStart text pos =
    String.left pos text
        |> String.indexes "\n"
        |> List.reverse
        |> List.head
        |> Maybe.map ((+) 1)
        |> Maybe.withDefault 0


lineEnd : String -> Int -> Int
lineEnd text pos =
    String.indexes "\n" text
        |> List.filter (\i -> i >= pos)
        |> List.head
        |> Maybe.withDefault (String.length text)
