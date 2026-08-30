module Dsl.Check exposing
    ( Cardinality(..)
    , ChartSpec
    , Params
    , Checked
    , CheckedCombine
    , Display(..)
    , Projection(..)
    , Side
    , TExpr(..)
    , check
    , typeOf
    )

{-| Surface AST plus a schema, into a typed IR.

Everything downstream reads this IR and nothing re-derives it: the SQL and the
Elm module are two renderings of one checked structure, so they cannot
disagree about what a column is called or what type it holds.

The shape a row takes after combining two tables is the design decision this
module is built around. Rows are **paired, not merged**: after
`intersect .customer_id customers .id` the row has two sides, and a later
lambda destructures them with `\(o, c) -> …`. Each side keeps its own
namespace, so two tables that both have an `id` need no renaming, no
qualification rule, and no collision error. The SQL renderer aliases the
tables and qualifies every column, which is what makes that work.

-}

import Dict
import Dsl.Ast as Ast exposing (..)
import Dsl.Schema as Schema exposing (Schema, Type(..))


type alias Checked =
    { source : String
    , sourceAlias : String
    , reads : List String
    , combines : List CheckedCombine
    , filter : Maybe TExpr
      -- What to GROUP BY. A plain column key is just its own column
      -- expression, so both kinds of key render the same way.
    , groupBy : List TExpr
    , having : Maybe TExpr
    , projection : Projection
    , hidden : List ( String, String, Type )
    , sort : Maybe SortSpec
    , limit : Maybe Int
    , cardinality : Cardinality
    , orderSignificant : Bool
    , rowType : List ( String, Type )
    , declarations : List TypeDecl
    , display : Display
    }


{-| How the cell's rows should be shown. Not part of the query: the SQL and
the Elm module are the same either way.
-}
type Display
    = AsRows
    | AsScalar
    | AsChart ChartSpec


type alias ChartSpec =
    { kind : ChartKind
    , channels : List ( String, String, Type )
    }


{-| One collection of rows in scope. A pipeline starts with one and gains
another for every `intersect` or `diff`.
-}
type alias Side =
    { alias : String
    , table : String
    , columns : List ( String, Type )
    }


type alias CheckedCombine =
    { kind : CombineKind
    , table : String
    , alias : String
    , leftAlias : String
    , leftKey : String
    , rightKey : String
    }


type Projection
    = All
    | Fields (List ( String, TExpr ))


type Cardinality
    = One
    | Many


type TExpr
    = TCol String String Type
    | TLit Literal Type
    | TBin Op TExpr TExpr Type
    | TNot TExpr
    | TAgg String (List TExpr) Type
    | TCall String (List TExpr) Type
    | TCast TExpr String


typeOf : TExpr -> Type
typeOf expr =
    case expr of
        TCol _ _ t ->
            t

        TLit _ t ->
            t

        TBin _ _ _ t ->
            t

        TNot _ ->
            TBool

        TAgg _ _ t ->
            t

        TCall _ _ t ->
            t

        TCast _ name ->
            TCustom name



-- ENTRY POINT


{-| Values bound by input cells, ready to be inlined.

Inlined rather than passed as query parameters, and that is the whole design:
moving a control changes the SQL, which changes the cell's cache key, which
re-runs exactly what depends on it. The reactive machinery needs no special
case for widgets at all.

-}
type alias Params =
    Dict.Dict String ( Type, Literal )


check : Schema -> Params -> Pipeline -> Result String Checked
check schema params ast =
    case Schema.columnsOf ast.source schema of
        Nothing ->
            Err ("`" ++ ast.source ++ "` is not a table or an earlier cell. Known: " ++ knownTables schema)

        Just columns ->
            validateDeclarations columns ast.declarations
                |> Result.andThen (\_ -> foldStages schema params ast (start ast.source columns))
                |> Result.andThen finish


knownTables : Schema -> String
knownTables schema =
    Dict.keys schema |> String.join ", "



-- BUILDER


type Phase
    = Rows
    | Grouped
    | Projected
    | Done


type alias Builder =
    { source : String
    , sides : List Side
    , combines : List CheckedCombine
    , phase : Phase
    , filter : Maybe TExpr
      -- Name to expression: the name is how `reduce` refers to the key, the
      -- expression is what the database groups by.
    , groupBy : List ( String, TExpr )
    , having : Maybe TExpr
    , projection : Projection
    , hidden : List ( String, String, Type )
    , sort : Maybe SortSpec
    , limit : Maybe Int
    , cardinality : Maybe Cardinality
    , declarations : List TypeDecl
    , display : Display
    }


start : String -> List ( String, Type ) -> Builder
start source columns =
    { source = source
    , sides = [ { alias = source, table = source, columns = columns } ]
    , combines = []
    , phase = Rows
    , filter = Nothing
    , groupBy = []
    , having = Nothing
    , projection = All
    , hidden = []
    , sort = Nothing
    , limit = Nothing
    , cardinality = Nothing
    , declarations = []
    , display = AsRows
    }


foldStages : Schema -> Params -> Pipeline -> Builder -> Result String Builder
foldStages schema params ast builder =
    List.foldl
        (\stage acc -> Result.andThen (applyStage schema params ast stage) acc)
        (Ok { builder | declarations = ast.declarations })
        ast.stages


