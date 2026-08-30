module DslTests exposing (checks)

{-| Tests for the DSL front end: parsing, checking, and the two codegen
targets.
-}

import Check exposing (Check, assert, equal, isErr)
import Dict
import Dsl.Ast exposing (..)
import Dsl.Check exposing (Cardinality(..))
import Dsl.Compile
import Dsl.Parser
import Dsl.Schema exposing (Schema, Type(..))


checks : List Check
checks =
    parserChecks ++ checkerChecks ++ sqlChecks ++ elmChecks ++ readsChecks ++ joinChecks ++ keywordFieldChecks ++ chartChecks ++ functionChecks


{-| The fixture schema every checker test runs against. `delivered_at` is
nullable on purpose: it is the column a constructor payload is drawn from, and
it is null for every row that is not delivered.
-}
schema : Schema
schema =
    Dict.fromList
        [ ( "orders"
          , [ ( "id", TInt )
            , ( "owner", TString )
            , ( "region", TString )
            , ( "status", TString )
            , ( "delivered_at", TMaybe TTimestamp )
            , ( "total", TFloat )
            ]
          )
        , ( "vips", [ ( "owner", TString ) ] )
        , ( "regions", [ ( "region", TString ) ] )

        -- Shares `owner` with orders, so an equi-join on it becomes USING.
        , ( "customers", [ ( "owner", TString ), ( "tier", TString ) ] )

        -- Shares nothing, so a join has to be written as ON.
        , ( "people", [ ( "person", TString ), ( "rank", TInt ) ] )

        -- Shares `region` as well as `owner`, which no join can merge.
        , ( "owners", [ ( "owner", TString ), ( "region", TString ) ] )
        ]


compile : String -> Result String Dsl.Compile.Compiled
compile =
    Dsl.Compile.compile schema Dict.empty "Generated"


rowTypeOf : String -> Result String (List ( String, String ))
rowTypeOf source =
    compile source
        |> Result.map (.rowType >> List.map (\( n, t ) -> ( n, Dsl.Schema.typeName t )))


sqlOf : String -> Result String String
sqlOf source =
    compile source |> Result.map .sql


elmOf : String -> Result String String
elmOf source =
    compile source |> Result.map .elmModule


contains : String -> String -> Result String String -> Check
contains name needle result =
    case result of
        Err e ->
            { name = name, ok = False, detail = "compilation failed: " ++ e }

        Ok text ->
            { name = name
            , ok = String.contains needle text
            , detail =
                if String.contains needle text then
                    ""

                else
                    "expected to find:\n      " ++ needle ++ "\n    in:\n" ++ text
            }


ok : String -> Result String Pipeline
ok =
    Dsl.Parser.parse


{-| Most tests only care about the stages, not the boilerplate around them.
-}
stagesOf : String -> Result String (List Stage)
stagesOf source =
    Dsl.Parser.parse source |> Result.map .stages


bodyOf : String -> Result String Expr
bodyOf source =
    stagesOf source
        |> Result.andThen
            (\stages ->
                case stages of
                    (Filter l) :: _ ->
                        Ok l.body

                    (Map l) :: _ ->
                        Ok l.body

                    (Reduce l) :: _ ->
                        Ok l.body

                    _ ->
                        Err "no lambda stage"
            )


filterExpr : String -> Result String Expr
filterExpr body =
    bodyOf ("access t ()\n  |> filter (\\o -> " ++ body ++ ")")


