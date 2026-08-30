module Dsl.Parser exposing (parse)

{-| Source text to surface AST.

Lexeme style: every terminal consumes its own trailing whitespace, so no rule
has to think about leading space. Binary operators are read by maximal munch
into a flat list and only then folded by precedence, which keeps the grammar
free of the backtracking that `/` versus `/=` would otherwise force.

-}

import Dsl.Ast exposing (..)
import Dsl.Keywords
import Parser exposing ((|.), (|=), Parser)
import Set exposing (Set)


parse : String -> Result String Pipeline
parse source =
    case Parser.run pipeline source of
        Ok ast ->
            Ok ast

        Err deadEnds ->
            Err (describe source deadEnds)



-- WHITESPACE AND TOKENS


ws : Parser ()
ws =
    Parser.loop () <|
        \_ ->
            Parser.oneOf
                [ Parser.succeed (Parser.Loop ()) |. Parser.lineComment "--"
                , Parser.succeed (Parser.Loop ()) |. spaces1
                , Parser.succeed (Parser.Done ())
                ]


spaces1 : Parser ()
spaces1 =
    Parser.chompIf isSpace
        |. Parser.chompWhile isSpace


isSpace : Char -> Bool
isSpace c =
    c == ' ' || c == '\n' || c == '\r' || c == '\t'


sym : String -> Parser ()
sym s =
    Parser.succeed ()
        |. Parser.symbol s
        |. ws


kw : String -> Parser ()
kw s =
    Parser.succeed ()
        |. Parser.keyword s
        |. ws


reserved : Set String
reserved =
    Dsl.Keywords.reserved


{-| A field name, which may be a keyword.

After a dot, or on the left of `=` in a record, there is nothing a keyword
could be confused with. Excluding them there would mean the language simply
could not read a column called `from`, `to`, `type` or `select`, and real data
has all of those. Binding occurrences — lambda parameters, table names — stay
restricted, because those do sit where a keyword could appear.

-}
fieldName : Parser String
fieldName =
    Parser.variable
        { start = \c -> Char.isLower c || c == '_'
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = Set.empty
        }
        |. ws


lname : Parser String
lname =
    Parser.variable
        { start = Char.isLower
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = reserved
        }
        |. ws


uname : Parser String
uname =
    Parser.variable
        { start = Char.isUpper
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = Set.empty
        }
        |. ws


{-| One or more, where none would be a mistake worth reporting.
-}
some : Parser a -> Parser (List a)
some p =
    Parser.succeed (::)
        |= p
        |= many p


many : Parser a -> Parser (List a)
many p =
    Parser.loop [] <|
        \acc ->
            Parser.oneOf
                [ Parser.succeed (\x -> Parser.Loop (x :: acc)) |= p
                , Parser.succeed (Parser.Done (List.reverse acc))
                ]



-- PROGRAM


pipeline : Parser Pipeline
pipeline =
    Parser.succeed Pipeline
        |. ws
        |= many typeDecl
        |= accessClause
        |= many stage
        |. Parser.end


accessClause : Parser String
accessClause =
    Parser.succeed identity
        |. kw "access"
        |= lname
        |. sym "("
        |. sym ")"



-- TYPE DECLARATIONS


typeDecl : Parser TypeDecl
typeDecl =
    Parser.succeed TypeDecl
        |. kw "type"
        |= uname
        |. sym "="
        |= definition


{-| Both shapes start with a constructor name; what follows decides which.

A quoted tag makes it an enum, a type name makes it a wrapper. Nothing else
can appear there, so one token of lookahead settles it.

-}
definition : Parser Definition
definition =
    uname
        |> Parser.andThen
            (\first ->
                Parser.oneOf
                    [ Parser.map (Wraps first) uname
                    , Parser.succeed (\tag payload rest -> Enum (Constructor first tag payload :: rest))
                        |= quotedString
                        |= payloadColumn
                        |= many
                            (Parser.backtrackable
                                (Parser.succeed identity |. sym "|" |= constructor)
                            )
                    ]
            )


constructor : Parser Constructor
constructor =
    Parser.succeed Constructor
        |= uname
        |= quotedString
        |= payloadColumn


payloadColumn : Parser (Maybe String)
payloadColumn =
    Parser.oneOf
        [ Parser.succeed Just |. kw "from" |= accessor
        , Parser.succeed Nothing
        ]