applyStage : Schema -> Params -> Pipeline -> Stage -> Builder -> Result String Builder
applyStage schema params ast stage builder =
    case ( stage, builder.phase ) of
        ( _, Done ) ->
            Err "nothing may follow `select` or `selectAll` — the pipeline ends there"

        ( Filter lambda, Rows ) ->
            bind params ast builder lambda
                |> Result.andThen (\env -> checkExpr env lambda.body)
                |> Result.andThen
                    (\texpr ->
                        if Schema.typeName (typeOf texpr) == "Bool" then
                            Ok { builder | filter = Just (conjoin builder.filter texpr) }

                        else
                            Err ("`filter` needs a condition, but this expression is a " ++ Schema.typeName (typeOf texpr))
                    )

        ( Filter lambda, Projected ) ->
            filterProjected params ast lambda builder

        ( Filter _, Grouped ) ->
            Err "`filter` cannot sit between `groupBy` and `reduce` — put it before the `groupBy` to filter rows, or after the `reduce` to filter groups"

        ( Combine kind leftKey table rightKey, Rows ) ->
            combine schema kind leftKey table rightKey builder

        ( Combine _ _ _ _, _ ) ->
            Err "combining rows has to come before `groupBy`, `reduce` or `map`"

        ( Map lambda, Rows ) ->
            bind params ast builder lambda
                |> Result.andThen (\env -> checkProjection env lambda.body)
                |> Result.map
                    (\( fields, hidden ) ->
                        { builder
                            | projection = Fields fields
                            , hidden = hidden
                            , phase = Projected
                        }
                    )

        ( Map _, _ ) ->
            Err "`map` cannot follow `groupBy` or `reduce` — use `reduce` to build the grouped row"

        ( GroupBy keys, Rows ) ->
            groupKeys params ast keys builder
                |> Result.map (\resolved -> { builder | groupBy = resolved, phase = Grouped })

        ( GroupBy _, _ ) ->
            Err "`groupBy` has to come before any projection"

        ( Reduce lambda, Rows ) ->
            -- No `groupBy` before it: one row for the whole table. Every
            -- column must still be aggregated, which is exactly what SQL
            -- requires of a select with no GROUP BY.
            reduceInto params ast lambda builder

        ( Reduce lambda, Grouped ) ->
            reduceInto params ast lambda builder

        ( Reduce _, _ ) ->
            Err "`reduce` cannot follow a projection"

        ( SortBy spec, _ ) ->
            if lookupColumn spec.column (outputColumns builder |> Result.withDefault []) == Nothing then
                Err (unknownColumn spec.column (outputColumns builder |> Result.withDefault []))

            else
                Ok { builder | sort = Just spec }

        ( Limit n, _ ) ->
            if n <= 0 then
                Err "`limit` needs a positive number of rows"

            else
                Ok { builder | limit = Just n }

        ( Select, _ ) ->
            Ok { builder | cardinality = Just One, phase = Done }

        ( SelectAll, _ ) ->
            Ok { builder | cardinality = Just Many, phase = Done }

        ( Scalar, _ ) ->
            outputColumns builder
                |> Result.andThen
                    (\rowType ->
                        case rowType of
                            [ _ ] ->
                                Ok
                                    { builder
                                        | display = AsScalar
                                        , cardinality = Just One
                                        , phase = Done
                                    }

                            _ ->
                                Err
                                    ("`scalar` shows one number, but this row has "
                                        ++ String.fromInt (List.length rowType)
                                        ++ " columns"
                                    )
                    )

        ( Chart kind config, _ ) ->
            chart kind config builder
                |> Result.map
                    (\spec ->
                        { builder
                            | display = AsChart spec
                            , cardinality = Just Many
                            , phase = Done
                        }
                    )


{-| Check a chart's channels against the row it will be drawn from.

This is the point of the compiler knowing column types. Vega-Lite needs each
channel annotated as quantitative, nominal or temporal, and those annotations
are usually written by hand and quietly wrong. Here they are derived. A `y`
that is not a number is a compile error rather than an empty chart.

-}
chart : ChartKind -> List ( String, String ) -> Builder -> Result String ChartSpec
chart kind config builder =
    outputColumns builder
        |> Result.andThen
            (\rowType ->
                case List.filter (\( name, _ ) -> not (List.member name knownChannels)) config of
                    ( unknown, _ ) :: _ ->
                        Err
                            ("`"
                                ++ unknown
                                ++ "` is not a channel. This chart takes "
                                ++ String.join ", " knownChannels
                                ++ "."
                            )

                    [] ->
                        let
                            names =
                                List.map Tuple.first config
                        in
                        case List.filter (\n -> countOf n names > 1) names |> List.head of
                            Just repeated ->
                                Err ("this chart sets `" ++ repeated ++ "` twice")

                            Nothing ->
                                config
                                    |> List.foldl
                                        (\( name, column ) acc ->
                                            Result.map2 (\done t -> done ++ [ ( name, column, t ) ])
                                                acc
                                                (channelColumn name column rowType)
                                        )
                                        (Ok [])
                                    |> Result.andThen (requireChannels kind)
            )


knownChannels : List String
knownChannels =
    [ "x", "y", "color" ]


channelColumn : String -> String -> List ( String, Type ) -> Result String Type
channelColumn name column rowType =
    case lookupColumn column rowType of
        Just t ->
            Ok t

        Nothing ->
            Err ("`" ++ name ++ "` names `" ++ column ++ "`, but " ++ unknownColumn column rowType)


