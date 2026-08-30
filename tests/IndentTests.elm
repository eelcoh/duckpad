module IndentTests exposing (checks)

{-| Tests for what Enter and Tab do in a cell. The logic is small and entirely
about off-by-one positions, which is exactly the kind of thing that is easier
to pin than to re-derive.
-}

import Check exposing (Check, equal)
import Indent


checks : List Check
checks =
    enterChecks ++ tabChecks


{-| `‸` marks the caret in these fixtures, so a case reads as the thing being
typed rather than as a pair of integers. It has to be a character the language
never uses: `|` was the obvious choice and was wrong, because the pipeline
operator is full of them.
-}
at : String -> ( String, Int )
at marked =
    ( String.replace "‸" "" marked
    , String.indexes "‸" marked |> List.head |> Maybe.withDefault 0
    )


pressEnter : String -> String
pressEnter marked =
    let
        ( text, caret ) =
            at marked

        edit =
            Indent.enter text caret caret
    in
    String.left edit.caret edit.text ++ "‸" ++ String.dropLeft edit.caret edit.text


enterChecks : List Check
enterChecks =
    [ equal "enter: a new line keeps the indent of the one before it"
        "  |> filter x\n  ‸"
        (pressEnter "  |> filter x‸")
    , equal "enter: no indent to keep means none is added"
        "access t ()\n‸"
        (pressEnter "access t ()‸")
    , equal "enter: a line ending in a lambda arrow goes one step deeper"
        "  |> map (\\o ->\n    ‸"
        (pressEnter "  |> map (\\o ->‸")
    , equal "enter: an unclosed bracket goes one step deeper"
        "  |> reduce (\n    ‸"
        (pressEnter "  |> reduce (‸")
    , equal "enter: a bracket opened and closed on the same line does not"
        "  |> intersect .a b .c\n  ‸"
        (pressEnter "  |> intersect .a b .c‸")
    , equal "enter: a bracket inside a string is not a bracket"
        -- Otherwise a URI with a brace in it drags everything after it sideways.
        "csv \"https://x/a{b\"\n‸"
        (pressEnter "csv \"https://x/a{b\"‸")
    , equal "enter: splitting a line carries the rest along"
        "  one\n  ‸two"
        (pressEnter "  one‸two")
    , equal "enter: a selection is replaced, as typing anything else would"
        ( "  ab\n  c", 7 )
        (Indent.enter "  abXYc" 4 6 |> (\e -> ( e.text, e.caret )))
    , equal "enter: indent is measured from the line, not from the caret"
        "    deep\n    ‸"
        (pressEnter "    deep‸")
    ]


tabChecks : List Check
tabChecks =
    [ equal "tab: inserts a step at the caret"
        ( "  ab", 2 )
        (Indent.tab "ab" 0 0 |> (\e -> ( e.text, e.caret )))
    , equal "tab: replaces a selection inside one line"
        ( "a  c", 3 )
        (Indent.tab "abc" 1 2 |> (\e -> ( e.text, e.caret )))
    , equal "tab: a selection over several lines shifts all of them"
        "  one\n  two"
        (Indent.tab "one\ntwo" 0 7 |> .text)
    , equal "tab: shifting a block covers whole lines, not the part selected"
        "  one\n  two"
        (Indent.tab "one\ntwo" 1 5 |> .text)
    , equal "shift-tab: removes a step from the current line"
        "one"
        (Indent.shiftTab "  one" 2 2 |> .text)
    , equal "shift-tab: removes what it can when there is less than a step"
        "one"
        (Indent.shiftTab " one" 1 1 |> .text)
    , equal "shift-tab: a line with no indent is left alone"
        "one"
        (Indent.shiftTab "one" 0 0 |> .text)
    , equal "shift-tab: over several lines it dedents all of them"
        "one\ntwo"
        (Indent.shiftTab "  one\n  two" 0 11 |> .text)
    , equal "shift-tab: does not eat a line's text when it is short of a step"
        "a\nb"
        (Indent.shiftTab " a\n b" 0 5 |> .text)
    ]