-- STAGES


stage : Parser Stage
stage =
    Parser.succeed identity
        |. sym "|>"
        |= Parser.oneOf
            [ Parser.map Filter (lambdaStage "filter")
            , combineStage "intersect" Intersect
            , combineStage "diff" Diff
            , combineStage "exclude" Exclude
            , combineStage "union" Union
            , combineStage "xunion" XUnion
            , Parser.map Map (lambdaStage "map")
            , Parser.map Reduce (lambdaStage "reduce")
            , Parser.succeed GroupBy |. kw "groupBy" |= groupKeys
            , Parser.succeed SortBy |. kw "sortBy" |= sortSpec
            , Parser.succeed Limit |. kw "limit" |= (Parser.int |. ws)

            , Parser.succeed Scalar |. kw "scalar"
            , chartStage "barChart" Bar
            , chartStage "lineChart" Line
            , chartStage "scatter" Scatter

            -- `selectAll` first: `select` is a prefix of it.
            , Parser.succeed SelectAll |. kw "selectAll"
            , Parser.succeed Select |. kw "select"
            ]


{-| `intersect .customer_id customers .id`

Key extractor, table, key extractor — the same order Acadia writes it in,
with the left-hand rows supplied by the pipeline rather than named.

-}
combineStage : String -> CombineKind -> Parser Stage
combineStage name kind =
    Parser.succeed (Combine kind)
        |. kw name
        |= accessor
        |= lname
        |= accessor


groupKeys : Parser GroupKeys
groupKeys =
    Parser.oneOf
        [ Parser.succeed ByExpressions
            |. sym "("
            |= lambda
            |. sym ")"
        , Parser.map ByColumns (some accessor)
        ]


{-| `barChart { x = .origin, y = .flights }`

A record of channel names to accessors. Positional arguments would have
matched `groupBy .a .b`, but a chart has optional channels and there is no
reading order that stays clear once `color` is one of them.

-}
chartStage : String -> ChartKind -> Parser Stage
chartStage name kind =
    Parser.succeed (Chart kind)
        |. kw name
        |. sym "{"
        |= channels
        |. sym "}"


channels : Parser (List ( String, String ))
channels =
    Parser.succeed (::)
        |= channel
        |= many (Parser.succeed identity |. sym "," |= channel)


channel : Parser ( String, String )
channel =
    Parser.succeed Tuple.pair
        |= fieldName
        |. sym "="
        |= accessor


lambdaStage : String -> Parser Lambda
lambdaStage name =
    Parser.succeed identity
        |. kw name
        |. sym "("
        |= lambda
        |. sym ")"


lambda : Parser Lambda
lambda =
    Parser.succeed Lambda
        |. sym "\\"
        |= pattern
        |. sym "->"
        |= expr


pattern : Parser Pattern
pattern =
    Parser.oneOf
        [ Parser.succeed Destructure
            |. sym "("
            |= names
            |. sym ")"
        , Parser.map Single lname
        ]


names : Parser (List String)
names =
    Parser.succeed (::)
        |= lname
        |= many (Parser.succeed identity |. sym "," |= lname)


accessor : Parser String
accessor =
    Parser.succeed identity
        |. Parser.symbol "."
        |= fieldName


sortSpec : Parser SortSpec
sortSpec =
    Parser.oneOf
        [ Parser.succeed (\dir col -> SortSpec col dir)
            |. sym "("
            |= direction
            |= accessor
            |. sym ")"
        , Parser.map (\col -> SortSpec col Asc) accessor
        ]


direction : Parser SortDir
direction =
    Parser.oneOf
        [ Parser.succeed Desc |. kw "desc"
        , Parser.succeed Asc |. kw "asc"
        ]



-- EXPRESSIONS


expr : Parser Expr
expr =
    Parser.succeed resolve
        |= unary
        |= many operatorAndOperand


operatorAndOperand : Parser ( Op, Expr )
operatorAndOperand =
    Parser.succeed Tuple.pair
        |= knownOperator
        |= unary


{-| Maximal munch over the operator characters, then a table lookup.

Reading `/=` as one token is what stops the `/` of a division rule from
biting off half of an inequality and forcing the whole expression grammar to
backtrack.

-}
knownOperator : Parser Op
knownOperator =
    Parser.getChompedString (Parser.chompIf isOpChar |. Parser.chompWhile isOpChar)
        |. ws
        |> Parser.andThen
            (\token ->
                case lookupOp token of
                    Just op ->
                        Parser.succeed op

                    Nothing ->
                        Parser.problem ("unknown operator `" ++ token ++ "`")
            )