requireChannels : ChartKind -> List ( String, String, Type ) -> Result String ChartSpec
requireChannels kind channels =
    let
        typeOfChannel name =
            channels
                |> List.filter (\( n, _, _ ) -> n == name)
                |> List.head
                |> Maybe.map (\( _, column, t ) -> ( column, t ))

        numeric name =
            case typeOfChannel name of
                Nothing ->
                    Err ("this chart needs a `" ++ name ++ "` channel")

                Just ( column, t ) ->
                    if Schema.isNumeric t then
                        Ok ()

                    else
                        Err
                            ("`"
                                ++ name
                                ++ "` has to be a number to be plotted, but `"
                                ++ column
                                ++ "` is a "
                                ++ Schema.typeName t
                            )

        present name =
            case typeOfChannel name of
                Nothing ->
                    Err ("this chart needs an `" ++ name ++ "` channel")

                Just _ ->
                    Ok ()

        requiredX =
            case kind of
                Scatter ->
                    numeric "x"

                _ ->
                    present "x"
    in
    requiredX
        |> Result.andThen (\_ -> numeric "y")
        |> Result.map (\_ -> { kind = kind, channels = channels })


{-| Resolve every grouping key to a name and an expression.

A bare accessor takes its own name. A lambda names each key itself, which is
what makes a computed key referable at all: `reduce` says `g.day`, and there
is no column called `day` to point at.

Repeating a key is refused. SQL accepts it and it means nothing, so it is far
more likely to be a slip.

-}
groupKeys : Params -> Pipeline -> GroupKeys -> Builder -> Result String (List ( String, TExpr ))
groupKeys params ast keys builder =
    case keys of
        ByColumns columns ->
            case List.filter (\c -> countOf c columns > 1) columns |> List.head of
                Just repeated ->
                    Err ("`groupBy` names `" ++ repeated ++ "` twice")

                Nothing ->
                    columns
                        |> List.foldl
                            (\column acc ->
                                Result.map2
                                    (\resolved ( alias, t ) -> resolved ++ [ ( column, TCol alias column t ) ])
                                    acc
                                    (resolve column builder.sides)
                            )
                            (Ok [])

        ByExpressions lambda ->
            bind params ast builder lambda
                |> Result.andThen (\env -> computedKeys env lambda.body)


computedKeys : Env -> Expr -> Result String (List ( String, TExpr ))
computedKeys env body =
    case body of
        Record [] ->
            Err "this `groupBy` names no keys"

        Record fields ->
            let
                names =
                    List.map .name fields
            in
            case List.filter (\n -> countOf n names > 1) names |> List.head of
                Just repeated ->
                    Err ("`groupBy` names `" ++ repeated ++ "` twice")

                Nothing ->
                    fields
                        |> List.foldl
                            (\f acc ->
                                Result.map2 (\done t -> done ++ [ ( f.name, t ) ])
                                    acc
                                    (checkExpr env f.value)
                            )
                            (Ok [])

        _ ->
            Err "a `groupBy` lambda has to produce a record, like `{ day = startOfDay f.date }`"


{-| A filter after a projection.

It reads as filtering what the projection produced, and that is what it does —
but the reference is to the projection's *expression*, not to the alias it is
selected under, for the same reason a computed grouping key inlines: an alias
is not reliably visible to the clause that would need it.

Where the filter lands depends on whether there was a grouping. After a
`reduce` the expressions contain aggregates and belong in HAVING; after a
plain `map` there is nothing aggregated and WHERE is correct.

-}
filterProjected : Params -> Pipeline -> Lambda -> Builder -> Result String Builder
filterProjected params ast lambda builder =
    case builder.limit of
        Just _ ->
            Err "`filter` after `limit` would be applied before it, not after — put the filter first"

        Nothing ->
            case builder.projection of
                All ->
                    Err "there is nothing to filter here yet"

                Fields fields ->
                    projectionEnv params ast builder lambda fields
                        |> Result.andThen (\env -> checkExpr env lambda.body)
                        |> Result.andThen
                            (\texpr ->
                                if Schema.typeName (typeOf texpr) /= "Bool" then
                                    Err ("`filter` needs a condition, but this expression is a " ++ Schema.typeName (typeOf texpr))

                                else if List.isEmpty builder.groupBy then
                                    Ok { builder | filter = Just (conjoin builder.filter texpr) }

                                else
                                    Ok { builder | having = Just (conjoin builder.having texpr) }
                            )


{-| Scope for a lambda that reads a projection rather than a table: one row,
whose columns are the projected names and whose values are their expressions.
-}
projectionEnv : Params -> Pipeline -> Builder -> Lambda -> List ( String, TExpr ) -> Result String Env
projectionEnv params ast builder lambda fields =
    case lambda.pattern of
        Single name ->
            Ok
                { bindings =
                    [ ( name
                      , { alias = ""
                        , table = ""
                        , columns = List.map (\( n, e ) -> ( n, typeOf e )) fields
                        }
                      )
                    ]
                , declarations = ast.declarations
                , inReduce = False
                , groupKeys = []
                , inlined = fields
                , sides = builder.sides
                , params = params
                }

        Destructure _ ->
            Err "a projection is one row, so this lambda takes a single name"


reduceInto : Params -> Pipeline -> Lambda -> Builder -> Result String Builder
reduceInto params ast lambda builder =
    groupEnv params ast builder lambda
        |> Result.andThen (\env -> checkProjection env lambda.body)
        |> Result.map
            (\( fields, hidden ) ->
                { builder
                    | projection = Fields fields
                    , hidden = hidden
                    , phase = Projected
                }
            )


conjoin : Maybe TExpr -> TExpr -> TExpr
conjoin existing next =
    case existing of
        Nothing ->
            next

        Just prior ->
            TBin And prior next TBool



-- COMBINING


