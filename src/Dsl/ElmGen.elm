module Dsl.ElmGen exposing (render)

{-| Typed IR to an Elm module.

The other rendering of `Dsl.Check.Checked`, and the reason the checker exists
at all: the row type and its decoder come out of the same pass that produced
the SQL, so a column cannot be renamed in one and not the other.

The shape is the one `Spike.Orders` was hand-written to discover — an opaque
row record, custom types rebuilt from a tag column, payloads pulled from a
sibling column, and timestamps widened through Float because that is how they
survive Arrow and JSON.

-}

import Dsl.Ast exposing (Constructor, TypeDecl)
import Dsl.Check exposing (Cardinality(..), Checked, Projection(..), TExpr(..))
import Dsl.Schema as Schema exposing (Type(..))


render : String -> Checked -> String
render moduleName checked =
    let
        used =
            usedDeclarations checked
    in
    [ header moduleName used ++ "\n\n" ++ imports checked used
    , List.map customType used |> String.join "\n\n"
    , rowAlias checked
    , decoder checked
    , List.map (constructorDecoder checked) used |> String.join "\n\n"
    , helpers checked used
    ]
        |> List.filter (not << String.isEmpty)
        |> String.join "\n\n\n"
        |> (\body -> body ++ "\n")


header : String -> List TypeDecl -> String
header moduleName used =
    let
        exposed =
            [ "Row", "Value", "decoder" ]
                ++ List.map (\d -> d.name ++ "(..)") used
    in
    "module "
        ++ moduleName
        ++ " exposing ("
        ++ String.join ", " (List.sort exposed)
        ++ ")"


imports : Checked -> List TypeDecl -> String
imports checked used =
    let
        needsTime =
            columnsOf checked
                |> List.any (\( _, t ) -> mentionsTimestamp t)

        payloadTime =
            used
                |> List.concatMap .constructors
                |> List.filterMap .payloadColumn
                |> List.filterMap (\c -> lookupHidden c checked)
                |> List.any mentionsTimestamp
    in
    ("import Json.Decode as D"
        :: (if needsTime || payloadTime then
                [ "import Time" ]

            else
                []
           )
    )
        |> String.join "\n"


mentionsTimestamp : Type -> Bool
mentionsTimestamp t =
    case t of
        TTimestamp ->
            True

        TMaybe inner ->
            mentionsTimestamp inner

        _ ->
            False


{-| Only the declarations a cast actually reached. A cell may declare a type
and not use it; emitting it anyway would produce an unused-import warning in
the generated module and confuse anyone reading it.
-}
usedDeclarations : Checked -> List TypeDecl
usedDeclarations checked =
    let
        names =
            columnsOf checked
                |> List.filterMap
                    (\( _, t ) ->
                        case t of
                            TCustom name ->
                                Just name

                            _ ->
                                Nothing
                    )
    in
    checked.declarations
        |> List.filter (\d -> List.member d.name names)


columnsOf : Checked -> List ( String, Type )
columnsOf checked =
    checked.rowType


lookupHidden : String -> Checked -> Maybe Type
lookupHidden name checked =
    checked.hidden
        |> List.filter (\( n, _ ) -> n == name)
        |> List.head
        |> Maybe.map Tuple.second


customType : TypeDecl -> String
customType decl =
    let
        variants =
            decl.constructors
                |> List.indexedMap
                    (\i c ->
                        (if i == 0 then
                            "    = "

                         else
                            "    | "
                        )
                            ++ c.name
                            ++ (case c.payloadColumn of
                                    Just _ ->
                                        " Time.Posix"

                                    Nothing ->
                                        ""
                               )
                    )
    in
    ("type " ++ decl.name) :: variants |> String.join "\n"