parserChecks : List Check
parserChecks =
    [ equal "parse: bare source and terminator"
        (Ok { declarations = [], source = "orders", stages = [ SelectAll ] })
        (ok "access orders () |> selectAll")
    , equal "parse: selectAll is not read as select followed by junk"
        (Ok [ SelectAll ])
        (stagesOf "access t () |> selectAll")
    , equal "parse: select is its own terminator"
        (Ok [ Select ])
        (stagesOf "access t () |> select")
    , equal "parse: a pipeline spanning several lines"
        (Ok [ Filter { pattern = Single "o", body = Binary Gt (Access "o" "total") (Lit (LInt 100)) }, SelectAll ])
        (stagesOf "access orders ()\n  |> filter (\\o -> o.total > 100)\n  |> selectAll")
    , equal "parse: line comments are ignored"
        (Ok [ SelectAll ])
        (stagesOf "-- a note\naccess t () -- trailing\n  |> selectAll")

    -- Operator handling is where a hand-rolled expression grammar usually
    -- breaks, so each hazard gets its own case.
    , equal "parse: division is not mistaken for inequality"
        (Ok (Binary Div (Access "o" "a") (Access "o" "b")))
        (filterExpr "o.a / o.b")
    , equal "parse: inequality is not mistaken for division"
        (Ok (Binary Neq (Access "o" "a") (Access "o" "b")))
        (filterExpr "o.a /= o.b")
    , equal "parse: <= is one token, not < then ="
        (Ok (Binary Lte (Access "o" "a") (Lit (LInt 3))))
        (filterExpr "o.a <= 3")
    , equal "parse: multiplication binds tighter than addition"
        (Ok (Binary Add (Access "o" "a") (Binary Mul (Access "o" "b") (Lit (LInt 2)))))
        (filterExpr "o.a + o.b * 2")
    , equal "parse: comparison binds looser than arithmetic"
        (Ok (Binary Gt (Binary Add (Access "o" "a") (Access "o" "b")) (Lit (LInt 10))))
        (filterExpr "o.a + o.b > 10")
    , equal "parse: && binds looser than comparison"
        (Ok
            (Binary And
                (Binary Gt (Access "o" "a") (Lit (LInt 1)))
                (Binary Lt (Access "o" "b") (Lit (LInt 2)))
            )
        )
        (filterExpr "o.a > 1 && o.b < 2")
    , equal "parse: || binds looser than &&"
        (Ok
            (Binary Or
                (Binary And (Access "o" "a") (Access "o" "b"))
                (Access "o" "c")
            )
        )
        (filterExpr "o.a && o.b || o.c")
    , equal "parse: subtraction is left-associative"
        (Ok (Binary Sub (Binary Sub (Access "o" "a") (Access "o" "b")) (Access "o" "c")))
        (filterExpr "o.a - o.b - o.c")
    , equal "parse: parentheses override precedence"
        (Ok (Binary Mul (Binary Add (Access "o" "a") (Access "o" "b")) (Lit (LInt 2))))
        (filterExpr "(o.a + o.b) * 2")
    , equal "parse: not applies to the operand, not the comparison"
        (Ok (Binary And (Not (Access "o" "flag")) (Access "o" "other")))
        (filterExpr "not o.flag && o.other")
    , equal "parse: string and boolean literals"
        (Ok (Binary Or (Binary Eq (Access "o" "s") (Lit (LString "hi"))) (Lit (LBool True))))
        (filterExpr "o.s == \"hi\" || true")
    , equal "parse: float and negative literals"
        (Ok (Binary Lt (Access "o" "x") (Lit (LFloat -1.5))))
        (filterExpr "o.x < -1.5")

    -- Records, aggregates, and the remaining stages.
    , equal "parse: map builds a record"
        (Ok
            [ Map
                { pattern = Single "o"
                , body =
                    Record
                        [ { name = "who", value = Access "o" "owner" }
                        , { name = "amount", value = Access "o" "total" }
                        ]
                }
            , SelectAll
            ]
        )
        (stagesOf "access t () |> map (\\o -> { who = o.owner, amount = o.total }) |> selectAll")
    , equal "parse: groupBy takes several accessors"
        (Ok [ GroupBy (ByColumns [ "origin", "destination" ]) ])
        (stagesOf "access t () |> groupBy .origin .destination")
    , equal "parse: groupBy takes an accessor"
        (Ok [ GroupBy (ByColumns [ "region" ]), SelectAll ])
        (stagesOf "access t () |> groupBy .region |> selectAll")
    , equal "parse: aggregates over the group and over a column"
        (Ok
            [ Reduce
                { pattern = Single "g"
                , body =
                    Record
                        [ { name = "n", value = Aggregate "count" (Var "g") }
                        , { name = "revenue", value = Aggregate "sum" (Access "g" "total") }
                        ]
                }
            ]
        )
        (stagesOf "access t () |> reduce (\\g -> { n = count g, revenue = sum g.total })")
    , equal "parse: sortBy defaults to ascending"
        (Ok [ SortBy { column = "total", direction = Asc } ])
        (stagesOf "access t () |> sortBy .total")
    , equal "parse: sortBy takes an explicit direction"
        (Ok [ SortBy { column = "revenue", direction = Desc } ])
        (stagesOf "access t () |> sortBy (desc .revenue)")
    , equal "parse: limit"
        (Ok [ Limit 10 ])
        (stagesOf "access t () |> limit 10")
    , equal "parse: a cast on a column"
        (Ok (Cast (Access "o" "status") "Status"))
        (bodyOf "access t () |> map (\\o -> o.status as Status)")

    -- Type declarations.
    , equal "parse: an enum declaration with wire tags"
        (Ok
            [ { name = "Status"
              , constructors =
                    [ { name = "Submitted", tag = "submitted", payloadColumn = Nothing }
                    , { name = "InTransit", tag = "in_transit", payloadColumn = Nothing }
                    ]
              }
            ]
        )
        (Dsl.Parser.parse "type Status\n  = Submitted \"submitted\"\n  | InTransit \"in_transit\"\n\naccess t () |> selectAll"
            |> Result.map .declarations
        )
    , equal "parse: a constructor can draw its payload from another column"
        (Ok (Just "delivered_at"))
        (Dsl.Parser.parse "type S = Delivered \"delivered\" from .delivered_at\naccess t () |> selectAll"
            |> Result.map .declarations
            |> Result.map (List.concatMap .constructors)
            |> Result.andThen
                (\cs ->
                    case cs of
                        c :: _ ->
                            Ok c.payloadColumn

                        [] ->
                            Err "no constructors"
                )
        )
    , equal "parse: several declarations precede the pipeline"
        (Ok 2)
        (Dsl.Parser.parse "type A = X \"x\"\ntype B = Y \"y\"\naccess t () |> selectAll"
            |> Result.map (.declarations >> List.length)
        )

    -- Failures should be failures, not silent successes.
    , isErr "parse: a pipeline must have a source"
        (ok "|> selectAll")
    , isErr "parse: an unclosed paren is rejected"
        (ok "access t () |> filter (\\o -> o.a > 1")
    , isErr "parse: an unknown operator is rejected"
        (filterExpr "o.a <> o.b")
    , isErr "parse: trailing junk after the pipeline is rejected"
        (ok "access t () |> selectAll garbage")
    , isErr "parse: a stage must follow the pipe"
        (ok "access t () |> ")
    ]