{-| Add another table to the row.

`intersect` and `diff` give the row a new side; `exclude` does not, because an
anti-join contributes no columns — it only removes rows.

-}
combine : Schema -> CombineKind -> String -> String -> String -> Builder -> Result String Builder
combine schema kind leftKey table rightKey builder =
    case Schema.columnsOf table schema of
        Nothing ->
            Err ("`" ++ table ++ "` is not a table or an earlier cell. Known: " ++ knownTables schema)

        Just rightColumns ->
            Result.map2 Tuple.pair
                (resolve leftKey builder.sides)
                (columnOf rightKey table rightColumns)
                |> Result.andThen
                    (\( ( leftAlias, leftType ), rightType ) ->
                        if not (comparable (baseType leftType) (baseType rightType)) then
                            Err
                                ("these keys cannot match: `"
                                    ++ leftKey
                                    ++ "` is a "
                                    ++ Schema.typeName leftType
                                    ++ " and `"
                                    ++ table
                                    ++ "."
                                    ++ rightKey
                                    ++ "` is a "
                                    ++ Schema.typeName rightType
                                )

                        else
                            let
                                alias =
                                    uniqueAlias table builder.sides

                                entry =
                                    { kind = kind
                                    , table = table
                                    , alias = alias
                                    , leftAlias = leftAlias
                                    , leftKey = leftKey
                                    , rightKey = rightKey
                                    }
                            in
                            Ok
                                { builder
                                    | combines = builder.combines ++ [ entry ]
                                    , sides =
                                        case kind of
                                            Exclude ->
                                                builder.sides

                                            Diff ->
                                                -- A row with no match leaves this
                                                -- side absent, and the row type
                                                -- has to say so.
                                                builder.sides
                                                    ++ [ { alias = alias
                                                         , table = table
                                                         , columns = List.map (\( n, t ) -> ( n, optional t )) rightColumns
                                                         }
                                                       ]

                                            Intersect ->
                                                builder.sides
                                                    ++ [ { alias = alias, table = table, columns = rightColumns } ]
                                }
                    )


{-| A table may appear twice in one pipeline, so aliases are made unique.
-}
uniqueAlias : String -> List Side -> String
uniqueAlias table sides =
    let
        taken =
            List.map .alias sides

        candidate n =
            if n == 1 then
                table

            else
                table ++ "_" ++ String.fromInt n

        pick n =
            if List.member (candidate n) taken then
                pick (n + 1)

            else
                candidate n
    in
    pick 1


optional : Type -> Type
optional t =
    case t of
        TMaybe _ ->
            t

        _ ->
            TMaybe t



-- SCOPE


type alias Env =
    { bindings : List ( String, Side )
    , declarations : List TypeDecl
    , inReduce : Bool
    , groupKeys : List ( String, TExpr )

    -- Names that stand for an expression rather than a column, so reading one
    -- substitutes the expression.
    , inlined : List ( String, TExpr )
    , sides : List Side
    , params : Params
    }


{-| Match a lambda's pattern against the sides currently in scope.

An arity mismatch is the error that makes combining safe: a row that has
grown cannot go on being read as though it had not.

-}
bind : Params -> Pipeline -> Builder -> Lambda -> Result String Env
bind params ast builder lambda =
    case ( lambda.pattern, builder.sides ) of
        ( Single name, [ only ] ) ->
            Ok (envWith params ast builder [ ( name, only ) ])

        ( Single _, sides ) ->
            Err
                ("this row has "
                    ++ String.fromInt (List.length sides)
                    ++ " sides after combining, so the lambda has to name all of them, as in `\\("
                    ++ String.join ", " (List.map .alias sides)
                    ++ ") -> …`"
                )

        ( Destructure names, sides ) ->
            if List.length names /= List.length sides then
                Err
                    ("this lambda names "
                        ++ String.fromInt (List.length names)
                        ++ " rows but there are "
                        ++ String.fromInt (List.length sides)
                        ++ " in scope: "
                        ++ String.join ", " (List.map .alias sides)
                    )

            else
                Ok (envWith params ast builder (List.map2 Tuple.pair names sides))


{-| `reduce` binds the group as a whole rather than destructuring it, so a
column inside an aggregate is resolved across every side.
-}
groupEnv : Params -> Pipeline -> Builder -> Lambda -> Result String Env
groupEnv params ast builder lambda =
    case lambda.pattern of
        Single name ->
            Ok
                { bindings = List.map (\side -> ( name, side )) builder.sides
                , declarations = ast.declarations
                , inReduce = True
                , groupKeys = builder.groupBy
                , inlined = []
                , sides = builder.sides
                , params = params
                }

        Destructure _ ->
            Err "`reduce` binds the whole group, so it takes a single name, as in `\\g -> …`"


envWith : Params -> Pipeline -> Builder -> List ( String, Side ) -> Env
envWith params ast builder bindings =
    { bindings = bindings
    , declarations = ast.declarations
    , inReduce = False
    , groupKeys = []
    , inlined = []
    , sides = builder.sides
    , params = params
    }


{-| Find a column by name across every side in scope, refusing if more than
one side has it. Used where there is no pattern to say which side is meant:
`groupBy .region`, and columns inside `reduce`.
-}
resolve : String -> List Side -> Result String ( String, Type )
resolve column sides =
    case List.filterMap (\side -> lookupColumn column side.columns |> Maybe.map (\t -> ( side.alias, t ))) sides of
        [ found ] ->
            Ok found

        [] ->
            Err (unknownColumn column (List.concatMap .columns sides))

        several ->
            Err
                ("`"
                    ++ column
                    ++ "` is ambiguous — it is a column of "
                    ++ String.join " and " (List.map Tuple.first several)
                    ++ ". Rename one of them by projecting that side in its own cell first."
                )


