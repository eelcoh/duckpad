module Dsl.Check exposing
    ( Cardinality(..)
    , Checked
    , CheckedJoin
    , Projection(..)
    , TExpr(..)
    , check
    , typeOf
    )

{-| Surface AST plus a schema, into a typed IR.

Everything downstream reads this IR and nothing re-derives it, which is the
point: the SQL and the Elm module are two renderings of one checked structure,
so they cannot disagree about what a column is called or what type it holds.

The checker also enforces SQL's grouping rule at the language level — inside
`reduce`, a bare column reference is only legal if it is the grouping key —
so the usual "column must appear in the GROUP BY clause" runtime error becomes
a message about the cell you are editing.

-}

import Dict
import Dsl.Ast as Ast exposing (..)
import Dsl.Schema as Schema exposing (Schema, Type(..))


type alias Checked =
    { source : String
    , reads : List String
    , joins : List CheckedJoin
    , filter : Maybe TExpr
    , groupBy : Maybe ( String, Type )
    , projection : Projection

    -- Columns the SQL must select but the row type must not expose: payloads
    -- that a cast's decoder reads out of a sibling column.
    , hidden : List ( String, Type )
    , intersects : List String
    , sort : Maybe SortSpec
    , limit : Maybe Int
    , cardinality : Cardinality
    , orderSignificant : Bool
    , rowType : List ( String, Type )
    , declarations : List TypeDecl
    }


type Projection
    = All
    | Fields (List ( String, TExpr ))


{-| Either a `USING` key or an `ON` predicate, never both.

An equality between two columns of the same name becomes `USING`, so the key
appears once in the result. That is not a convenience: it is what keeps every
name in the merged row unique, which in turn is what lets join predicates and
every later stage refer to columns without qualifying them by table.

-}
type alias CheckedJoin =
    { kind : JoinKind
    , table : String
    , using : Maybe String
    , on : Maybe TExpr
    }


type Cardinality
    = One
    | Many


type TExpr
    = TCol String Type
    | TLit Literal Type
    | TBin Op TExpr TExpr Type
    | TNot TExpr
      -- function, column (Nothing is `count g`, i.e. count(*)), result type
    | TAgg String (Maybe String) Type
    | TCast TExpr String


typeOf : TExpr -> Type
typeOf expr =
    case expr of
        TCol _ t ->
            t

        TLit _ t ->
            t

        TBin _ _ _ t ->
            t

        TNot _ ->
            TBool

        TAgg _ _ t ->
            t

        TCast _ name ->
            TCustom name



-- ENTRY POINT


check : Schema -> Pipeline -> Result String Checked
check schema ast =
    case Schema.columnsOf ast.source schema of
        Nothing ->
            Err
                ("`" ++ ast.source ++ "` is not a table or an earlier cell. Known: " ++ knownTables schema)

        Just columns ->
            validateDeclarations columns ast.declarations
                |> Result.andThen (\_ -> foldStages schema ast (start ast.source columns))
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
    , columns : List ( String, Type )
    , joins : List CheckedJoin
    , phase : Phase
    , filter : Maybe TExpr
    , groupBy : Maybe ( String, Type )
    , projection : Projection
    , hidden : List ( String, Type )
    , intersects : List String
    , sort : Maybe SortSpec
    , limit : Maybe Int
    , cardinality : Maybe Cardinality
    , declarations : List TypeDecl
    }


start : String -> List ( String, Type ) -> Builder
start source columns =
    { source = source
    , columns = columns
    , joins = []
    , phase = Rows
    , filter = Nothing
    , groupBy = Nothing
    , projection = All
    , hidden = []
    , intersects = []
    , sort = Nothing
    , limit = Nothing
    , cardinality = Nothing
    , declarations = []
    }


foldStages : Schema -> Pipeline -> Builder -> Result String Builder
foldStages schema ast builder =
    List.foldl
        (\stage acc -> Result.andThen (applyStage schema ast stage) acc)
        (Ok { builder | declarations = ast.declarations })
        ast.stages