-- CHECKER


checkerChecks : List Check
checkerChecks =
    [ isErr "check: an unknown source table is rejected"
        (compile "access nope () |> selectAll")
    , isErr "check: an unknown column is rejected"
        (compile "access orders () |> filter (\\o -> o.nope > 1) |> selectAll")
    , isErr "check: a lambda cannot reach a name it did not bind"
        (compile "access orders () |> filter (\\o -> x.total > 1) |> selectAll")
    , isErr "check: filter needs a condition, not a value"
        (compile "access orders () |> filter (\\o -> o.total) |> selectAll")
    , isErr "check: a string cannot be compared with a number"
        (compile "access orders () |> filter (\\o -> o.owner > 1) |> selectAll")
    , isErr "check: a pipeline must terminate"
        (compile "access orders () |> filter (\\o -> o.total > 1)")
    , isErr "check: nothing may follow the terminator"
        (compile "access orders () |> selectAll |> limit 5")
    , isErr "check: a row is not a value on its own"
        (compile "access orders () |> filter (\\o -> o) |> selectAll")
    , equal "check: with no projection the row type is the source table"
        (Ok
            [ ( "id", "Int" )
            , ( "owner", "String" )
            , ( "region", "String" )
            , ( "status", "String" )
            , ( "delivered_at", "Maybe Timestamp" )
            , ( "total", "Float" )
            ]
        )
        (rowTypeOf "access orders () |> selectAll")
    , equal "check: map determines the row type"
        (Ok [ ( "who", "String" ), ( "amount", "Float" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { who = o.owner, amount = o.total }) |> selectAll")
    , equal "check: arithmetic on an Int and a Float widens to Float"
        (Ok [ ( "x", "Float" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { x = o.id + o.total }) |> selectAll")
    , equal "check: division always yields a Float"
        (Ok [ ( "x", "Float" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { x = o.id / o.id }) |> selectAll")
    , isErr "check: a projection cannot name a column twice"
        (compile "access orders () |> map (\\o -> { a = o.id, a = o.total }) |> selectAll")
    , isErr "check: a projection cannot be empty"
        (compile "access orders () |> map (\\o -> { }) |> selectAll")
    , isErr "check: map must produce a record"
        (compile "access orders () |> map (\\o -> o.total) |> selectAll")

    -- Grouping. The rule the checker exists to enforce.
    , isErr "check: an aggregate outside reduce is rejected"
        (compile "access orders () |> map (\\o -> { n = count o }) |> selectAll")
    , equal "check: reduce with no groupBy reduces the whole table"
        (Ok [ ( "n", "Int" ), ( "spend", "Float" ) ])
        (rowTypeOf "access orders () |> reduce (\\g -> { n = count g, spend = sum g.total }) |> selectAll")
    , equal "sql: a global reduce has no GROUP BY at all"
        (Ok "SELECT count(*) AS \"n\"\nFROM \"orders\" AS \"orders\"")
        (sqlOf "access orders () |> reduce (\\g -> { n = count g }) |> selectAll")
    , isErr "check: a global reduce still has to aggregate every column"
        -- With no GROUP BY there is no key to be an exception, so this is the
        -- same rule stated at its limit.
        (compile "access orders () |> reduce (\\g -> { o = g.owner }) |> selectAll")
    , isErr "check: reduce cannot follow a projection"
        (compile "access orders () |> map (\\o -> { a = o.total }) |> reduce (\\g -> { n = count g }) |> selectAll")
    , isErr "check: a non-key column in reduce must be aggregated"
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { o = g.owner }) |> selectAll")
    , equal "check: the grouping key may be used bare in reduce"
        (Ok [ ( "region", "String" ), ( "n", "Int" ), ( "revenue", "Float" ) ])
        (rowTypeOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g, revenue = sum g.total }) |> selectAll")
    , equal "check: avg widens an Int column to Float"
        (Ok [ ( "a", "Float" ) ])
        (rowTypeOf "access orders () |> groupBy .region |> reduce (\\g -> { a = avg g.id }) |> selectAll")
    , equal "check: min keeps its column's type"
        (Ok [ ( "m", "String" ) ])
        (rowTypeOf "access orders () |> groupBy .region |> reduce (\\g -> { m = min g.owner }) |> selectAll")
    , isErr "check: sum needs a number"
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { s = sum g.owner }) |> selectAll")
    -- Computed keys: the case that makes a time series expressible.
    , equal "group: a lambda names each key itself"
        (Ok [ ( "day", "Timestamp" ), ( "n", "Int" ) ])
        (rowTypeOf "access orders () |> groupBy (\\o -> { day = startOfDay o.delivered_at }) |> reduce (\\g -> { day = g.day, n = count g }) |> selectAll")
    , contains "sql: a computed key is grouped by its expression, not an alias"
        "GROUP BY date_trunc('day', \"orders\".\"delivered_at\")"
        (sqlOf "access orders () |> groupBy (\\o -> { day = startOfDay o.delivered_at }) |> reduce (\\g -> { day = g.day, n = count g }) |> selectAll")
    , contains "sql: reading the key inlines the expression again"
        "date_trunc('day', \"orders\".\"delivered_at\") AS \"day\""
        (sqlOf "access orders () |> groupBy (\\o -> { day = startOfDay o.delivered_at }) |> reduce (\\g -> { day = g.day, n = count g }) |> selectAll")
    , equal "group: several computed keys"
        (Ok [ ( "y", "Int" ), ( "m", "Int" ), ( "n", "Int" ) ])
        (rowTypeOf "access orders () |> groupBy (\\o -> { y = year o.delivered_at, m = month o.delivered_at }) |> reduce (\\g -> { y = g.y, m = g.m, n = count g }) |> selectAll")
    , isErr "group: a name that is not a key still has to be aggregated"
        (compile "access orders () |> groupBy (\\o -> { day = startOfDay o.delivered_at }) |> reduce (\\g -> { o = g.owner }) |> selectAll")
    , isErr "group: the original column is not a key once it has been transformed"
        (compile "access orders () |> groupBy (\\o -> { day = startOfDay o.delivered_at }) |> reduce (\\g -> { d = g.delivered_at }) |> selectAll")
    , isErr "group: a lambda has to produce a record"
        (compile "access orders () |> groupBy (\\o -> o.region) |> reduce (\\g -> { n = count g }) |> selectAll")
    , isErr "group: naming two keys the same is refused"
        (compile "access orders () |> groupBy (\\o -> { a = o.region, a = o.status }) |> reduce (\\g -> { a = g.a }) |> selectAll")
    , equal "check: grouping by two columns keeps both in the row type"
        (Ok [ ( "region", "String" ), ( "status", "String" ), ( "n", "Int" ) ])
        (rowTypeOf "access orders () |> groupBy .region .status |> reduce (\\g -> { region = g.region, status = g.status, n = count g }) |> selectAll")
    , contains "sql: several grouping keys are all in the GROUP BY"
        "GROUP BY \"orders\".\"region\", \"orders\".\"status\""
        (sqlOf "access orders () |> groupBy .region .status |> reduce (\\g -> { region = g.region, status = g.status, n = count g }) |> selectAll")
    , isErr "check: a column that is not any of the keys still has to be aggregated"
        (compile "access orders () |> groupBy .region .status |> reduce (\\g -> { o = g.owner }) |> selectAll")
    , isErr "check: grouping twice by the same column is a slip, not a no-op"
        (compile "access orders () |> groupBy .region .region |> reduce (\\g -> { r = g.region }) |> selectAll")
    , isErr "check: groupBy needs at least one key"
        (compile "access orders () |> groupBy |> reduce (\\g -> { n = count g }) |> selectAll")
    -- Filtering after a projection: HAVING when there was a grouping, an
    -- ordinary WHERE when there was not.
    , contains "sql: filtering a reduced row becomes HAVING"
        "HAVING (count(*) > 100)"
        (sqlOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g }) |> filter (\\r -> r.n > 100) |> selectAll")
    , contains "sql: HAVING inlines the aggregate, not the alias it is selected under"
        "HAVING (sum(\"orders\".\"total\") > 500)"
        (sqlOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, revenue = sum g.total }) |> filter (\\r -> r.revenue > 500) |> selectAll")
    , contains "sql: filtering a mapped row with no grouping is a WHERE"
        "WHERE ((\"orders\".\"total\" * 2) > 100)"
        (sqlOf "access orders () |> map (\\o -> { doubled = o.total * 2 }) |> filter (\\r -> r.doubled > 100) |> selectAll")
    , equal "check: filtering after a reduce does not change the row type"
        (Ok [ ( "region", "String" ), ( "n", "Int" ) ])
        (rowTypeOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g }) |> filter (\\r -> r.n > 100) |> selectAll")
    , contains "sql: two filters after a reduce are conjoined into one HAVING"
        "HAVING ((count(*) > 100) AND (count(*) < 900))"
        (sqlOf "access orders () |> groupBy .region |> reduce (\\g -> { n = count g }) |> filter (\\r -> r.n > 100) |> filter (\\r -> r.n < 900) |> selectAll")
    , isErr "check: a filter after a projection can only see the projection"
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { n = count g }) |> filter (\\r -> r.owner > 1) |> selectAll")
    , isErr "check: filter still needs a condition"
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { n = count g }) |> filter (\\r -> r.n) |> selectAll")
    , isErr "check: filter after limit would be applied before it"
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { n = count g }) |> limit 5 |> filter (\\r -> r.n > 1) |> selectAll")
    , isErr "check: filter cannot sit between groupBy and reduce"
        (compile "access orders () |> groupBy .region |> filter (\\o -> o.total > 1) |> reduce (\\g -> { n = count g }) |> selectAll")
    , isErr "check: a filter with nothing projected yet has nothing to read"
        (compile "access orders () |> groupBy .region |> filter (\\o -> o.total > 1) |> selectAll")

    -- Casts and declarations.
    , equal "check: a cast gives the column a declared type"
        (Ok [ ( "owner", "String" ), ( "s", "Status" ) ])
        (rowTypeOf declaredStatus)
    , isErr "check: casting to an undeclared type is rejected"
        (compile "access orders () |> map (\\o -> { s = o.status as Nope }) |> selectAll")
    , isErr "check: a cast needs a text column"
        (compile "type S = A \"a\"\naccess orders () |> map (\\o -> { s = o.total as S }) |> selectAll")
    , isErr "check: a payload column has to exist"
        (compile "type S = A \"a\" from .nope\naccess orders () |> map (\\o -> { s = o.status as S }) |> selectAll")
    , isErr "check: two constructors cannot share a tag"
        (compile "type S = A \"x\" | B \"x\"\naccess orders () |> map (\\o -> { s = o.status as S }) |> selectAll")

    -- Sorting, limits, set operations, metadata.
    , isErr "check: sortBy must name an output column"
        (compile "access orders () |> map (\\o -> { a = o.total }) |> sortBy .total |> selectAll")
    , assert "check: sortBy may name a projection alias"
        (sqlOf "access orders () |> map (\\o -> { amount = o.total }) |> sortBy (desc .amount) |> selectAll"
            |> Result.map (String.contains "ORDER BY \"amount\" DESC")
            |> Result.withDefault False
        )
    , isErr "check: limit must be positive"
        (compile "access orders () |> limit 0 |> selectAll")
    , equal "check: selectAll is many rows"
        (Ok Many)
        (compile "access orders () |> selectAll" |> Result.map .cardinality)
    , equal "check: select is one row"
        (Ok One)
        (compile "access orders () |> select" |> Result.map .cardinality)
    , equal "check: a cell that never sorts has no significant order"
        (Ok False)
        (compile "access orders () |> selectAll" |> Result.map .orderSignificant)
    , equal "check: sorting makes the row order significant"
        (Ok True)
        (compile "access orders () |> sortBy .total |> selectAll" |> Result.map .orderSignificant)
    , equal "check: limiting makes the row order significant"
        (Ok True)
        (compile "access orders () |> limit 5 |> selectAll" |> Result.map .orderSignificant)
    ]