isOpChar : Char -> Bool
isOpChar c =
    List.member c [ '=', '/', '<', '>', '&', '|', '+', '-', '*' ]


lookupOp : String -> Maybe Op
lookupOp token =
    case token of
        "==" ->
            Just Eq

        "/=" ->
            Just Neq

        "<" ->
            Just Lt

        "<=" ->
            Just Lte

        ">" ->
            Just Gt

        ">=" ->
            Just Gte

        "&&" ->
            Just And

        "||" ->
            Just Or

        "+" ->
            Just Add

        "-" ->
            Just Sub

        "*" ->
            Just Mul

        "/" ->
            Just Div

        "++" ->
            Just Concat

        _ ->
            Nothing


precedence : Op -> Int
precedence op =
    case op of
        Or ->
            1

        And ->
            2

        Eq ->
            3

        Neq ->
            3

        Lt ->
            3

        Lte ->
            3

        Gt ->
            3

        Gte ->
            3

        Add ->
            4

        Sub ->
            4

        Concat ->
            4

        Mul ->
            5

        Div ->
            5


{-| Precedence climbing over the flat operator list. All operators here are
left-associative, hence the `+ 1` when recursing on the right.
-}
resolve : Expr -> List ( Op, Expr ) -> Expr
resolve first rest =
    Tuple.first (climb first rest 0)


climb : Expr -> List ( Op, Expr ) -> Int -> ( Expr, List ( Op, Expr ) )
climb lhs tokens minPrec =
    case tokens of
        [] ->
            ( lhs, [] )

        ( op, rhs ) :: rest ->
            if precedence op < minPrec then
                ( lhs, tokens )

            else
                let
                    ( folded, remaining ) =
                        gather rhs rest (precedence op + 1)
                in
                climb (Binary op lhs folded) remaining minPrec


gather : Expr -> List ( Op, Expr ) -> Int -> ( Expr, List ( Op, Expr ) )
gather rhs tokens minPrec =
    case tokens of
        ( op, _ ) :: _ ->
            if precedence op >= minPrec then
                climb rhs tokens minPrec

            else
                ( rhs, tokens )

        [] ->
            ( rhs, [] )


unary : Parser Expr
unary =
    Parser.oneOf
        [ Parser.succeed Not |. kw "not" |= Parser.lazy (\_ -> unary)
        , postfix
        ]


postfix : Parser Expr
postfix =
    atom
        |> Parser.andThen
            (\e ->
                Parser.oneOf
                    [ Parser.succeed (Cast e) |. kw "as" |= uname
                    , Parser.succeed e
                    ]
            )


atom : Parser Expr
atom =
    Parser.oneOf
        [ record
        , Parser.succeed (Lit (LBool True)) |. kw "true"
        , Parser.succeed (Lit (LBool False)) |. kw "false"
        , Parser.map (Lit << LString) quotedString
        , numberLiteral
        , Parser.succeed identity |. sym "(" |= Parser.lazy (\_ -> expr) |. sym ")"
        , identifierExpr
        ]


numberLiteral : Parser Expr
numberLiteral =
    Parser.oneOf
        [ Parser.succeed negateLiteral |. Parser.symbol "-" |= numberCore
        , numberCore
        ]


numberCore : Parser Expr
numberCore =
    Parser.number
        { int = Just (Lit << LInt)
        , hex = Nothing
        , octal = Nothing
        , binary = Nothing
        , float = Just (Lit << LFloat)
        }
        |. ws


negateLiteral : Expr -> Expr
negateLiteral e =
    case e of
        Lit (LInt n) ->
            Lit (LInt (negate n))

        Lit (LFloat f) ->
            Lit (LFloat (negate f))

        other ->
            other


{-| A name in expression position.

Field access is tried first, so a lambda parameter may be called `round` or
`month` without the name being read as a call. Only a bare name is a candidate
for one.

-}
identifierExpr : Parser Expr
identifierExpr =
    lname
        |> Parser.andThen
            (\name ->
                Parser.oneOf
                    [ Parser.succeed (Access name) |. Parser.symbol "." |= fieldName
                    , if isAggregate name then
                        Parser.map (Aggregate name) (many aggArg)

                      else if isFunction name then
                        Parser.map (Call name) (many argAtom)

                      else
                        Parser.succeed (Var name)
                    ]
            )