applyStage : Schema -> Pipeline -> Stage -> Builder -> Result String Builder
applyStage schema ast stage builder =
    case ( stage, builder.phase ) of
        ( _, Done ) ->
            Err "nothing may follow `select` or `selectAll` — the pipeline ends there"

        ( Filter lambda, Rows ) ->
            checkExpr (envFor ast builder lambda.param False Nothing) lambda.body
                |> Result.andThen
                    (\texpr ->
                        if Schema.typeName (typeOf texpr) == "Bool" then
                            Ok { builder | filter = Just (conjoin builder.filter texpr) }

                        else
                            Err ("`filter` needs a condition, but this expression is a " ++ Schema.typeName (typeOf texpr))
                    )

        ( Filter _, _ ) ->
            Err "`filter` has to come before `groupBy`, `reduce` or `map` — filtering grouped rows is not supported yet"

        ( Join kind table lambda, Rows ) ->
            applyJoin schema ast kind table lambda builder

        ( Join _ _ _, _ ) ->
            Err "a join has to come before `groupBy`, `reduce` or `map`"

        ( Map lambda, Rows ) ->
            checkProjection (envFor ast builder lambda.param False Nothing) lambda.body
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

        ( GroupBy column, Rows ) ->
            case lookupColumn column builder.columns of
                Nothing ->
                    Err (unknownColumn column builder.columns)

                Just t ->
                    Ok { builder | groupBy = Just ( column, t ), phase = Grouped }

        ( GroupBy _, _ ) ->
            Err "`groupBy` has to come before any projection"

        ( Reduce lambda, Grouped ) ->
            let
                key =
                    Maybe.map Tuple.first builder.groupBy
            in
            checkProjection (envFor ast builder lambda.param True key) lambda.body
                |> Result.map
                    (\( fields, hidden ) ->
                        { builder
                            | projection = Fields fields
                            , hidden = hidden
                            , phase = Projected
                        }
                    )

        ( Reduce _, _ ) ->
            Err "`reduce` needs a `groupBy` immediately before it"

        ( SortBy spec, _ ) ->
            if lookupOutput spec.column builder == Nothing then
                Err (unknownColumn spec.column (outputColumns builder))

            else
                Ok { builder | sort = Just spec }

        ( Limit n, _ ) ->
            if n <= 0 then
                Err "`limit` needs a positive number of rows"

            else
                Ok { builder | limit = Just n }

        ( Intersect other, _ ) ->
            checkIntersect schema other builder

        ( Select, _ ) ->
            Ok { builder | cardinality = Just One, phase = Done }

        ( SelectAll, _ ) ->
            Ok { builder | cardinality = Just Many, phase = Done }


{-| Merge another table into the row.

The predicate is checked with both sides in scope, then the shape of it decides
how the join is written: an equality between two columns of the same name is a
`USING`, anything else an `ON`.

-}
applyJoin : Schema -> Pipeline -> JoinKind -> String -> Lambda2 -> Builder -> Result String Builder
applyJoin schema ast kind table lambda builder =
    case Schema.columnsOf table schema of
        Nothing ->
            Err ("`" ++ table ++ "` is not a table or an earlier cell. Known: " ++ knownTables schema)

        Just rightColumns ->
            let
                -- A left join can leave the right side absent, and the row type
                -- has to say so. This is the kind of thing that is a runtime
                -- surprise in SQL and a `Maybe` here.
                contributed =
                    case kind of
                        Inner ->
                            rightColumns

                        LeftOuter ->
                            List.map (\( n, t ) -> ( n, optional t )) rightColumns

                using =
                    detectUsing lambda lambda.body
            in
            checkExpr (joinEnv ast lambda builder.columns rightColumns) lambda.body
                |> Result.andThen requirePredicate
                |> Result.andThen
                    (\predicate ->
                        noSharedNames table builder.columns contributed using
                            |> Result.map
                                (\_ ->
                                    { builder
                                        | columns = merge builder.columns contributed using
                                        , joins =
                                            builder.joins
                                                ++ [ { kind = kind
                                                     , table = table
                                                     , using = using
                                                     , on =
                                                        case using of
                                                            Just _ ->
                                                                Nothing

                                                            Nothing ->
                                                                Just predicate
                                                     }
                                                   ]
                                    }
                                )
                    )


requirePredicate : TExpr -> Result String TExpr
requirePredicate predicate =
    if Schema.typeName (typeOf predicate) == "Bool" then
        Ok predicate

    else
        Err ("a join needs a condition, but this expression is a " ++ Schema.typeName (typeOf predicate))


{-| Detected from the surface syntax rather than the checked expression,
because by then which side a column came from has been forgotten — and that is
exactly the question being asked.
-}
detectUsing : Lambda2 -> Expr -> Maybe String
detectUsing lambda body =
    case body of
        Binary Eq (Access a c1) (Access b c2) ->
            if c1 == c2 && ((a == lambda.left && b == lambda.right) || (a == lambda.right && b == lambda.left)) then
                Just c1

            else
                Nothing

        _ ->
            Nothing


optional : Type -> Type
optional t =
    case t of
        TMaybe _ ->
            t

        _ ->
            TMaybe t


merge : List ( String, Type ) -> List ( String, Type ) -> Maybe String -> List ( String, Type )
merge left right using =
    left ++ List.filter (\( n, _ ) -> Just n /= using) right