resultOk : Result e a -> Bool
resultOk r =
    case r of
        Ok _ ->
            True

        Err _ ->
            False


{-| The worked example the whole phase is aimed at: a declared type rebuilt
from a tag column, with one constructor drawing a payload from a sibling.
-}
declaredStatus : String
declaredStatus =
    """
type Status
  = Submitted "submitted"
  | InTransit "in_transit"
  | Delivered "delivered" from .delivered_at

access orders ()
  |> filter (\\o -> o.total > 100.0)
  |> map (\\o -> { owner = o.owner, s = o.status as Status })
  |> selectAll
"""



-- SQL CODEGEN


sqlChecks : List Check
sqlChecks =
    [ equal "sql: the simplest pipeline"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"")
        (sqlOf "access orders () |> selectAll")
    , equal "sql: filter becomes WHERE"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE (\"orders\".\"total\" > 100)")
        (sqlOf "access orders () |> filter (\\o -> o.total > 100) |> selectAll")
    , equal "sql: two filters are conjoined"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE ((\"orders\".\"total\" > 100) AND (\"orders\".\"owner\" = 'ada'))")
        (sqlOf "access orders () |> filter (\\o -> o.total > 100) |> filter (\\o -> o.owner == \"ada\") |> selectAll")
    , equal "sql: inequality uses the SQL spelling"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE (\"orders\".\"owner\" <> 'ada')")
        (sqlOf "access orders () |> filter (\\o -> o.owner /= \"ada\") |> selectAll")
    , equal "sql: map becomes an aliased projection"
        (Ok "SELECT \"orders\".\"owner\" AS \"who\", \"orders\".\"total\" AS \"amount\"\nFROM \"orders\" AS \"orders\"")
        (sqlOf "access orders () |> map (\\o -> { who = o.owner, amount = o.total }) |> selectAll")
    , equal "sql: groupBy and aggregates"
        (Ok "SELECT \"orders\".\"region\" AS \"region\", count(*) AS \"n\", sum(\"orders\".\"total\") AS \"revenue\"\nFROM \"orders\" AS \"orders\"\nGROUP BY \"orders\".\"region\"")
        (sqlOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g, revenue = sum g.total }) |> selectAll")
    , equal "sql: sort and limit"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nORDER BY \"total\" DESC\nLIMIT 5")
        (sqlOf "access orders () |> sortBy (desc .total) |> limit 5 |> selectAll")
    , equal "sql: a string literal is escaped, not interpolated"
        (Ok "SELECT *\nFROM \"orders\" AS \"orders\"\nWHERE (\"orders\".\"owner\" = 'it''s')")
        (sqlOf "access orders () |> filter (\\o -> o.owner == \"it's\") |> selectAll")
    , contains "sql: a cast selects the underlying tag column"
        "\"orders\".\"status\" AS \"s\""
        (sqlOf declaredStatus)
    , contains "sql: a payload column is selected even though it is not a field"
        "\"delivered_at\""
        (sqlOf declaredStatus)
    ]



