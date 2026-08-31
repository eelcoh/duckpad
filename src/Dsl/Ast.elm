module Dsl.Ast exposing
    ( ChartKind(..)
    , Constructor
    , CombineKind(..)
    , Definition(..)
    , Expr(..)
    , GroupKeys(..)
    , Pattern(..)
    , Field
    , Lambda
    , Literal(..)
    , Op(..)
    , Pipeline
    , SortDir(..)
    , SortSpec
    , Stage(..)
    , TypeDecl
    , UnpivotSpec
    , opSymbol
    )

{-| The surface syntax, straight off the page and not yet checked.

A cell is a sequence of type declarations followed by exactly one pipeline.
There is no way to write two pipelines in a cell, because a cell is one
binding: its value is the pipeline's result.

-}


type alias Pipeline =
    { declarations : List TypeDecl
    , source : String
    , stages : List Stage
    }


{-| An enum whose wire form is a string column.

    type Status
      = Submitted "submitted"
      | Delivered "delivered" from .delivered_at

Each constructor names the exact string it appears as in the data, so the
generated decoder can be exhaustive rather than guessing from the Elm name.
`from` points at a second column supplying that constructor's payload, which
is the case the Phase 2 spike had to write by hand.

-}
type alias TypeDecl =
    { name : String
    , definition : Definition
    }


{-| The two shapes a declared type can take.

An `Enum` is a closed set of values a text column holds. A wrapper is a single
constructor around one primitive — `type OrderId = OrderId Int` — which carries
no information the column did not already have, and exists so that an order id
cannot be handed to something expecting a customer id.

-}
type Definition
    = Enum (List Constructor)
    | Wraps String String


type alias Constructor =
    { name : String
    , tag : String
    , payloadColumn : Maybe String
    }


{-| How two collections of rows are combined.

Named after Acadia's own vocabulary rather than SQL's. All three take a key
extractor from each side, so they are equi-joins by construction: there is no
way to write a non-equi join, and therefore no way to write an accidental
cross product.

-}
type CombineKind
    = Intersect
    | Diff
    | Exclude
    | Union
    | XUnion


type ChartKind
    = Bar
    | Line
    | Scatter


type Stage
    = Filter Lambda
      -- `intersect .customer_id customers .id` — combine the rows so far with
      -- another table, matching on a key from each side.
    | Combine CombineKind String String String
    | Map Lambda
      -- One or more keys. Repeated accessors rather than a list, because the
      -- language has no list syntax and `intersect .a t .b` already reads
      -- this way.
    | GroupBy GroupKeys
    | Reduce Lambda
    | SortBy SortSpec
    | Limit Int
    | Select
    | SelectAll
      -- A chart is a terminator like `selectAll`: the cell's value is still
      -- its rows, and this says how to show them.
    | Chart ChartKind (List ( String, String ))
      -- A single number, shown as itself rather than as a table of one cell.
    | Scalar
      -- `summarize` — DuckDB's SUMMARIZE, one row per column of the input.
      -- Statically typeable where `PIVOT` is not: its output schema is fixed
      -- whatever it is pointed at.
    | Summarize
      -- `partitionBy .origin (asc .date)` — the OVER clause, named for what
      -- it does to the rows rather than for the SQL. Both halves are optional
      -- but not both at once: no keys means the whole table is one partition.
    | PartitionBy (List String) (Maybe SortSpec)
      -- `extend (\w -> { n = rowNumber w })` — the partner to `reduce`. Where
      -- a reduce collapses each group to one row, an extend keeps every row
      -- and adds what the window computed.
    | Extend Lambda
      -- `unpivot { name = month, value = sales } .jan .feb .mar` — fold a set
      -- of columns into two, one holding the old column's name and one its
      -- value. Unlike a pivot this is statically typeable, because both the
      -- columns folded and the columns produced are written down.
    | Unpivot UnpivotSpec (List String)


{-| How a `groupBy` names its keys.

Bare accessors for the common case, where the key is a column and takes its
name; a lambda when the key is computed, because then it needs a name of its
own and an expression to compute it — and a lambda is how every other stage
already writes one.

-}
type GroupKeys
    = ByColumns (List String)
    | ByExpressions Lambda


{-| What `unpivot` calls the two columns it produces.

A record rather than two positional names, for the reason `barChart` takes
one: both are bare identifiers, so positionally there would be nothing to
tell the reader which was which.

-}
type alias UnpivotSpec =
    { name : String
    , value : String
    }


type alias SortSpec =
    { column : String
    , direction : SortDir
    }


type SortDir
    = Asc
    | Desc


{-| What a lambda binds.

Before any combining a row has one side, and a lambda names it: `\o -> …`.
After combining it has several, and the lambda destructures them:
`\(o, c) -> …`. The arity has to match, which makes it impossible to forget
that a row has grown.

-}
type Pattern
    = Single String
    | Destructure (List String)


type alias Lambda =
    { pattern : Pattern
    , body : Expr
    }


type alias Field =
    { name : String
    , value : Expr
    }


type Expr
    = Lit Literal
      -- `o.total`, where `o` must be the enclosing lambda's parameter.
    | Access String String
      -- `{ a = ..., b = ... }`, the only shape `map` and `reduce` accept.
    | Record (List Field)
    | Binary Op Expr Expr
    | Not Expr
      -- A bare name. Only ever legal as an aggregate's argument (`count g`);
      -- anywhere else the checker rejects it, because a row has to be indexed
      -- by a column to mean anything.
    | Var String
      -- `count g`, `sum g.total`, `quantile 0.95 g.delay`. Only legal inside
      -- `reduce`. A list, because not every aggregate takes one column.
    | Aggregate String (List Expr)
      -- `round o.total`, `roundTo 1 g.avg`. Applied by juxtaposition, which
      -- binds tighter than any operator.
    | Call String (List Expr)
      -- `o.status as Status`, the bridge from a column to a declared type.
    | Cast Expr String


type Literal
    = LInt Int
    | LFloat Float
    | LString String
    | LBool Bool
      -- An ISO date, held as written. Not producible from the language itself;
      -- it is what a date input binds.
    | LTimestamp String


type Op
    = Eq
    | Neq
    | Lt
    | Lte
    | Gt
    | Gte
    | And
    | Or
    | Add
    | Sub
    | Mul
    | Div
    | Concat


opSymbol : Op -> String
opSymbol op =
    case op of
        Eq ->
            "=="

        Neq ->
            "/="

        Lt ->
            "<"

        Lte ->
            "<="

        Gt ->
            ">"

        Gte ->
            ">="

        And ->
            "&&"

        Or ->
            "||"

        Add ->
            "+"

        Sub ->
            "-"

        Mul ->
            "*"

        Div ->
            "/"

        Concat ->
            "++"