{-| The row record, plus the alias naming what the whole cell evaluates to.

`select` yields `Maybe Row` rather than a bare `Row`: a query that matched
nothing is an ordinary outcome, and making the caller face it here is cheaper
than a runtime error later.

-}
rowAlias : Checked -> String
rowAlias checked =
    let
        fields =
            checked.rowType
                |> List.indexedMap
                    (\i ( name, t ) ->
                        (if i == 0 then
                            "    { "

                         else
                            "    , "
                        )
                            ++ name
                            ++ " : "
                            ++ Schema.elmAnnotation t
                    )

        value =
            case checked.cardinality of
                One ->
                    "type alias Value =\n    Maybe Row"

                Many ->
                    "type alias Value =\n    List Row"
    in
    ((("type alias Row =" :: fields) ++ [ "    }" ]) |> String.join "\n")
        ++ "\n\n\n"
        ++ value


decoder : Checked -> String
decoder checked =
    let
        steps =
            checked.rowType
                |> List.map (\( name, t ) -> "        |> andMap " ++ fieldDecoder name t)
    in
    ("decoder : D.Decoder Row" :: "decoder =" :: "    D.succeed Row" :: steps)
        |> String.join "\n"


fieldDecoder : String -> Type -> String
fieldDecoder column t =
    case t of
        TCustom name ->
            "(" ++ decoderName name ++ " \"" ++ column ++ "\")"

        _ ->
            "(D.field \"" ++ column ++ "\" " ++ valueDecoder t ++ ")"


valueDecoder : Type -> String
valueDecoder t =
    case t of
        TInt ->
            "D.int"

        TFloat ->
            "D.float"

        TString ->
            "D.string"

        TBool ->
            "D.bool"

        TTimestamp ->
            "posix"

        TMaybe inner ->
            "(D.nullable " ++ valueDecoder inner ++ ")"

        TCustom name ->
            decoderName name


decoderName : String -> String
decoderName typeName =
    String.toLower (String.left 1 typeName) ++ String.dropLeft 1 typeName ++ "From"


{-| A tag-column decoder per declared type, parameterised by the column so two
columns of the same type can share it. An unrecognised tag fails the decode
rather than defaulting, which is the whole reason the tags are written down.
-}
constructorDecoder : Checked -> TypeDecl -> String
constructorDecoder _ decl =
    let
        branches =
            decl.constructors
                |> List.map
                    (\c ->
                        "                    \""
                            ++ c.tag
                            ++ "\" ->\n                        "
                            ++ constructorBody c
                    )
                |> String.join "\n\n"
    in
    decoderName decl.name
        ++ " : String -> D.Decoder "
        ++ decl.name
        ++ "\n"
        ++ decoderName decl.name
        ++ " column =\n"
        ++ "    D.field column D.string\n"
        ++ "        |> D.andThen\n"
        ++ "            (\\tag ->\n"
        ++ "                case tag of\n"
        ++ branches
        ++ "\n\n                    other ->\n"
        ++ "                        D.fail (\"unknown "
        ++ decl.name
        ++ ": \" ++ other)\n"
        ++ "            )"


constructorBody : Constructor -> String
constructorBody c =
    case c.payloadColumn of
        Nothing ->
            "D.succeed " ++ c.name

        Just column ->
            "D.map " ++ c.name ++ " (D.field \"" ++ column ++ "\" posix)"


helpers : Checked -> List TypeDecl -> String
helpers checked used =
    let
        needsPosix =
            List.any (\( _, t ) -> mentionsTimestamp t) checked.rowType
                || not (List.isEmpty (List.filterMap .payloadColumn (List.concatMap .constructors used)))

        andMapHelper =
            [ "andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b"
            , "andMap ="
            , "    D.map2 (|>)"
            ]
                |> String.join "\n"

        posixHelper =
            [ "{-| Timestamps cross the bridge as epoch milliseconds, widened to Float"
            , "because DuckDB's BIGINT does not survive JSON as an integer."
            , "-}"
            , "posix : D.Decoder Time.Posix"
            , "posix ="
            , "    D.map (Time.millisToPosix << round) D.float"
            ]
                |> String.join "\n"
    in
    if needsPosix then
        andMapHelper ++ "\n\n\n" ++ posixHelper

    else
        andMapHelper