-- ELM CODEGEN


elmChecks : List Check
elmChecks =
    [ contains "elm: the row alias mirrors the projection"
        "type alias Row =\n    { who : String\n    , amount : Float\n    }"
        (elmOf "access orders () |> map (\\o -> { who = o.owner, amount = o.total }) |> selectAll")
    , contains "elm: selectAll yields a list"
        "type alias Value =\n    List Row"
        (elmOf "access orders () |> selectAll")
    , contains "elm: select yields a Maybe"
        "type alias Value =\n    Maybe Row"
        (elmOf "access orders () |> select")
    , contains "elm: a decoder reads the projection's alias, not the source column"
        "(D.field \"d\" (D.nullable posix))"
        (elmOf "access orders () |> map (\\o -> { d = o.delivered_at }) |> selectAll")
    , contains "elm: the declared type is emitted with its payload"
        "type Status\n    = Submitted\n    | InTransit\n    | Delivered Time.Posix"
        (elmOf declaredStatus)
    , contains "elm: the tag decoder is parameterised by column"
        "statusFrom : String -> D.Decoder Status"
        (elmOf declaredStatus)
    , contains "elm: an unknown tag fails the decode"
        "D.fail (\"unknown Status: \" ++ other)"
        (elmOf declaredStatus)
    , contains "elm: the payload is read from the sibling column"
        "D.map Delivered (D.field \"delivered_at\" posix)"
        (elmOf declaredStatus)
    , contains "elm: the row decoder is assembled with andMap"
        "D.succeed Row\n        |> andMap"
        (elmOf declaredStatus)
    , assert "elm: Time is only imported when something needs it"
        (elmOf "access orders () |> map (\\o -> { a = o.owner }) |> selectAll"
            |> Result.map (\t -> not (String.contains "import Time" t))
            |> Result.withDefault False
        )
    ]