columnOf : String -> String -> List ( String, Type ) -> Result String Type
columnOf column table columns =
    case lookupColumn column columns of
        Just t ->
            Ok t

        Nothing ->
            Err ("`" ++ table ++ "` has no column `" ++ column ++ "`. It has: " ++ (columns |> List.map Tuple.first |> String.join ", "))


boundSide : String -> Env -> Maybe Side
boundSide name env =
    env.bindings
        |> List.filter (\( bound, _ ) -> bound == name)
        |> List.head
        |> Maybe.map Tuple.second


paramNames : Env -> String
paramNames env =
    env.bindings |> List.map (\( bound, _ ) -> "`" ++ bound ++ "`") |> String.join " and "



-- OUTPUT


outputColumns : Builder -> Result String (List ( String, Type ))
outputColumns builder =
    case ( builder.projection, builder.sides ) of
        ( All, [ only ] ) ->
            Ok only.columns

        ( All, sides ) ->
            Err
                ("this pipeline combines "
                    ++ String.fromInt (List.length sides)
                    ++ " tables, so it has to say what the row should be with `map (\\("
                    ++ String.join ", " (List.map .alias sides)
                    ++ ") -> { … })` before selecting"
                )

        ( Fields fields, _ ) ->
            Ok (List.map (\( name, expr ) -> ( name, typeOf expr )) fields)


finish : Builder -> Result String Checked
finish builder =
    case builder.cardinality of
        Nothing ->
            Err "a pipeline has to end with `select` or `selectAll`"

        Just cardinality ->
            outputColumns builder
                |> Result.map
                    (\rowType ->
                        { source = builder.source
                        , sourceAlias =
                            List.head builder.sides |> Maybe.map .alias |> Maybe.withDefault builder.source
                        , reads = builder.source :: List.map .table builder.combines
                        , combines = builder.combines
                        , filter = builder.filter
                        , groupBy = List.map Tuple.second builder.groupBy
                        , having = builder.having
                        , projection = builder.projection
                        , hidden = builder.hidden
                        , sort = builder.sort
                        , limit = builder.limit
                        , cardinality = cardinality

                        -- The value cache's content hash is order-insensitive,
                        -- so only a cell that asked for an order needs the
                        -- stricter comparison.
                        , orderSignificant = builder.sort /= Nothing || builder.limit /= Nothing
                        , rowType = rowType
                        , declarations = builder.declarations
                        , display = builder.display
                        }
                    )



-- DECLARATIONS


validateDeclarations : List ( String, Type ) -> List TypeDecl -> Result String ()
validateDeclarations columns decls =
    decls
        |> List.foldl (\decl acc -> Result.andThen (\_ -> validateDecl columns decl) acc) (Ok ())


validateDecl : List ( String, Type ) -> TypeDecl -> Result String ()
validateDecl columns decl =
    let
        tags =
            List.map .tag decl.constructors

        duplicates =
            tags |> List.filter (\t -> countOf t tags > 1)
    in
    if not (List.isEmpty duplicates) then
        Err
            ("type `"
                ++ decl.name
                ++ "` has two constructors with the tag \""
                ++ (List.head duplicates |> Maybe.withDefault "")
                ++ "\""
            )

    else
        decl.constructors
            |> List.filterMap .payloadColumn
            |> List.filter (\col -> lookupColumn col columns == Nothing)
            |> List.head
            |> (\missing ->
                    case missing of
                        Just col ->
                            Err
                                ("type `"
                                    ++ decl.name
                                    ++ "` draws a payload from `."
                                    ++ col
                                    ++ "`, but "
                                    ++ unknownColumn col columns
                                )

                        Nothing ->
                            Ok ()
               )


lookupKey : String -> List ( String, TExpr ) -> Maybe TExpr
lookupKey name keys =
    keys |> List.filter (\( n, _ ) -> n == name) |> List.head |> Maybe.map Tuple.second


describeKeys : List String -> String
describeKeys keys =
    case keys of
        [] ->
            "available here — there is no `groupBy`, so this reduces the whole table and every column has to be aggregated"

        [ only ] ->
            "the grouping key `" ++ only ++ "`"

        _ ->
            "one of the grouping keys (" ++ String.join ", " keys ++ ")"


countOf : a -> List a -> Int
countOf x =
    List.filter ((==) x) >> List.length



-- EXPRESSIONS


checkProjection : Env -> Expr -> Result String ( List ( String, TExpr ), List ( String, String, Type ) )
checkProjection env expr =
    case expr of
        Record [] ->
            Err "this projection is empty — a row needs at least one column"

        Record fields ->
            let
                duplicates =
                    fields
                        |> List.map .name
                        |> (\names -> List.filter (\n -> countOf n names > 1) names)
            in
            case List.head duplicates of
                Just dup ->
                    Err ("this projection names the column `" ++ dup ++ "` twice")

                Nothing ->
                    fields
                        |> List.foldl
                            (\f acc ->
                                Result.andThen
                                    (\checked ->
                                        checkExpr env f.value
                                            |> Result.map (\t -> checked ++ [ ( f.name, t ) ])
                                    )
                                    acc
                            )
                            (Ok [])
                        |> Result.map (\fs -> ( fs, hiddenFor env fs ))

        _ ->
            Err "this stage has to produce a record, like `{ name = o.owner, total = o.total }`"


hiddenFor : Env -> List ( String, TExpr ) -> List ( String, String, Type )
hiddenFor env fields =
    let
        visible =
            List.map Tuple.first fields
    in
    fields
        |> List.concatMap (\( _, expr ) -> castPayloads env expr)
        |> List.filter (\( _, name, _ ) -> not (List.member name visible))
        |> dedupeColumns


