module Dsl.Schema exposing
    ( Schema
    , Type(..)
    , columnType
    , columnsOf
    , elmAnnotation
    , fromDuckDb
    , isNumeric
    , typeName
    )

{-| The type language, and the mapping from DuckDB's column types into it.

Deliberately small. Every type here has to survive three trips: out of DuckDB
as an Arrow value, across the port as JSON, and into an Elm annotation the
generated decoder can satisfy. A type that cannot make all three is not worth
having in the language.

-}

import Dict exposing (Dict)


type Type
    = TInt
    | TFloat
    | TString
    | TBool
    | TTimestamp
      -- A declared ADT. Carries only the name; the declaration itself lives in
      -- the AST, because codegen needs its constructors and the checker only
      -- needs to know the column has been claimed by one.
    | TCustom String
    | TMaybe Type


{-| Table name -> ordered columns. Base tables come from DuckDB; upstream cells
contribute the row type their own compilation produced.
-}
type alias Schema =
    Dict String (List ( String, Type ))


columnsOf : String -> Schema -> Maybe (List ( String, Type ))
columnsOf table schema =
    Dict.get table schema


columnType : String -> String -> Schema -> Maybe Type
columnType table column schema =
    columnsOf table schema
        |> Maybe.andThen
            (\cols ->
                cols
                    |> List.filter (\( name, _ ) -> name == column)
                    |> List.head
                    |> Maybe.map Tuple.second
            )


{-| DuckDB's `information_schema` spelling into our type language.

DECIMAL and friends collapse to Float: the notebook renders them and Elm has
no decimal type, so pretending otherwise would only move the lie later.

-}
fromDuckDb : String -> Maybe Type
fromDuckDb raw =
    case String.toUpper (String.trim raw) |> baseName of
        "BOOLEAN" ->
            Just TBool

        "TINYINT" ->
            Just TInt

        "SMALLINT" ->
            Just TInt

        "INTEGER" ->
            Just TInt

        "BIGINT" ->
            Just TInt

        "HUGEINT" ->
            Just TInt

        "UTINYINT" ->
            Just TInt

        "USMALLINT" ->
            Just TInt

        "UINTEGER" ->
            Just TInt

        "UBIGINT" ->
            Just TInt

        "FLOAT" ->
            Just TFloat

        "REAL" ->
            Just TFloat

        "DOUBLE" ->
            Just TFloat

        "DECIMAL" ->
            Just TFloat

        "NUMERIC" ->
            Just TFloat

        "VARCHAR" ->
            Just TString

        "TEXT" ->
            Just TString

        "STRING" ->
            Just TString

        "UUID" ->
            Just TString

        "TIMESTAMP" ->
            Just TTimestamp

        "TIMESTAMPTZ" ->
            Just TTimestamp

        "DATE" ->
            Just TTimestamp

        _ ->
            Nothing


{-| Strip the parameters off `DECIMAL(10,2)` and the like.
-}
baseName : String -> String
baseName raw =
    case String.split "(" raw of
        head :: _ ->
            String.trim head

        [] ->
            raw


typeName : Type -> String
typeName t =
    case t of
        TInt ->
            "Int"

        TFloat ->
            "Float"

        TString ->
            "String"

        TBool ->
            "Bool"

        TTimestamp ->
            "Timestamp"

        TCustom name ->
            name

        TMaybe inner ->
            "Maybe " ++ typeName inner


{-| How the type is written in generated Elm, which is not always how it is
written in a DSL error message: `Timestamp` is the language's name for what Elm
calls `Time.Posix`.
-}
elmAnnotation : Type -> String
elmAnnotation t =
    case t of
        TTimestamp ->
            "Time.Posix"

        TMaybe inner ->
            "Maybe " ++ parenthesised (elmAnnotation inner)

        _ ->
            typeName t


parenthesised : String -> String
parenthesised s =
    if String.contains " " s then
        "(" ++ s ++ ")"

    else
        s


isNumeric : Type -> Bool
isNumeric t =
    case t of
        TInt ->
            True

        TFloat ->
            True

        TMaybe inner ->
            isNumeric inner

        _ ->
            False