-- DEPENDENCY EXTRACTION


{-| What the notebook builds its graph from, before any schema exists.
-}
readsChecks : List Check
readsChecks =
    [ equal "reads: the source table"
        [ "orders" ]
        (Dsl.Compile.readsOf "access orders () |> selectAll")
    , equal "reads: combine targets count too"
        [ "orders", "customers" ]
        (Dsl.Compile.readsOf "access orders () |> intersect .owner customers .owner |> selectAll")
    , equal "reads: a cell that does not parse reads nothing"
        []
        (Dsl.Compile.readsOf "access orders () |> filter (")
    , equal "reads: a column named like a table is not a dependency"
        [ "orders" ]
        (Dsl.Compile.readsOf "access orders () |> map (\\o -> { vips = o.owner }) |> selectAll")
    , equal "reads: a string literal is not a dependency"
        [ "orders" ]
        (Dsl.Compile.readsOf "access orders () |> filter (\\o -> o.owner == \"vips\") |> selectAll")
    ]



-- COMBINING ROWS


{-| Acadia's vocabulary: `intersect` is an inner join, `diff` a left join,
`exclude` an anti-join. Each takes a key extractor from either side, so a
non-equi join cannot be written at all.
-}
joinChecks : List Check
joinChecks =
    [ equal "combine: intersect parses as key, table, key"
        (Ok [ Combine Intersect "owner" "customers" "owner", SelectAll ])
        (stagesOf "access orders () |> intersect .owner customers .owner |> selectAll")
    , equal "combine: diff and exclude are their own stages"
        (Ok [ Combine Diff "owner" "people" "person", Combine Exclude "owner" "vips" "owner" ])
        (stagesOf "access orders () |> diff .owner people .person |> exclude .owner vips .owner")

    -- Rows are paired, not merged, so a later lambda destructures them.
    , equal "combine: a combined row has to be destructured"
        (Ok [ ( "who", "String" ), ( "tier", "String" ) ])
        (rowTypeOf "access orders () |> intersect .owner customers .owner |> map (\\(o, c) -> { who = o.owner, tier = c.tier }) |> selectAll")
    , equal "combine: each side keeps its own namespace"
        -- `owner` exists on both sides. Under a flat merge that would be a
        -- collision; paired, it is simply two different columns.
        (Ok [ ( "a", "String" ), ( "b", "String" ) ])
        (rowTypeOf "access orders () |> intersect .owner owners .owner |> map (\\(o, w) -> { a = o.region, b = w.region }) |> selectAll")
    , equal "combine: diff makes the right side optional"
        (Ok [ ( "who", "String" ), ( "rank", "Maybe Int" ) ])
        (rowTypeOf "access orders () |> diff .owner people .person |> map (\\(o, p) -> { who = o.owner, rank = p.rank }) |> selectAll")
    , equal "combine: exclude adds no side, so the row is unchanged"
        (Ok [ ( "who", "String" ) ])
        (rowTypeOf "access orders () |> exclude .owner vips .owner |> map (\\o -> { who = o.owner }) |> selectAll")

    -- SQL.
    , contains "sql: intersect is an inner join on the two keys"
        "JOIN \"customers\" AS \"customers\" ON \"orders\".\"owner\" = \"customers\".\"owner\""
        (sqlOf "access orders () |> intersect .owner customers .owner |> map (\\(o, c) -> { t = c.tier }) |> selectAll")
    , contains "sql: diff is a left join"
        "LEFT JOIN \"people\" AS \"people\""
        (sqlOf "access orders () |> diff .owner people .person |> map (\\(o, p) -> { r = p.rank }) |> selectAll")
    , contains "sql: exclude is an anti-join in the where clause"
        "NOT EXISTS (SELECT 1 FROM \"vips\" AS \"vips\" WHERE \"vips\".\"owner\" = \"orders\".\"owner\")"
        (sqlOf "access orders () |> exclude .owner vips .owner |> map (\\o -> { w = o.owner }) |> selectAll")
    , contains "sql: a table combined with itself gets a distinct alias"
        "AS \"orders_2\""
        (sqlOf "access orders () |> intersect .owner orders .owner |> map (\\(a, b) -> { x = a.id, y = b.id }) |> selectAll")

    -- Scope and arity.
    , isErr "combine: a single name cannot read a combined row"
        (compile "access orders () |> intersect .owner customers .owner |> map (\\o -> { w = o.owner }) |> selectAll")
    , isErr "combine: the pattern's arity has to match the number of sides"
        (compile "access orders () |> intersect .owner customers .owner |> map (\\(o, c, x) -> { w = o.owner }) |> selectAll")
    , isErr "combine: destructuring a row that has one side is rejected"
        (compile "access orders () |> map (\\(o, c) -> { w = o.owner }) |> selectAll")
    , isErr "combine: a combined row must be projected before selecting"
        (compile "access orders () |> intersect .owner customers .owner |> selectAll")
    , isErr "combine: an unknown table is rejected"
        (compile "access orders () |> intersect .owner nowhere .owner |> selectAll")
    , isErr "combine: the right key has to be a column of the right table"
        (compile "access orders () |> intersect .owner customers .nope |> selectAll")
    , isErr "combine: keys of different types cannot match"
        (compile "access orders () |> intersect .owner people .rank |> selectAll")
    , isErr "combine: combining cannot follow a projection"
        (compile "access orders () |> map (\\o -> { a = o.owner }) |> intersect .a customers .owner |> selectAll")

    -- Downstream stages.
    , equal "combine: reduce resolves a column across sides"
        (Ok [ ( "tier", "String" ), ( "revenue", "Float" ) ])
        (rowTypeOf "access orders () |> intersect .owner customers .owner |> groupBy .tier |> reduce (\\g -> { tier = g.tier, revenue = sum g.total }) |> selectAll")
    , isErr "combine: an ambiguous column is refused rather than guessed"
        (compile "access orders () |> intersect .owner owners .owner |> groupBy .region |> reduce (\\g -> { r = g.region }) |> selectAll")
    , equal "combine: the combined table is a dependency"
        (Ok [ "orders", "customers" ])
        (compile "access orders () |> intersect .owner customers .owner |> map (\\(o, c) -> { t = c.tier }) |> selectAll"
            |> Result.map .reads
        )
    , equal "combine: combines chain"
        (Ok [ "orders", "customers", "people" ])
        (compile "access orders () |> intersect .owner customers .owner |> diff .tier people .person |> map (\\(o, c, p) -> { t = c.tier, r = p.rank }) |> selectAll"
            |> Result.map .reads
        )
    ]