castPayloads : Env -> TExpr -> List ( String, String, Type )
castPayloads env expr =
    case expr of
        TCast inner typeName ->
            let
                alias =
                    case inner of
                        TCol a _ _ ->
                            a

                        _ ->
                            ""
            in
            env.declarations
                |> List.filter (\d -> d.name == typeName)
                |> List.concatMap .constructors
                |> List.filterMap .payloadColumn
                |> List.filterMap
                    (\col ->
                        env.sides
                            |> List.filter (\s -> s.alias == alias)
                            |> List.concatMap .columns
                            |> lookupColumn col
                            |> Maybe.map (\t -> ( alias, col, t ))
                    )

        TBin _ l r _ ->
            castPayloads env l ++ castPayloads env r

        TCall _ args _ ->
            List.concatMap (castPayloads env) args

        TNot inner ->
            castPayloads env inner

        _ ->
            []


dedupeColumns : List ( String, String, Type ) -> List ( String, String, Type )
dedupeColumns =
    List.foldl
        (\c acc ->
            if List.any (\( _, n, _ ) -> n == (\( _, x, _ ) -> x) c) acc then
                acc

            else
                acc ++ [ c ]
        )
        []


checkExpr : Env -> Expr -> Result String TExpr
checkExpr env expr =
    case expr of
        Lit literal ->
            Ok (TLit literal (literalType literal))

        Var name ->
            case boundSide name env of
                Just _ ->
                    Err ("`" ++ name ++ "` is a whole row — index it with a column, like `" ++ name ++ ".total`")

                Nothing ->
                    case Dict.get name env.params of
                        Just ( t, literal ) ->
                            Ok (TLit literal t)

                        Nothing ->
                            Err ("there is no value called `" ++ name ++ "` here")

        Access obj column ->
            case boundSide obj env of
                Nothing ->
                    Err ("`" ++ obj ++ "` is not in scope — this lambda binds " ++ paramNames env)

                Just side ->
                    if not (List.isEmpty env.inlined) then
                        case lookupKey column env.inlined of
                            Just inlinedExpr ->
                                Ok inlinedExpr

                            Nothing ->
                                Err (unknownColumn column side.columns)

                    else if env.inReduce then
                        -- A key is referred to by the name `groupBy` gave it,
                        -- and reading it inlines the expression rather than
                        -- relying on the alias existing yet.
                        case lookupKey column env.groupKeys of
                            Just keyExpr ->
                                Ok keyExpr

                            Nothing ->
                                Err
                                    ("`"
                                        ++ column
                                        ++ "` is not "
                                        ++ describeKeys (List.map Tuple.first env.groupKeys)
                                        ++ ", so it has no single value per group. Wrap it in an aggregate, like `sum "
                                        ++ obj
                                        ++ "."
                                        ++ column
                                        ++ "`"
                                    )

                    else
                        case lookupColumn column side.columns of
                            Nothing ->
                                Err (unknownColumn column side.columns)

                            Just t ->
                                Ok (TCol side.alias column t)

        Record _ ->
            Err "a record is only allowed as the whole result of `map` or `reduce`"

        Not inner ->
            checkExpr env inner
                |> Result.andThen
                    (\t ->
                        if Schema.typeName (typeOf t) == "Bool" then
                            Ok (TNot t)

                        else
                            Err ("`not` needs a condition, but this is a " ++ Schema.typeName (typeOf t))
                    )

        Binary op left right ->
            Result.map2 Tuple.pair (checkExpr env left) (checkExpr env right)
                |> Result.andThen (\( l, r ) -> checkBinary op l r)

        Aggregate fn args ->
            checkAggregate env fn args

        Call fn args ->
            args
                |> List.foldl
                    (\arg acc -> Result.map2 (\done t -> done ++ [ t ]) acc (checkExpr env arg))
                    (Ok [])
                |> Result.andThen (checkCall fn)

        Cast inner typeName ->
            checkCast env inner typeName


literalType : Literal -> Type
literalType literal =
    case literal of
        LInt _ ->
            TInt

        LFloat _ ->
            TFloat

        LString _ ->
            TString

        LBool _ ->
            TBool


checkBinary : Op -> TExpr -> TExpr -> Result String TExpr
checkBinary op left right =
    let
        lt =
            baseType (typeOf left)

        rt =
            baseType (typeOf right)

        mismatch =
            Err
                ("`"
                    ++ Ast.opSymbol op
                    ++ "` cannot compare a "
                    ++ Schema.typeName lt
                    ++ " with a "
                    ++ Schema.typeName rt
                )
    in
    case op of
        And ->
            requireBool op left right

        Or ->
            requireBool op left right

        Add ->
            arithmetic op left right lt rt

        Sub ->
            arithmetic op left right lt rt

        Mul ->
            arithmetic op left right lt rt

        Div ->
            if Schema.isNumeric lt && Schema.isNumeric rt then
                Ok (TBin op left right TFloat)

            else
                mismatch

        Concat ->
            if lt == TString && rt == TString then
                Ok (TBin op left right TString)

            else
                Err ("`++` joins text, but got a " ++ Schema.typeName lt ++ " and a " ++ Schema.typeName rt)

        _ ->
            if comparable lt rt then
                Ok (TBin op left right TBool)

            else
                mismatch


requireBool : Op -> TExpr -> TExpr -> Result String TExpr
requireBool op left right =
    if baseType (typeOf left) == TBool && baseType (typeOf right) == TBool then
        Ok (TBin op left right TBool)

    else
        Err ("`" ++ Ast.opSymbol op ++ "` joins two conditions, but one side is not a condition")


