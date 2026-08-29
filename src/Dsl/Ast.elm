module Dsl.Ast exposing
    ( Constructor
    , Expr(..)
    , JoinKind(..)
    , Lambda2
    , Field
    , Lambda
    , Literal(..)
    , Op(..)
    , Pipeline
    , SortDir(..)
    , SortSpec
    , Stage(..)
    , TypeDecl
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
    , constructors : List Constructor
    }


type alias Constructor =
    { name : String
    , tag : String
    , payloadColumn : Maybe String
    }


type JoinKind
    = Inner
    | LeftOuter


type Stage
    = Filter Lambda
      -- `join customers (\o c -> o.customer_id == c.id)`. Two parameters,
      -- because the whole point is to say which side a column came from.
    | Join JoinKind String Lambda2
    | Map Lambda
    | GroupBy String
    | Reduce Lambda
    | SortBy SortSpec
    | Limit Int
    | Intersect String
    | Select
    | SelectAll


type alias SortSpec =
    { column : String
    , direction : SortDir
    }


type SortDir
    = Asc
    | Desc


type alias Lambda =
    { param : String
    , body : Expr
    }


type alias Lambda2 =
    { left : String
    , right : String
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
      -- `count g`, `sum g.total`. Only legal inside `reduce`.
    | Aggregate String Expr
      -- `o.status as Status`, the bridge from a column to a declared type.
    | Cast Expr String


type Literal
    = LInt Int
    | LFloat Float
    | LString String
    | LBool Bool


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