-- KEYWORDS AS FIELD NAMES


{-| Real tables have columns called `from`, `to`, `type` and `select`. Those
are keywords of this language, but only where a keyword could appear — after
a dot, or naming a record field, there is nothing to confuse them with.
-}
keywordFieldChecks : List Check
keywordFieldChecks =
    [ equal "keywords: a column may be called `from`"
        (Ok (Access "o" "from"))
        (bodyOf "access t () |> map (\\o -> o.from)")
    , equal "keywords: a projection may name a field `from`"
        (Ok [ ( "from", "String" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { from = o.owner }) |> selectAll")
    , equal "keywords: a projection may name a field `select`"
        (Ok [ ( "select", "String" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { select = o.owner }) |> selectAll")
    , equal "keywords: an accessor stage takes one too"
        (Ok [ SortBy { column = "type", direction = Asc } ])
        (stagesOf "access t () |> sortBy .type")
    , isErr "keywords: but a lambda still cannot bind one"
        (Dsl.Parser.parse "access t () |> map (\\from -> { a = from.x }) |> selectAll")
    ]



-- DISPLAY VERBS


displayOf : String -> Result String Dsl.Check.Display
displayOf source =
    compile source |> Result.map .display


chartChecks : List Check
chartChecks =
    [ equal "chart: a chart is a terminator, and the value is still rows"
        (Ok Many)
        (compile "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g }) |> barChart { x = .region, y = .n }"
            |> Result.map .cardinality
        )
    , equal "chart: channels carry the column type the compiler worked out"
        -- Vega-Lite needs each channel annotated, and those annotations are
        -- normally hand-written and quietly wrong.
        (Ok (Dsl.Check.AsChart { kind = Bar, channels = [ ( "x", "region", TString ), ( "y", "n", TInt ) ] }))
        (displayOf "access orders () |> groupBy .region |> reduce (\\g -> { region = g.region, n = count g }) |> barChart { x = .region, y = .n }")
    , equal "scalar: one number, and exactly one row"
        (Ok ( Dsl.Check.AsScalar, One ))
        (compile "access orders () |> reduce (\\g -> { spend = sum g.total }) |> scalar"
            |> Result.map (\c -> ( c.display, c.cardinality ))
        )
    , isErr "scalar: more than one column is not a scalar"
        (compile "access orders () |> reduce (\\g -> { a = count g, b = sum g.total }) |> scalar")
    , isErr "scalar: nothing may follow it"
        (compile "access orders () |> reduce (\\g -> { a = count g }) |> scalar |> limit 2")
    , equal "chart: selectAll leaves the cell as rows"
        (Ok Dsl.Check.AsRows)
        (displayOf "access orders () |> selectAll")
    , assert "chart: a colour channel is allowed"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total, c = o.region }) |> lineChart { x = .a, y = .b, color = .c }"
            |> resultOk
        )
    , isErr "chart: a y that is not a number is refused, not drawn empty"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.region }) |> barChart { x = .a, y = .b }")
    , isErr "chart: scatter needs a number on both axes"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total }) |> scatter { x = .a, y = .b }")
    , isErr "chart: a channel has to name a column of the row"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total }) |> barChart { x = .nope, y = .b }")
    , isErr "chart: an unknown channel is refused"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total }) |> barChart { x = .a, y = .b, wobble = .a }")
    , isErr "chart: a chart needs a y"
        (compile "access orders () |> map (\\o -> { a = o.owner }) |> barChart { x = .a }")
    , isErr "chart: setting a channel twice is refused"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total }) |> barChart { x = .a, y = .b, y = .b }")
    , isErr "chart: nothing may follow a chart"
        (compile "access orders () |> map (\\o -> { a = o.owner, b = o.total }) |> barChart { x = .a, y = .b } |> limit 5")
    ]