noSharedNames : String -> List ( String, Type ) -> List ( String, Type ) -> Maybe String -> Result String ()
noSharedNames table left right using =
    let
        leftNames =
            List.map Tuple.first left
    in
    right
        |> List.map Tuple.first
        |> List.filter (\n -> Just n /= using)
        |> List.filter (\n -> List.member n leftNames)
        |> List.head
        |> (\shared ->
                case shared of
                    Nothing ->
                        Ok ()

                    Just name ->
                        Err
                            ("both sides of this join have a column `"
                                ++ name
                                ++ "`. Only an equality between two columns of the same name is merged, and it has to be the whole condition; otherwise project `"
                                ++ table
                                ++ "` in its own cell first and rename the column there."
                            )
           )


conjoin : Maybe TExpr -> TExpr -> TExpr
conjoin existing next =
    case existing of
        Nothing ->
            next

        Just prior ->
            TBin And prior next TBool


{-| Both sides of an INTERSECT have to agree on names and types, or the result
has no row type at all.
-}
checkIntersect : Schema -> String -> Builder -> Result String Builder
checkIntersect schema other builder =
    case Schema.columnsOf other schema of
        Nothing ->
            Err ("`intersect " ++ other ++ "` refers to something that is not a table or an earlier cell")

        Just theirs ->
            let
                mine =
                    outputColumns builder
            in
            if mine == theirs then
                Ok { builder | intersects = builder.intersects ++ [ other ] }

            else
                Err
                    ("`intersect "
                        ++ other
                        ++ "` needs both sides to have the same columns.\n    this side: "
                        ++ describeColumns mine
                        ++ "\n    "
                        ++ other
                        ++ ": "
                        ++ describeColumns theirs
                    )


describeColumns : List ( String, Type ) -> String
describeColumns columns =
    columns
        |> List.map (\( name, t ) -> name ++ " : " ++ Schema.typeName t)
        |> String.join ", "


finish : Builder -> Result String Checked
finish builder =
    case builder.cardinality of
        Nothing ->
            Err "a pipeline has to end with `select` or `selectAll`"

        Just cardinality ->
            Ok
                { source = builder.source
                , joins = builder.joins
                , reads = builder.source :: (List.map .table builder.joins ++ builder.intersects)
                , filter = builder.filter
                , groupBy = builder.groupBy
                , projection = builder.projection
                , hidden = builder.hidden
                , intersects = builder.intersects
                , sort = builder.sort
                , limit = builder.limit
                , cardinality = cardinality

                -- The Phase 2 finding made actionable: the value cache can
                -- only ignore row order for cells that never asked for one.
                , orderSignificant = builder.sort /= Nothing || builder.limit /= Nothing
                , rowType = outputColumns builder
                , declarations = builder.declarations
                }


outputColumns : Builder -> List ( String, Type )
outputColumns builder =
    case builder.projection of
        All ->
            builder.columns

        Fields fields ->
            List.map (\( name, expr ) -> ( name, typeOf expr )) fields


lookupOutput : String -> Builder -> Maybe Type
lookupOutput name builder =
    lookupColumn name (outputColumns builder)



-- DECLARATIONS


{-| A declaration is only usable if every payload column it names exists and
every constructor is distinguishable by its wire tag.
-}
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


countOf : a -> List a -> Int
countOf x =
    List.filter ((==) x) >> List.length



-- EXPRESSIONS


{-| A lambda's parameters and the columns each one stands for.

Most stages bind one row. A join binds two, which is the whole reason its
predicate takes two parameters: `o.id` and `c.id` have to be distinguishable
before the checker can decide whether they are the same column.

-}
type alias Env =
    { bindings : List ( String, List ( String, Type ) )
    , declarations : List TypeDecl
    , inReduce : Bool
    , groupKey : Maybe String
    }


envFor : Pipeline -> Builder -> String -> Bool -> Maybe String -> Env
envFor ast builder param inReduce groupKey =
    { bindings = [ ( param, builder.columns ) ]
    , declarations = ast.declarations
    , inReduce = inReduce
    , groupKey = groupKey
    }


joinEnv : Pipeline -> Lambda2 -> List ( String, Type ) -> List ( String, Type ) -> Env
joinEnv ast lambda leftColumns rightColumns =
    { bindings = [ ( lambda.left, leftColumns ), ( lambda.right, rightColumns ) ]
    , declarations = ast.declarations
    , inReduce = False
    , groupKey = Nothing
    }


boundColumns : String -> Env -> Maybe (List ( String, Type ))
boundColumns name env =
    env.bindings
        |> List.filter (\( bound, _ ) -> bound == name)
        |> List.head
        |> Maybe.map Tuple.second


paramNames : Env -> String
paramNames env =
    env.bindings |> List.map (\( bound, _ ) -> "`" ++ bound ++ "`") |> String.join " and "