arithmetic : Op -> TExpr -> TExpr -> Type -> Type -> Result String TExpr
arithmetic op left right lt rt =
    if Schema.isNumeric lt && Schema.isNumeric rt then
        Ok
            (TBin op
                left
                right
                (if lt == TFloat || rt == TFloat then
                    TFloat

                 else
                    TInt
                )
            )

    else
        Err
            ("`"
                ++ Ast.opSymbol op
                ++ "` needs numbers, but got a "
                ++ Schema.typeName lt
                ++ " and a "
                ++ Schema.typeName rt
            )


comparable : Type -> Type -> Bool
comparable a b =
    if Schema.isNumeric a && Schema.isNumeric b then
        True

    else
        case ( a, b ) of
            ( TCustom _, _ ) ->
                False

            ( _, TCustom _ ) ->
                False

            _ ->
                a == b


baseType : Type -> Type
baseType t =
    case t of
        TMaybe inner ->
            inner

        _ ->
            t


checkAggregate : Env -> String -> List Expr -> Result String TExpr
checkAggregate env fn args =
    if not env.inReduce then
        Err ("`" ++ fn ++ "` is an aggregate, so it only works inside `reduce`")

    else if List.member fn conditional then
        checkConditional env fn args

    else
        args
            |> List.foldl
                (\arg acc -> Result.map2 (\done t -> done ++ [ t ]) acc (aggArgument env fn arg))
                (Ok [])
            |> Result.andThen (aggregateResult fn)


{-| Aggregates that count or total only the rows matching a condition.

This is what a pivot is for, arrived at from the other side. DuckDB's `PIVOT`
produces a column per distinct value found in the data, which cannot be given
a row type before the query runs — and a row type known ahead of the query is
the thing this whole design rests on. Naming the cases instead gives the same
table, statically, and generalises: any condition, not only equality against a
value that happens to be present.

-}
conditional : List String
conditional =
    [ "countWhere", "sumWhere", "avgWhere" ]


checkConditional : Env -> String -> List Expr -> Result String TExpr
checkConditional env fn args =
    case ( fn, args ) of
        ( "countWhere", [ predicate ] ) ->
            checkPredicate env fn predicate
                |> Result.map (\p -> TAgg fn [ p ] TInt)

        ( "sumWhere", [ column, predicate ] ) ->
            conditionalOver env fn column predicate identity

        ( "avgWhere", [ column, predicate ] ) ->
            conditionalOver env fn column predicate (always TFloat)

        _ ->
            Err
                (case fn of
                    "countWhere" ->
                        "`countWhere` takes a condition, as in `countWhere (g.delay > 30)`"

                    _ ->
                        "`" ++ fn ++ "` takes a column and a condition, as in `" ++ fn ++ " g.distance (g.delay > 30)`"
                )


conditionalOver : Env -> String -> Expr -> Expr -> (Type -> Type) -> Result String TExpr
conditionalOver env fn column predicate result =
    Result.map2 Tuple.pair
        (aggArgument env fn column)
        (checkPredicate env fn predicate)
        |> Result.andThen
            (\( maybeColumn, p ) ->
                case maybeColumn of
                    Nothing ->
                        Err ("`" ++ fn ++ "` needs a column, not the whole group")

                    Just c ->
                        if Schema.isNumeric (typeOf c) then
                            Ok (TAgg fn [ c, p ] (result (baseType (typeOf c))))

                        else
                            Err ("`" ++ fn ++ "` needs a number, but this column is a " ++ Schema.typeName (typeOf c))
            )


{-| The condition looks at one row at a time, so the grouping rule is lifted
for it: inside the condition a bare column is exactly what is meant.
-}
checkPredicate : Env -> String -> Expr -> Result String TExpr
checkPredicate env fn predicate =
    checkExpr { env | inReduce = False, groupKeys = [] } predicate
        |> Result.andThen
            (\p ->
                if Schema.typeName (typeOf p) == "Bool" then
                    Ok p

                else
                    Err ("`" ++ fn ++ "` needs a condition, but this is a " ++ Schema.typeName (typeOf p))
            )


{-| An aggregate's argument is a column, a literal, or — for `count` alone —
the group itself.
-}
aggArgument : Env -> String -> Expr -> Result String (Maybe TExpr)
aggArgument env fn arg =
    case arg of
        Var name ->
            if boundSide name env == Nothing then
                Err ("`" ++ name ++ "` is not in scope — this group is " ++ paramNames env)

            else
                -- The group itself, which only `count` can be given.
                Ok Nothing

        Access obj column ->
            if boundSide obj env == Nothing then
                Err ("`" ++ obj ++ "` is not in scope — this group is " ++ paramNames env)

            else
                resolve column env.sides
                    |> Result.map (\( alias, t ) -> Just (TCol alias column t))

        Lit literal ->
            Ok (Just (TLit literal (literalType literal)))

        _ ->
            Err ("`" ++ fn ++ "` takes columns, not expressions")