-- SCALAR FUNCTIONS


functionChecks : List Check
functionChecks =
    [ equal "fn: applied by juxtaposition, and binding tighter than any operator"
        (Ok (Binary Add (Call "round" [ Access "o" "total" ]) (Lit (LInt 1))))
        (filterExpr "round o.total + 1")
    , equal "fn: a second argument is taken greedily"
        (Ok (Call "roundTo" [ Lit (LInt 1), Access "o" "total" ]))
        (bodyOf "access t () |> map (\\o -> roundTo 1 o.total)")
    , equal "fn: a parameter may share a function's name"
        -- Field access is tried first, so `round.x` is not a call.
        (Ok (Access "round" "x"))
        (bodyOf "access t () |> map (\\round -> round.x)")

    -- Result types are fixed by the checker, which is what lets a truncated
    -- timestamp reach a temporal axis and a rounded number count as an integer.
    , equal "fn: truncating a timestamp keeps it a timestamp"
        (Ok [ ( "d", "Timestamp" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { d = startOfDay o.delivered_at }) |> selectAll")
    , equal "fn: a component of a timestamp is a whole number"
        (Ok [ ( "y", "Int" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { y = year o.delivered_at }) |> selectAll")
    , equal "fn: rounding gives an integer, rounding to digits gives a float"
        (Ok [ ( "a", "Int" ), ( "b", "Float" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { a = round o.total, b = roundTo 1 o.total }) |> selectAll")
    , equal "fn: abs keeps the type it was given"
        (Ok [ ( "a", "Float" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { a = abs o.total }) |> selectAll")
    , equal "fn: ++ joins text"
        (Ok [ ( "label", "String" ) ])
        (rowTypeOf "access orders () |> map (\\o -> { label = o.owner ++ \" · \" ++ o.region }) |> selectAll")

    -- Refusals.
    , isErr "fn: a timestamp function needs a timestamp"
        (compile "access orders () |> map (\\o -> { y = year o.owner }) |> selectAll")
    , isErr "fn: a numeric function needs a number"
        (compile "access orders () |> map (\\o -> { a = round o.owner }) |> selectAll")
    , isErr "fn: a text function needs text"
        (compile "access orders () |> map (\\o -> { a = lower o.total }) |> selectAll")
    , isErr "fn: ++ does not join a number to text"
        (compile "access orders () |> map (\\o -> { a = o.owner ++ o.total }) |> selectAll")
    , isErr "fn: the wrong number of arguments is refused"
        (compile "access orders () |> map (\\o -> { a = round o.total o.total }) |> selectAll")
    , isErr "fn: roundTo takes the digits first"
        (compile "access orders () |> map (\\o -> { a = roundTo o.total 1 }) |> selectAll")

    , equal "fn: a function may wrap an aggregate"
        -- The reason this matters: an average comes back as
        -- 7.361030984637324, and rounding it is the difference between a
        -- readable table and a wall of digits.
        (Ok [ ( "d", "Float" ) ])
        (rowTypeOf "access orders () |> groupBy .region |> reduce (\\g -> { d = roundTo 1 (avg g.total) }) |> selectAll")
    , contains "sql: a function wrapping an aggregate nests the same way"
        "round(avg(\"orders\".\"total\"), 1)"
        (sqlOf "access orders () |> groupBy .region |> reduce (\\g -> { d = roundTo 1 (avg g.total) }) |> selectAll")
    , isErr "fn: an aggregate inside a function is still only legal in reduce"
        (compile "access orders () |> map (\\o -> { d = roundTo 1 (avg o.total) }) |> selectAll")

    -- SQL, where the casts matter: DuckDB's round returns a double.
    , contains "sql: truncation becomes date_trunc"
        "date_trunc('day', \"orders\".\"delivered_at\")"
        (sqlOf "access orders () |> map (\\o -> { d = startOfDay o.delivered_at }) |> selectAll")
    , contains "sql: round is cast, because the column type says integer"
        "CAST(round(\"orders\".\"total\") AS BIGINT)"
        (sqlOf "access orders () |> map (\\o -> { a = round o.total }) |> selectAll")
    , contains "sql: roundTo puts the digits second, as DuckDB wants them"
        "round(\"orders\".\"total\", 1)"
        (sqlOf "access orders () |> map (\\o -> { a = roundTo 1 o.total }) |> selectAll")
    , contains "sql: ++ becomes the SQL concatenation operator"
        "||"
        (sqlOf "access orders () |> map (\\o -> { a = o.owner ++ o.region }) |> selectAll")
    ]