{-| What may follow an aggregate. Like a function's argument, but a bare name
is allowed too, because `count g` names the group itself.
-}
aggArg : Parser Expr
aggArg =
    Parser.oneOf
        [ Parser.map (Lit << LString) quotedString
        , numberLiteral
        , Parser.succeed identity |. sym "(" |= Parser.lazy (\_ -> expr) |. sym ")"
        , Parser.backtrackable (lname |> Parser.andThen fieldOrVar)
        ]


{-| What may follow a function name without parentheses. Application binds
tighter than every operator, so `round o.a + 1` is `(round o.a) + 1`.
-}
argAtom : Parser Expr
argAtom =
    Parser.oneOf
        [ Parser.map (Lit << LString) quotedString
        , numberLiteral
        , Parser.succeed identity |. sym "(" |= Parser.lazy (\_ -> expr) |. sym ")"
        , Parser.backtrackable
            (lname
                |> Parser.andThen
                    (\name ->
                        Parser.succeed (Access name) |. Parser.symbol "." |= fieldName
                    )
            )
        ]


fieldOrVar : String -> Parser Expr
fieldOrVar name =
    Parser.oneOf
        [ Parser.succeed (Access name) |. Parser.symbol "." |= fieldName
        , Parser.succeed (Var name)
        ]


isAggregate : String -> Bool
isAggregate name =
    Set.member name Dsl.Keywords.aggregates


isFunction : String -> Bool
isFunction name =
    Set.member name Dsl.Keywords.functions


record : Parser Expr
record =
    Parser.succeed Record
        |. sym "{"
        |= fields
        |. sym "}"


fields : Parser (List Field)
fields =
    Parser.oneOf
        [ Parser.succeed (::)
            |= field
            |= many (Parser.succeed identity |. sym "," |= field)
        , Parser.succeed []
        ]


field : Parser Field
field =
    Parser.succeed Field
        |= fieldName
        |. sym "="
        |= Parser.lazy (\_ -> expr)


quotedString : Parser String
quotedString =
    Parser.succeed identity
        |. Parser.symbol "\""
        |= Parser.getChompedString (Parser.chompWhile (\c -> c /= '"'))
        |. Parser.symbol "\""
        |. ws



-- ERRORS


describe : String -> List Parser.DeadEnd -> String
describe source deadEnds =
    case List.head deadEnds of
        Nothing ->
            "could not parse this cell"

        Just first ->
            let
                line =
                    String.lines source
                        |> List.drop (first.row - 1)
                        |> List.head
                        |> Maybe.withDefault ""
            in
            "line "
                ++ String.fromInt first.row
                ++ ", column "
                ++ String.fromInt first.col
                ++ ": "
                ++ expected deadEnds
                ++ "\n    "
                ++ String.trimRight line
                ++ "\n    "
                ++ String.repeat (max 0 (first.col - 1)) " "
                ++ "^"


expected : List Parser.DeadEnd -> String
expected deadEnds =
    let
        wanted =
            deadEnds
                |> List.filterMap problemText
                |> dedupe
    in
    case wanted of
        [] ->
            "unexpected input"

        [ one ] ->
            "expected " ++ one

        several ->
            "expected one of " ++ String.join ", " several


problemText : Parser.DeadEnd -> Maybe String
problemText deadEnd =
    case deadEnd.problem of
        Parser.Expecting s ->
            Just ("`" ++ s ++ "`")

        Parser.ExpectingSymbol s ->
            Just ("`" ++ s ++ "`")

        Parser.ExpectingKeyword s ->
            Just ("`" ++ s ++ "`")

        Parser.ExpectingInt ->
            Just "a whole number"

        Parser.ExpectingFloat ->
            Just "a number"

        Parser.ExpectingNumber ->
            Just "a number"

        Parser.ExpectingVariable ->
            Just "a name"

        Parser.ExpectingEnd ->
            Just "end of the cell"

        Parser.Problem s ->
            Just s

        _ ->
            Nothing


dedupe : List String -> List String
dedupe =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                acc ++ [ x ]
        )
        []
