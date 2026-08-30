module Notebook exposing (Notebook, blank, parse, serialize)

{-| The on-disk format: Markdown with the query cells in fenced blocks.

Pluto stores a notebook as a runnable file in its host language. That does not
transfer here, because a notebook holds two languages plus prose, and no single
grammar makes all three valid. Markdown is the replacement that keeps the same
property that matters: the file is plain text a human can read, and a diff
shows the edit rather than a re-encoded document.

Prose is not a cell with an identity. It is the text between the fences,
exactly as written. Only query cells are named, because only they can be
referred to — a name here is a binding, not a label.

What the file never contains: results, generated SQL, generated Elm. Those are
recomputed on load. Pluto made the same choice, and it is what keeps a diff
about the edit instead of about the output that followed from it.

-}

import Cell exposing (Cell, Kind(..))


type alias Notebook =
    { title : String
    , cells : List Cell
    }


blank : Notebook
blank =
    { title = "Untitled notebook", cells = [] }


fence : String
fence =
    "```"


{-| The fence tags that make a block a cell. Everything else, fenced or not,
is prose — so a notebook can carry a shell snippet or a JSON sample without
the parser taking an interest in it.
-}
tags : List ( String, Kind )
tags =
    [ ( "duckpad", Query ), ( "source", Source ), ( "input", Input ) ]


tagFor : Kind -> String
tagFor kind =
    tags
        |> List.filter (\( _, k ) -> k == kind)
        |> List.head
        |> Maybe.map Tuple.first
        |> Maybe.withDefault "duckpad"



-- SERIALIZE


serialize : Notebook -> String
serialize notebook =
    let
        blocks =
            notebook.cells
                |> List.filterMap block
    in
    (frontmatter notebook :: blocks)
        |> String.join "\n\n"
        |> (\text -> text ++ "\n")


frontmatter : Notebook -> String
frontmatter notebook =
    "---\ntitle: " ++ notebook.title ++ "\n---"


block : Cell -> Maybe String
block cell =
    case cell.kind of
        Prose ->
            let
                text =
                    trimBlank cell.source
            in
            if String.isEmpty text then
                Nothing

            else
                Just text

        _ ->
            Just
                (fence
                    ++ tagFor cell.kind
                    ++ " "
                    ++ cell.id
                    ++ "\n"
                    ++ trimBlank cell.source
                    ++ "\n"
                    ++ fence
                )


{-| Strip blank lines from the ends without touching the indentation inside.
-}
trimBlank : String -> String
trimBlank text =
    text
        |> String.lines
        |> dropWhileBlank
        |> List.reverse
        |> dropWhileBlank
        |> List.reverse
        |> String.join "\n"


dropWhileBlank : List String -> List String
dropWhileBlank lines =
    case lines of
        first :: rest ->
            if String.trim first == "" then
                dropWhileBlank rest

            else
                lines

        [] ->
            []



-- PARSE


parse : String -> Result String Notebook
parse text =
    let
        ( title, body ) =
            splitFrontmatter (String.lines (String.replace "\u{000D}" "" text))
    in
    readBlocks body [] []
        |> Result.andThen uniqueNames
        |> Result.map (\cells -> { title = title, cells = cells })


splitFrontmatter : List String -> ( String, List String )
splitFrontmatter lines =
    case lines of
        "---" :: rest ->
            let
                ( head, tail ) =
                    spanUntil "---" rest
            in
            ( head
                |> List.filterMap (field "title")
                |> List.head
                |> Maybe.withDefault blank.title
            , tail
            )

        _ ->
            ( blank.title, lines )


spanUntil : String -> List String -> ( List String, List String )
spanUntil terminator lines =
    case lines of
        [] ->
            ( [], [] )

        first :: rest ->
            if String.trim first == terminator then
                ( [], rest )

            else
                let
                    ( taken, remaining ) =
                        spanUntil terminator rest
                in
                ( first :: taken, remaining )


field : String -> String -> Maybe String
field key line =
    let
        prefix =
            key ++ ":"
    in
    if String.startsWith prefix (String.trim line) then
        Just (String.trim (String.dropLeft (String.length prefix) (String.trim line)))

    else
        Nothing


{-| Walk the lines, switching into cell mode only on a `duckpad` fence.

Any other fenced block is prose and stays prose, so a notebook can contain a
shell snippet or a JSON sample without the parser taking an interest in it.

-}
readBlocks : List String -> List String -> List Cell -> Result String (List Cell)
readBlocks lines prose acc =
    case lines of
        [] ->
            Ok (List.reverse (flushProse prose acc))

        first :: rest ->
            case openingTag first of
                Just ( kind, name ) ->
                    if not (validName name) then
                        Err (badName name)

                    else
                        let
                            ( source, remaining ) =
                                spanUntil fence rest
                        in
                        readBlocks remaining
                            []
                            ({ id = name
                             , kind = kind
                             , source = String.join "\n" source
                             }
                                :: flushProse prose acc
                            )

                Nothing ->
                    readBlocks rest (first :: prose) acc


{-| A fence line that starts a cell, and the name it binds. A tagged fence
with no name is reported as a bad name rather than quietly read as prose,
because it is much more likely to be a typo than intended text.
-}
openingTag : String -> Maybe ( Kind, String )
openingTag line =
    tags
        |> List.filterMap
            (\( tag, kind ) ->
                let
                    prefix =
                        fence ++ tag
                in
                if line == prefix || String.startsWith (prefix ++ " ") line then
                    Just ( kind, String.trim (String.dropLeft (String.length prefix) line) )

                else
                    Nothing
            )
        |> List.head


flushProse : List String -> List Cell -> List Cell
flushProse prose acc =
    let
        text =
            prose |> List.reverse |> String.join "\n" |> trimBlank
    in
    if String.isEmpty text then
        acc

    else
        { id = "", kind = Prose, source = text } :: acc


validName : String -> Bool
validName name =
    case String.uncons name of
        Just ( first, rest ) ->
            Char.isLower first
                && String.all (\c -> Char.isAlphaNum c || c == '_') rest

        Nothing ->
            False


badName : String -> String
badName name =
    "`"
        ++ name
        ++ "` is not a usable cell name. Names start with a lowercase letter and hold letters, digits and underscores."


{-| Two cells of the same name would be two bindings of the same thing, and
the graph could not say which one a dependent meant.
-}
uniqueNames : List Cell -> Result String (List Cell)
uniqueNames cells =
    let
        names =
            cells |> List.filter (\c -> c.kind /= Prose) |> List.map .id

        duplicate =
            names |> List.filter (\n -> List.length (List.filter ((==) n) names) > 1) |> List.head
    in
    case duplicate of
        Just name ->
            Err ("this notebook defines `" ++ name ++ "` twice")

        Nothing ->
            Ok cells