{-| Arity and result type for each aggregate. The result types are DuckDB's
own: a median is a double even over integers, a mode keeps its column's type.
-}
aggregateResult : String -> List (Maybe TExpr) -> Result String TExpr
aggregateResult fn args =
    case ( fn, args ) of
        ( "count", [ Nothing ] ) ->
            Ok (TAgg "count" [] TInt)

        ( "count", [ Just column ] ) ->
            Ok (TAgg "count" [ column ] TInt)

        ( "countDistinct", [ Just column ] ) ->
            Ok (TAgg "countDistinct" [ column ] TInt)

        ( "sum", [ Just column ] ) ->
            overNumber fn column (baseType (typeOf column))

        ( "avg", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "median", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "stdDev", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "variance", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "min", [ Just column ] ) ->
            overOrdered fn column

        ( "max", [ Just column ] ) ->
            overOrdered fn column

        ( "mode", [ Just column ] ) ->
            overOrdered fn column

        ( "quantile", [ Just fraction, Just column ] ) ->
            if not (Schema.isNumeric (typeOf fraction)) then
                Err "`quantile` takes the fraction first, as in `quantile 0.95 g.delay`"

            else
                overNumber fn column TFloat
                    |> Result.map (\_ -> TAgg fn [ fraction, column ] TFloat)

        ( "correlation", [ Just left, Just right ] ) ->
            if Schema.isNumeric (typeOf left) && Schema.isNumeric (typeOf right) then
                Ok (TAgg fn [ left, right ] TFloat)

            else
                Err "`correlation` needs two numeric columns"

        ( _, [ Nothing ] ) ->
            Err ("`" ++ fn ++ "` needs a column, not the whole group")

        _ ->
            Err
                ("`"
                    ++ fn
                    ++ "` does not take "
                    ++ String.fromInt (List.length args)
                    ++ (if List.length args == 1 then
                            " argument"

                        else
                            " arguments"
                       )
                )


overNumber : String -> TExpr -> Type -> Result String TExpr
overNumber fn column result =
    if Schema.isNumeric (typeOf column) then
        Ok (TAgg fn [ column ] result)

    else
        Err ("`" ++ fn ++ "` needs a number, but this column is a " ++ Schema.typeName (typeOf column))


overOrdered : String -> TExpr -> Result String TExpr
overOrdered fn column =
    if baseType (typeOf column) == TBool then
        Err ("`" ++ fn ++ "` does not work on a Bool")

    else
        Ok (TAgg fn [ column ] (baseType (typeOf column)))


checkCall : String -> List TExpr -> Result String TExpr
checkCall fn args =
    case ( fn, args ) of
        ( "startOfDay", [ a ] ) ->
            temporal fn a TTimestamp

        ( "startOfMonth", [ a ] ) ->
            temporal fn a TTimestamp

        ( "startOfYear", [ a ] ) ->
            temporal fn a TTimestamp

        ( "year", [ a ] ) ->
            temporal fn a TInt

        ( "month", [ a ] ) ->
            temporal fn a TInt

        ( "dayOfWeek", [ a ] ) ->
            temporal fn a TInt

        ( "round", [ a ] ) ->
            numericCall fn a TInt

        ( "floor", [ a ] ) ->
            numericCall fn a TInt

        ( "ceiling", [ a ] ) ->
            numericCall fn a TInt

        ( "abs", [ a ] ) ->
            numericCall fn a (baseType (typeOf a))

        ( "roundTo", [ digits, a ] ) ->
            if baseType (typeOf digits) /= TInt then
                Err "`roundTo` takes the number of digits first, as in `roundTo 1 g.average`"

            else if not (Schema.isNumeric (typeOf a)) then
                Err ("`roundTo` needs a number, but this is a " ++ Schema.typeName (typeOf a))

            else
                -- Both arguments have to be carried, which the single-argument
                -- helper cannot do.
                Ok (TCall fn [ digits, a ] TFloat)

        ( "lower", [ a ] ) ->
            textual fn a

        ( "upper", [ a ] ) ->
            textual fn a

        _ ->
            Err
                ("`"
                    ++ fn
                    ++ "` does not take "
                    ++ String.fromInt (List.length args)
                    ++ (if List.length args == 1 then
                            " argument"

                        else
                            " arguments"
                       )
                )


temporal : String -> TExpr -> Type -> Result String TExpr
temporal fn arg result =
    if baseType (typeOf arg) == TTimestamp then
        Ok (TCall fn [ arg ] result)

    else
        Err ("`" ++ fn ++ "` needs a timestamp, but this is a " ++ Schema.typeName (typeOf arg))


numericCall : String -> TExpr -> Type -> Result String TExpr
numericCall fn arg result =
    if Schema.isNumeric (typeOf arg) then
        Ok (TCall fn [ arg ] result)

    else
        Err ("`" ++ fn ++ "` needs a number, but this is a " ++ Schema.typeName (typeOf arg))


textual : String -> TExpr -> Result String TExpr
textual fn arg =
    if baseType (typeOf arg) == TString then
        Ok (TCall fn [ arg ] TString)

    else
        Err ("`" ++ fn ++ "` needs text, but this is a " ++ Schema.typeName (typeOf arg))


checkCast : Env -> Expr -> String -> Result String TExpr
checkCast env inner typeName =
    case List.filter (\d -> d.name == typeName) env.declarations of
        [] ->
            Err
                ("`"
                    ++ typeName
                    ++ "` is not declared in this cell. Add `type "
                    ++ typeName
                    ++ " = ...` above the pipeline"
                )

        _ ->
            checkExpr env inner
                |> Result.andThen
                    (\t ->
                        if baseType (typeOf t) == TString then
                            Ok (TCast t typeName)

                        else
                            Err
                                ("`as "
                                    ++ typeName
                                    ++ "` reads a text column, but this one is a "
                                    ++ Schema.typeName (typeOf t)
                                )
                    )



-- LOOKUP HELPERS


lookupColumn : String -> List ( String, Type ) -> Maybe Type
lookupColumn name columns =
    columns
        |> List.filter (\( n, _ ) -> n == name)
        |> List.head
        |> Maybe.map Tuple.second


unknownColumn : String -> List ( String, Type ) -> String
unknownColumn name columns =
    "there is no column `"
        ++ name
        ++ "` here. Available: "
        ++ (columns |> List.map Tuple.first |> String.join ", ")
