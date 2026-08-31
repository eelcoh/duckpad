module Dsl.Check exposing
    ( Cardinality(..)
    , ChartSpec
    , Params
    , Checked
    , CheckedCombine
    , CheckedUnpivot
    , CheckedWindow
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
import Set


type alias Checked =
    { source : String
    , sourceAlias : String
    , unpivot : Maybe CheckedUnpivot
      -- A `filter` over what an `extend` computed. Its own clause because a
      -- window function is evaluated after WHERE and after GROUP BY, so
      -- neither of those can see it.
    , qualify : Maybe TExpr
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


{-| The OVER clause every window function in an `extend` shares.

One per stage rather than one per function. SQL allows a different window on
each, but a stage that computed a rank over one partition and a running total
over another would be two thoughts wearing one lambda — and a second window is
a second cell, which in a notebook is the natural place for it.

-}
type alias CheckedWindow =
    { partition : List TExpr
    , order : Maybe SortSpec
    }


{-| A `unpivot`, resolved against the source's columns.

It renders as part of the FROM rather than as a clause, because DuckDB's
UNPIVOT produces a table. That is also why it has to be the first stage:
everything else in a `Checked` is one flat SELECT over this.

-}
type alias CheckedUnpivot =
    { name : String
    , value : String
    , columns : List String
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
      -- Everything the row already had, plus what an `extend` computed. The
      -- row grows rather than being replaced, which is the difference between
      -- an extend and a map.
    | Extended (List ( String, TExpr ))


type Cardinality
    = One
    | Many


type TExpr
    = TCol String String Type
    | TLit Literal Type
    | TBin Op TExpr TExpr Type
    | TNot TExpr
    | TAgg String (List TExpr) Type
      -- The same call, but over a window. A separate constructor because the
      -- renderer has to append the OVER clause and the checker has to allow it
      -- where a bare aggregate would be wrong.
    | TWin String (List TExpr) CheckedWindow Type
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

        TWin _ _ _ t ->
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


check : Schema -> Params -> List TypeDecl -> Pipeline -> Result String Checked
check schema params inherited ast =
    case Schema.columnsOf ast.source schema of
        Nothing ->
            Err ("`" ++ ast.source ++ "` is not a table or an earlier cell. Known: " ++ knownTables schema)

        Just columns ->
            inherit inherited ast.declarations
                |> Result.andThen
                    (\declarations ->
                        validateDeclarations columns ast.declarations
                            |> Result.andThen (\_ -> foldStages schema params { ast | declarations = declarations } (start ast.source columns))
                            |> Result.andThen finish
                    )


{-| A cell's own declarations, plus the ones its dependencies declared.

A type describes columns and columns flow down the graph, so the declaration
travels with them: a cell reading a column of type `Status` needs `Status`'s
constructors to decode it, and before this it inherited the type without the
declaration and generated a module referring to a type it never defined.

Redeclaring an inherited type identically is allowed, because that is what
anyone had to write before this and there is nothing wrong with it. Declaring
a *different* type under a name already in scope is refused: the column's
values were produced upstream, so a local definition that disagrees would
generate a decoder for tags the data does not contain.

-}
inherit : List TypeDecl -> List TypeDecl -> Result String (List TypeDecl)
inherit inherited own =
    let
        clash decl =
            own
                |> List.filter (\o -> o.name == decl.name && o.definition /= decl.definition)
                |> List.head
    in
    case List.filterMap clash inherited of
        conflicting :: _ ->
            Err
                ("`"
                    ++ conflicting.name
                    ++ "` is already declared by a cell this one reads, and this declaration is different. Remove it to use the one upstream, or rename this one"
                )

        [] ->
            Ok (own ++ List.filter (\d -> not (List.any (\o -> o.name == d.name) own)) inherited)


knownTables : Schema -> String
knownTables schema =
    Dict.keys schema |> String.join ", "



-- BUILDER


type Phase
    = Rows
    | Grouped
      -- `partitionBy` has named a window and `extend` has not consumed it yet.
    | Partitioned
      -- An `extend` has added its columns. Distinct from `Projected` because a
      -- `filter` here becomes a QUALIFY rather than a WHERE or a HAVING.
    | Windowed
    | Projected
    | Done


type alias Builder =
    { source : String
    , sides : List Side
    , unpivot : Maybe CheckedUnpivot
    , window : Maybe CheckedWindow
    , qualify : Maybe TExpr
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
    , unpivot = Nothing
    , window = Nothing
    , qualify = Nothing
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

        ( PartitionBy keys order, Rows ) ->
            partitionBy keys order builder

        ( PartitionBy _ _, _ ) ->
            Err "`partitionBy` has to come before `groupBy`, `reduce` or `map` — rank the groups in a cell that reads this one"

        ( Extend lambda, Partitioned ) ->
            extend params ast lambda builder

        ( Extend _, Rows ) ->
            Err "`extend` needs a window — put `partitionBy` before it"

        ( Extend _, _ ) ->
            Err "`extend` adds to a row, so it cannot follow `reduce` or `map`"

        ( _, Partitioned ) ->
            Err "`partitionBy` names a window, so `extend` has to come next"

        ( Filter lambda, Windowed ) ->
            qualify params ast lambda builder

        ( Unpivot spec columns, Rows ) ->
            unpivot spec columns builder

        ( Unpivot _ _, _ ) ->
            Err "`unpivot` has to come before `groupBy`, `reduce` or `map` — it changes what a row is"

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

                Extended _ ->
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
                , window = Nothing
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
                            outerSafe kind builder
                                |> Result.map
                                    (\safe ->
                                        { safe
                                            | combines = safe.combines ++ [ entry ]
                                            , sides = sidesAfter kind alias table rightColumns safe.sides
                                        }
                                    )
                    )


{-| How the row's sides change once another table is combined in.

`exclude` contributes nothing — an anti-join removes rows and adds no columns.
`diff` adds a side that may be absent. A full outer join may leave *either*
side absent, so every side already in scope becomes optional too: that is what
the join means, and saying so in the row type is the whole point of having one.

-}
sidesAfter : CombineKind -> String -> String -> List ( String, Type ) -> List Side -> List Side
sidesAfter kind alias table rightColumns sides =
    let
        added optional_ =
            sides
                ++ [ { alias = alias
                     , table = table
                     , columns =
                        if optional_ then
                            List.map (\( n, t ) -> ( n, optional t )) rightColumns

                        else
                            rightColumns
                     }
                   ]
    in
    case kind of
        Exclude ->
            sides

        Intersect ->
            added False

        Diff ->
            added True

        Union ->
            List.map optionalSide (added True)

        XUnion ->
            List.map optionalSide (added True)


optionalSide : Side -> Side
optionalSide side =
    { side | columns = List.map (\( n, t ) -> ( n, optional t )) side.columns }


{-| A filter already gathered would become a WHERE, which SQL applies after
the join — and after a full outer join that would silently discard every row
the other side contributed alone, turning it back into an inner join.
-}
outerSafe : CombineKind -> Builder -> Result String Builder
outerSafe kind builder =
    if (kind == Union || kind == XUnion) && builder.filter /= Nothing then
        Err "a `filter` before a `union` would be applied after the join and drop the rows only the other side has — filter after it, or project that side in its own cell first"

    else
        Ok builder


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
      -- Set inside an `extend`, where the window functions are legal and an
      -- ordinary aggregate means the running kind rather than the collapsing
      -- kind. Its presence is the fact; the window itself is what the calls
      -- need, so there is no separate flag to keep in step with it.
    , window : Maybe CheckedWindow
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
                , window = Nothing
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
    , window = Nothing
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

        ( Extended fields, [ only ] ) ->
            Ok (only.columns ++ List.map (\( name, expr ) -> ( name, typeOf expr )) fields)

        ( Extended _, sides ) ->
            Err
                ("this pipeline combines "
                    ++ String.fromInt (List.length sides)
                    ++ " tables, so it has to say what the row should be with `map` before `extend` can add to it"
                )


finish : Builder -> Result String Checked
finish builder =
    case builder.cardinality of
        Nothing ->
            Err "a pipeline has to end with `select` or `selectAll`"

        Just cardinality ->
            outputColumns builder
                |> Result.andThen (declared builder.declarations)
                |> Result.map
                    (\rowType ->
                        { source = builder.source
                        , unpivot = builder.unpivot
                        , qualify = builder.qualify
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



{-| Every custom type in the output row has to be declared somewhere in scope.

Without this the failure is silent and lands in the generated Elm rather than
here: a column typed `Status` with no declaration produces a module annotating
a type it never defines and calling a decoder it never writes. That is the
co-derivation guarantee — one IR, two renderings, no drift — failing quietly,
so it is worth a check of its own.

-}
declared : List TypeDecl -> List ( String, Type ) -> Result String (List ( String, Type ))
declared declarations rowType =
    let
        missing =
            rowType
                |> List.filterMap
                    (\( column, t ) ->
                        case stripMaybe t of
                            TCustom name ->
                                if List.any (\d -> d.name == name) declarations then
                                    Nothing

                                else
                                    Just ( column, name )

                            _ ->
                                Nothing
                    )
    in
    case missing of
        ( column, name ) :: _ ->
            Err ("`" ++ column ++ "` has type `" ++ name ++ "`, but nothing in scope declares it. Declare it here, or in a cell this one reads")

        [] ->
            Ok rowType


-- WINDOWS


{-| Name the window the next `extend` computes over.

The keys are plain columns, not expressions: a computed partition key would
need a name to be referred to by, and unlike `groupBy` nothing downstream
refers to it — the extend's lambda reads the row, not the key.

-}
partitionBy : List String -> Maybe SortSpec -> Builder -> Result String Builder
partitionBy keys order builder =
    case builder.sides of
        [ only ] ->
            let
                key name =
                    only.columns
                        |> List.filter (\( c, _ ) -> c == name)
                        |> List.head
                        |> Maybe.map (\( c, t ) -> TCol only.alias c t)
                        |> Result.fromMaybe ("`partitionBy` names `" ++ name ++ "`, which " ++ only.table ++ " does not have. It has: " ++ (only.columns |> List.map Tuple.first |> String.join ", "))

                ordered =
                    case order of
                        Nothing ->
                            Ok Nothing

                        Just spec ->
                            if List.any (\( c, _ ) -> c == spec.column) only.columns then
                                Ok (Just spec)

                            else
                                Err ("`partitionBy` orders by `" ++ spec.column ++ "`, which " ++ only.table ++ " does not have")
            in
            Result.map2
                (\partition sorted ->
                    { builder
                        | phase = Partitioned
                        , window = Just { partition = partition, order = sorted }
                    }
                )
                (collect (List.map key keys))
                ordered

        sides ->
            Err
                ("this pipeline combines "
                    ++ String.fromInt (List.length sides)
                    ++ " tables, so it has to say what the row should be with `map` before a window can be taken over it"
                )


{-| Add what the window computed, keeping every row.

The partner to `reduce`, and the difference is the whole point: a reduce
collapses each group to one row, so its record *is* the row; an extend leaves
the rows alone, so its record is added to what was already there.

-}
extend : Params -> Pipeline -> Lambda -> Builder -> Result String Builder
extend params ast lambda builder =
    bind params ast builder lambda
        |> Result.andThen (\env -> checkProjection { env | window = builder.window } lambda.body)
        |> Result.andThen
            (\( fields, hidden ) ->
                let
                    existing =
                        builder.sides |> List.concatMap .columns |> List.map Tuple.first

                    clashes =
                        fields |> List.map Tuple.first |> List.filter (\name -> List.member name existing)
                in
                case clashes of
                    clash :: _ ->
                        Err ("`extend` adds a column called `" ++ clash ++ "`, but the row already has one")

                    [] ->
                        Ok
                            { builder
                                | phase = Windowed
                                , projection = Extended fields
                                , hidden = builder.hidden ++ hidden
                            }
            )


{-| A `filter` over what an `extend` computed.

The same move as a `filter` after a `reduce` becoming a HAVING, for the same
reason: a window function is evaluated after WHERE and after GROUP BY, so
neither clause can see the column being filtered on. DuckDB has QUALIFY for
exactly this, which is why it costs nothing to expose — the alternative would
be wrapping the query in a subquery the rest of this IR cannot express.

-}
qualify : Params -> Pipeline -> Lambda -> Builder -> Result String Builder
qualify params ast lambda builder =
    case ( builder.projection, builder.sides, lambda.pattern ) of
        ( Extended fields, [ only ], Single name ) ->
            let
                -- Both halves of the row are readable: the columns that were
                -- always there, and what the extend just added. Reading either
                -- substitutes its expression, so the clause never depends on
                -- an alias being visible to it.
                row =
                    List.map (\( c, t ) -> ( c, TCol only.alias c t )) only.columns
                        ++ fields
            in
            checkExpr
                { bindings = [ ( name, { only | columns = List.map (\( n, e ) -> ( n, typeOf e )) row } ) ]
                , declarations = builder.declarations
                , inReduce = False
                , window = Nothing
                , groupKeys = []
                , inlined = row
                , sides = builder.sides
                , params = params
                }
                lambda.body
                |> Result.andThen
                    (\texpr ->
                        if Schema.typeName (typeOf texpr) /= "Bool" then
                            Err ("`filter` needs a condition, but this expression is a " ++ Schema.typeName (typeOf texpr))

                        else
                            Ok { builder | qualify = Just (conjoin builder.qualify texpr) }
                    )

        ( _, _, Destructure _ ) ->
            Err "a row is one thing here, so this lambda takes a single name"

        _ ->
            Err "there is nothing to filter here yet"


-- UNPIVOT


{-| Fold a set of columns into a name column and a value column.

The static-typeability argument, and the reason this exists where `pivot` does
not: a pivot invents columns from values only the data knows, so its row type
cannot be written down before the query runs. An unpivot's are all on the page.
Every folded column must share one type, because they all end up in the same
column, and that is what makes the result's type derivable rather than guessed.

-}
unpivot : Ast.UnpivotSpec -> List String -> Builder -> Result String Builder
unpivot spec columns builder =
    case ( builder.sides, builder.combines, builder.filter ) of
        ( [ side ], [], Nothing ) ->
            foldedType side columns
                |> Result.andThen
                    (\valueType ->
                        let
                            folded =
                                Set.fromList columns

                            survivors =
                                side.columns |> List.filter (\( name, _ ) -> not (Set.member name folded))

                            produced =
                                [ ( spec.name, TString ), ( spec.value, valueType ) ]

                            clashes =
                                [ spec.name, spec.value ]
                                    |> List.filter (\name -> List.any (\( c, _ ) -> c == name) survivors)
                        in
                        case clashes of
                            clash :: _ ->
                                Err ("`unpivot` would produce a column called `" ++ clash ++ "`, but one of the columns it keeps is already called that")

                            [] ->
                                if spec.name == spec.value then
                                    Err "`unpivot` needs two different names for the two columns it produces"

                                else
                                    Ok
                                        { builder
                                            | sides = [ { side | columns = survivors ++ produced } ]
                                            , unpivot = Just { name = spec.name, value = spec.value, columns = columns }
                                        }
                    )

        _ ->
            Err "`unpivot` has to be the first stage — it produces the rows everything after it works on, so nothing may come between it and the `access`"


{-| The one type every folded column has to share.

Nullability is the exception: folding a nullable column in with non-nullable
ones gives a nullable value column, which is right — some rows will have come
from the column that had nulls.

-}
foldedType : Side -> List String -> Result String Type
foldedType side columns =
    let
        lookup name =
            side.columns
                |> List.filter (\( c, _ ) -> c == name)
                |> List.head
                |> Maybe.map Tuple.second
                |> Result.fromMaybe ("`unpivot` names a column `" ++ name ++ "`, which " ++ side.table ++ " does not have. It has: " ++ (side.columns |> List.map Tuple.first |> String.join ", "))
    in
    case duplicated columns of
        Just name ->
            Err ("`unpivot` names `" ++ name ++ "` twice")

        Nothing ->
            columns
                |> List.map lookup
                |> collect
                |> Result.andThen
                    (\types ->
                        let
                            nullable =
                                List.any isNullable types

                            bases =
                                types |> List.map stripMaybe |> unique
                        in
                        case bases of
                            [ base ] ->
                                Ok
                                    (if nullable then
                                        TMaybe base

                                     else
                                        base
                                    )

                            _ ->
                                Err ("`unpivot` folds columns into one, so they all have to be the same type, but these are " ++ (bases |> List.map Schema.typeName |> String.join " and "))
                    )


isNullable : Type -> Bool
isNullable t =
    case t of
        TMaybe _ ->
            True

        _ ->
            False


stripMaybe : Type -> Type
stripMaybe t =
    case t of
        TMaybe inner ->
            inner

        _ ->
            t


unique : List Type -> List Type
unique =
    List.foldl
        (\t acc ->
            if List.member t acc then
                acc

            else
                acc ++ [ t ]
        )
        []


duplicated : List String -> Maybe String
duplicated names =
    case names of
        [] ->
            Nothing

        first :: rest ->
            if List.member first rest then
                Just first

            else
                duplicated rest


collect : List (Result String a) -> Result String (List a)
collect =
    List.foldr (\r acc -> Result.map2 (::) r acc) (Ok [])


-- DECLARATIONS


validateDeclarations : List ( String, Type ) -> List TypeDecl -> Result String ()
validateDeclarations columns decls =
    decls
        |> List.foldl (\decl acc -> Result.andThen (\_ -> validateDecl columns decl) acc) (Ok ())


validateDecl : List ( String, Type ) -> TypeDecl -> Result String ()
validateDecl columns decl =
    case decl.definition of
        Wraps _ wrapped ->
            if Schema.primitive wrapped == Nothing then
                Err
                    ("type `"
                        ++ decl.name
                        ++ "` wraps `"
                        ++ wrapped
                        ++ "`, which is not one of Int, Float, String, Bool, Timestamp"
                    )

            else
                Ok ()

        Enum constructors ->
            validateEnum columns decl.name constructors


validateEnum : List ( String, Type ) -> String -> List Constructor -> Result String ()
validateEnum columns name constructors =
    let
        decl =
            { name = name }

        tags =
            List.map .tag constructors

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
        constructors
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
                |> List.concatMap enumConstructors
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

        LTimestamp _ ->
            TTimestamp


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
    if env.window /= Nothing then
        checkWindow env fn args

    else if Set.member fn windowOnly then
        Err ("`" ++ fn ++ "` only works inside `extend`, over a window named by `partitionBy`")

    else if not env.inReduce then
        Err ("`" ++ fn ++ "` is an aggregate, so it only works inside `reduce`")

    else if List.member fn conditional then
        checkConditional env fn args

    else
        args
            |> List.foldl
                (\arg acc -> Result.map2 (\done t -> done ++ [ t ]) acc (aggArgument env fn arg))
                (Ok [])
            |> Result.andThen (aggregateResult fn)


{-| The functions that mean nothing outside a window.
-}
windowOnly : Set.Set String
windowOnly =
    Set.fromList [ "rowNumber", "rank", "denseRank", "lag", "lead" ]


{-| A call inside `extend`, over the window `partitionBy` named.

Two kinds arrive here. The ranking and offset functions exist only over a
window. The ordinary aggregates are the same functions as in a `reduce` and
keep the same result types — over a window they accumulate down the partition
instead of collapsing it, which is what makes `sum` a running total here and a
grand total there.

-}
checkWindow : Env -> String -> List Expr -> Result String TExpr
checkWindow env fn args =
    case env.window of
        Nothing ->
            Err "`extend` needs a window — put `partitionBy` before it"

        Just window ->
            args
                |> List.foldl
                    (\arg acc -> Result.map2 (\done t -> done ++ [ t ]) acc (aggArgument env fn arg))
                    (Ok [])
                |> Result.andThen (windowResult fn)
                |> Result.map (\( name, resolved, t ) -> TWin name resolved window t)


{-| Arity and result type for each window function.

`lag` and `lead` are nullable however the column is declared: the first row of
a partition has nothing before it, and the last nothing after. Saying so here
is what stops the generated decoder from insisting on a value that is not
there.

-}
windowResult : String -> List (Maybe TExpr) -> Result String ( String, List TExpr, Type )
windowResult fn args =
    case ( fn, args ) of
        ( "rowNumber", [ Nothing ] ) ->
            Ok ( "rowNumber", [], TInt )

        ( "rank", [ Nothing ] ) ->
            Ok ( "rank", [], TInt )

        ( "denseRank", [ Nothing ] ) ->
            Ok ( "denseRank", [], TInt )

        ( "lag", [ Just column ] ) ->
            Ok ( "lag", [ column ], TMaybe (baseType (typeOf column)) )

        ( "lead", [ Just column ] ) ->
            Ok ( "lead", [ column ], TMaybe (baseType (typeOf column)) )

        ( _, _ ) ->
            if Set.member fn windowOnly then
                Err ("`" ++ fn ++ "` does not take those arguments — `rowNumber`, `rank` and `denseRank` take the window, `lag` and `lead` take a column")

            else
                aggregateResult fn args
                    |> Result.map
                        (\aggregated ->
                            case aggregated of
                                TAgg name resolved t ->
                                    ( name, resolved, t )

                                other ->
                                    ( fn, [], typeOf other )
                        )


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

        ( "skewness", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "kurtosis", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "mad", [ Just column ] ) ->
            overNumber fn column TFloat

        ( "entropy", [ Just column ] ) ->
            -- Not restricted to numbers: the entropy of a text column is the
            -- spread of its values, which is a fair question to ask of one.
            Ok (TAgg fn [ column ] TFloat)

        ( _, [ Just left, Just right ] ) ->
            if List.member fn pairwise then
                overPair fn left right

            else
                Err ("`" ++ fn ++ "` does not take two arguments")

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


{-| The aggregates that read two columns at once.

`correlation` was the first; the regression family and the covariances have
the same shape. DuckDB takes the dependent variable first — `regrSlope
g.revenue g.spend` is the slope of revenue against spend — which is both its
order and the order the maths is written in.

-}
pairwise : List String
pairwise =
    [ "correlation"
    , "covarPop"
    , "covarSamp"
    , "regrSlope"
    , "regrIntercept"
    , "regrR2"
    , "regrCount"
    ]


overPair : String -> TExpr -> TExpr -> Result String TExpr
overPair fn left right =
    if Schema.isNumeric (typeOf left) && Schema.isNumeric (typeOf right) then
        Ok
            (TAgg fn
                [ left, right ]
                (if fn == "regrCount" then
                    TInt

                 else
                    TFloat
                )
            )

    else
        Err ("`" ++ fn ++ "` needs two numeric columns")


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


{-| Constructors, for a declaration that has any. A wrapper has one, but it
carries a type rather than a tag and nothing that reads tags wants it.
-}
enumConstructors : TypeDecl -> List Constructor
enumConstructors decl =
    case decl.definition of
        Enum constructors ->
            constructors

        Wraps _ _ ->
            []


checkCast : Env -> Expr -> String -> Result String TExpr
checkCast env inner typeName =
    case List.filter (\d -> d.name == typeName) env.declarations |> List.head of
        Nothing ->
            Err
                ("`"
                    ++ typeName
                    ++ "` is not declared in this cell. Add `type "
                    ++ typeName
                    ++ " = ...` above the pipeline"
                )

        Just decl ->
            let
                required =
                    case decl.definition of
                        -- An enum's wire form is the text in the column.
                        Enum _ ->
                            TString

                        Wraps _ wrapped ->
                            Schema.primitive wrapped |> Maybe.withDefault TString
            in
            checkExpr env inner
                |> Result.andThen
                    (\t ->
                        if baseType (typeOf t) == required then
                            Ok (TCast t typeName)

                        else
                            Err
                                ("`as "
                                    ++ typeName
                                    ++ "` reads a "
                                    ++ Schema.typeName required
                                    ++ " column, but this one is a "
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