{-| A projection is the only place a record is legal, and it is required
there: a cell's value is a table, so its rows must have named columns.

Returns the visible fields and any hidden payload columns the casts need.

-}
checkProjection : Env -> Expr -> Result String ( List ( String, TExpr ), List ( String, Type ) )
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


{-| Payload columns referenced by any cast in the projection, minus anything
already visible under its own name.
-}
hiddenFor : Env -> List ( String, TExpr ) -> List ( String, Type )
hiddenFor env fields =
    let
        visible =
            List.map Tuple.first fields

        needed =
            fields
                |> List.concatMap (\( _, expr ) -> castPayloads env expr)
    in
    needed
        |> List.filter (\( name, _ ) -> not (List.member name visible))
        |> dedupeColumns


castPayloads : Env -> TExpr -> List ( String, Type )
castPayloads env expr =
    case expr of
        TCast _ typeName ->
            env.declarations
                |> List.filter (\d -> d.name == typeName)
                |> List.concatMap .constructors
                |> List.filterMap .payloadColumn
                |> List.filterMap
                    (\col ->
                        env.bindings
                            |> List.concatMap Tuple.second
                            |> lookupColumn col
                            |> Maybe.map (\t -> ( col, t ))
                    )

        TBin _ l r _ ->
            castPayloads env l ++ castPayloads env r

        TNot inner ->
            castPayloads env inner

        _ ->
            []


dedupeColumns : List ( String, Type ) -> List ( String, Type )
dedupeColumns =
    List.foldl
        (\c acc ->
            if List.any (\( n, _ ) -> n == Tuple.first c) acc then
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
            case boundColumns name env of
                Just _ ->
                    Err ("`" ++ name ++ "` is a whole row — index it with a column, like `" ++ name ++ ".total`")

                Nothing ->
                    Err ("there is no value called `" ++ name ++ "` here")

        Access obj column ->
            case boundColumns obj env of
                Nothing ->
                    Err ("`" ++ obj ++ "` is not in scope — this lambda binds " ++ paramNames env)

                Just columns ->
                    case lookupColumn column columns of
                        Nothing ->
                            Err (unknownColumn column columns)

                        Just t ->
                            if env.inReduce && env.groupKey /= Just column then
                                Err
                                    ("`"
                                        ++ column
                                        ++ "` is not the grouping key, so it has no single value per group. Wrap it in an aggregate, like `sum "
                                        ++ obj
                                        ++ "."
                                        ++ column
                                        ++ "`"
                                    )

                            else
                                Ok (TCol column t)

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

        Aggregate fn arg ->
            checkAggregate env fn arg

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


{-| Int and Float compare freely; everything else has to match exactly. A
custom type never compares, because its wire form is a string and comparing
against that would defeat having declared it.
-}
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


checkAggregate : Env -> String -> Expr -> Result String TExpr
checkAggregate env fn arg =
    if not env.inReduce then
        Err ("`" ++ fn ++ "` is an aggregate, so it only works inside `reduce`")

    else
        case arg of
            Var name ->
                if boundColumns name env == Nothing then
                    Err ("`" ++ name ++ "` is not in scope — this group is " ++ paramNames env)

                else if fn == "count" then
                    Ok (TAgg "count" Nothing TInt)

                else
                    Err ("`" ++ fn ++ "` needs a column, like `" ++ fn ++ " " ++ name ++ ".total`")

            Access obj column ->
                case boundColumns obj env of
                    Nothing ->
                        Err ("`" ++ obj ++ "` is not in scope — this group is " ++ paramNames env)

                    Just columns ->
                        case lookupColumn column columns of
                            Nothing ->
                                Err (unknownColumn column columns)

                            Just t ->
                                aggregateResult fn column (baseType t)

            _ ->
                Err ("`" ++ fn ++ "` takes a column, not an expression")


aggregateResult : String -> String -> Type -> Result String TExpr
aggregateResult fn column t =
    case fn of
        "count" ->
            Ok (TAgg fn (Just column) TInt)

        "avg" ->
            if Schema.isNumeric t then
                Ok (TAgg fn (Just column) TFloat)

            else
                Err ("`avg` needs a number, but `" ++ column ++ "` is a " ++ Schema.typeName t)

        "sum" ->
            if Schema.isNumeric t then
                Ok (TAgg fn (Just column) t)

            else
                Err ("`sum` needs a number, but `" ++ column ++ "` is a " ++ Schema.typeName t)

        _ ->
            -- min and max keep their column's type, and work on anything
            -- orderable, which for our type language is everything but Bool.
            if t == TBool then
                Err ("`" ++ fn ++ "` does not work on a Bool")

            else
                Ok (TAgg fn (Just column) t)


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
