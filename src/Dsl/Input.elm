module Dsl.Input exposing (Spec(..), defaultLiteral, parse, valueType)

{-| The tiny language an input cell is written in.

    range 0 5000 default 1000
    select "north" "south" "east" default "north"

An input is a graph node with no compile step of its own: its value is bound
to the cell's name, and a query that mentions that name depends on it. Moving
the control re-runs exactly what reads it.

-}

import Dsl.Ast exposing (Literal(..))
import Dsl.Schema exposing (Type(..))
import Parser exposing ((|.), (|=), Parser)


type Spec
    = Range { min : Float, max : Float, step : Float, default : Float }
    | Select { options : List String, default : String }


valueType : Spec -> Type
valueType widget =
    case widget of
        Range _ ->
            TFloat

        Select _ ->
            TString


defaultLiteral : Spec -> Literal
defaultLiteral widget =
    case widget of
        Range r ->
            LFloat r.default

        Select s ->
            LString s.default


parse : String -> Result String Spec
parse source =
    case Parser.run widgetSpec source of
        Ok parsed ->
            validate parsed

        Err _ ->
            Err "an input reads `range <min> <max> default <value>` or `select \"a\" \"b\" default \"a\"`"


widgetSpec : Parser Spec
widgetSpec =
    Parser.succeed identity
        |. ws
        |= Parser.oneOf [ range, select ]
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

        Select s ->
            if List.isEmpty s.options then
                Err "a select needs at least one option"

            else if not (List.member s.default s.options) then
                Err ("`" ++ s.default ++ "` is not one of this select's options")

            else
                Ok parsed


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


isSpace : Char -> Bool
isSpace c =
    c == ' ' || c == '\n' || c == '\r' || c == '\t'
