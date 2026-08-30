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
            leading line
                + (if opensBlock line then
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


{-| Whether the next line belongs one step deeper than this one.

Brackets inside string literals do not count, or a URI with a brace in it
would drag everything after it sideways.

-}
opensBlock : String -> Bool
opensBlock line =
    let
        code =
            withoutStrings line
    in
    String.endsWith "->" (String.trimRight code) || depth code > 0


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


depth : String -> Int
depth code =
    String.foldl
        (\c total ->
            if Set.member c openers then
                total + 1

            else if Set.member c closers then
                total - 1

            else
                total
        )
        0
        code


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
