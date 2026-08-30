module Dsl.Input exposing (Spec(..), defaultLiteral, optionSource, parse, valueType)

{-| The tiny language an input cell is written in.

    range 0 5000 default 1000
    select "north" "south" "east" default "north"

An input is a graph node with no compile step of its own: its value is bound
to the cell's name, and a query that mentions that name depends on it. Moving
the control re-runs exactly what reads it.

-}

import Dsl.Ast exposing (Literal(..))
import Dsl.Parser
import Dsl.Schema exposing (Type(..))
import Parser exposing ((|.), (|=), Parser)
import Set


type Spec
    = Range { min : Float, max : Float, step : Float, default : Float }
    | Select { options : List String, default : String }
      -- A single date. A *range* of dates is two of these, because a cell
      -- binds one value to its name and inventing a two-valued cell to avoid
      -- writing two would be the more complicated answer.
    | Date { min : String, max : String, default : String }
      -- A select whose options are a column of another cell. The cell is a
      -- dependency like any other, so it runs first and this reruns when it
      -- changes.
    | SelectFrom { cell : String, column : String, default : String }


valueType : Spec -> Type
valueType widget =
    case widget of
        Range _ ->
            TFloat

        Select _ ->
            TString

        Date _ ->
            TTimestamp

        SelectFrom _ ->
            TString


defaultLiteral : Spec -> Literal
defaultLiteral widget =
    case widget of
        Range r ->
            LFloat r.default

        Select s ->
            LString s.default

        Date d ->
            LTimestamp d.default

        SelectFrom s ->
            LString s.default


parse : String -> Result String Spec
parse source =
    case Parser.run widgetSpec source of
        Ok parsed ->
            validate parsed

        Err deadEnds ->
            Err
                (Dsl.Parser.describe source deadEnds
                    ++ "\n\nAn input is one of:\n"
                    ++ "    range <min> <max> [step <n>] default <n>\n"
                    ++ "    select \"a\" \"b\" default \"a\"\n"
                    ++ "    select from <cell> .<column> default \"a\"\n"
                    ++ "    date \"YYYY-MM-DD\" \"YYYY-MM-DD\" default \"YYYY-MM-DD\""
                )


widgetSpec : Parser Spec
widgetSpec =
    Parser.succeed identity
        |. ws
        |= Parser.oneOf [ range, selectFrom, select, date ]
        |. ws
        |. Parser.end


range : Parser Spec
range =
    Parser.succeed (\low high step_ default -> Range { min = low, max = high, step = step_, default = default })
        |. keyword "range"
        |= number
        |= number
        |= Parser.oneOf
            [ Parser.succeed identity |. keyword "step" |= number
            , Parser.succeed 0
            ]
        |. keyword "default"
        |= number


select : Parser Spec
select =
    Parser.succeed (\options default -> Select { options = options, default = default })
        |. keyword "select"
        |= someStrings
        |. keyword "default"
        |= string


{-| `select from by_state .state default "CA"`

Tried before the plain `select`, since both start with the same word and only
what follows tells them apart.

-}
selectFrom : Parser Spec
selectFrom =
    Parser.succeed (\cell column default -> SelectFrom { cell = cell, column = column, default = default })
        |. Parser.backtrackable (keyword "select")
        |. keyword "from"
        |= lowerName
        |. ws
        |. Parser.symbol "."
        |= lowerName
        |. ws
        |. keyword "default"
        |= string


lowerName : Parser String
lowerName =
    Parser.variable
        { start = Char.isLower
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = Set.empty
        }


{-| The cell an input reads its options from, if it reads any. This is what
puts it in the graph behind that cell.
-}
optionSource : Spec -> Maybe String
optionSource widget =
    case widget of
        SelectFrom s ->
            Just s.cell

        _ ->
            Nothing


date : Parser Spec
date =
    Parser.succeed (\low high default -> Date { min = low, max = high, default = default })
        |. keyword "date"
        |= string
        |= string
        |. keyword "default"
        |= string


someStrings : Parser (List String)
someStrings =
    Parser.loop [] <|
        \acc ->
            Parser.oneOf
                [ Parser.succeed (\s -> Parser.Loop (s :: acc)) |= string
                , Parser.succeed (Parser.Done (List.reverse acc))
                ]


{-| Whatever the author wrote has to make a usable control, and the checks are
the ones a reader would otherwise discover by dragging something that does
nothing.
-}
validate : Spec -> Result String Spec
validate parsed =
    case parsed of
        Range r ->
            if r.min >= r.max then
                Err "a range needs its smaller bound first"

            else if r.default < r.min || r.default > r.max then
                Err "a range's default has to sit between its bounds"

            else if r.step < 0 then
                Err "a range's step cannot be negative"

            else
                Ok
                    (Range
                        { r
                            | step =
                                if r.step == 0 then
                                    -- A hundred stops across the range is fine
                                    -- for dragging and keeps the value tidy.
                                    (r.max - r.min) / 100

                                else
                                    r.step
                        }
                    )

        Date d ->
            if not (List.all isoDate [ d.min, d.max, d.default ]) then
                Err "a date is written as \"YYYY-MM-DD\""

            else if d.min >= d.max then
                Err "a date range needs its earlier bound first"

            else if d.default < d.min || d.default > d.max then
                Err "a date's default has to sit between its bounds"

            else
                Ok parsed

        SelectFrom _ ->
            Ok parsed

        Select s ->
            if List.isEmpty s.options then
                Err "a select needs at least one option"

            else if not (List.member s.default s.options) then
                Err ("`" ++ s.default ++ "` is not one of this select's options")

            else
                Ok parsed


{-| ISO dates sort as text, which is why the bound checks above can simply
compare strings.
-}
isoDate : String -> Bool
isoDate value =
    case String.split "-" value of
        [ y, m, d ] ->
            (String.length y == 4)
                && (String.length m == 2)
                && (String.length d == 2)
                && List.all (String.all Char.isDigit) [ y, m, d ]

        _ ->
            False


keyword : String -> Parser ()
keyword word =
    Parser.succeed () |. Parser.keyword word |. ws


number : Parser Float
number =
    Parser.oneOf
        [ Parser.succeed negate |. Parser.symbol "-" |= magnitude
        , magnitude
        ]
        |. ws


magnitude : Parser Float
magnitude =
    Parser.number { int = Just toFloat, hex = Nothing, octal = Nothing, binary = Nothing, float = Just identity }


string : Parser String
string =
    Parser.succeed identity
        |. Parser.symbol "\""
        |= Parser.getChompedString (Parser.chompWhile (\c -> c /= '"'))
        |. Parser.symbol "\""
        |. ws


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


{-| A non-breaking space counts as whitespace here.

It is not whitespace to a parser and is indistinguishable from a space to a
reader, which makes it the worst kind of paste artefact: the line looks exactly
right and does not parse.

-}
isSpace : Char -> Bool
isSpace c =
    c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\u{00A0}'
