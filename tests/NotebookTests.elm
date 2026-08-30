module NotebookTests exposing (checks)

{-| Tests for the on-disk format: round-tripping, and the diff behaviour the
format exists to get right.
-}

import Cell exposing (Cell, Kind(..))
import Check exposing (Check, assert, equal, isErr)
import Notebook exposing (Notebook)


checks : List Check
checks =
    formatChecks ++ diffChecks


sample : Notebook
sample =
    { title = "Orders"
    , cells =
        [ { id = "", kind = Prose, source = "Intro prose." }
        , { id = "a", kind = Query, source = "access orders ()\n  |> selectAll" }
        , { id = "", kind = Prose, source = "Middle prose." }
        , { id = "b", kind = Query, source = "access a ()\n  |> selectAll" }
        ]
    }


sampleText : String
sampleText =
    Notebook.serialize sample


formatChecks : List Check
formatChecks =
    [ equal "notebook: serialize then parse is the identity"
        (Ok sample)
        (Notebook.parse sampleText)
    , equal "notebook: the serialized form is the obvious one"
        ("---\ntitle: Orders\n---\n\n"
            ++ "Intro prose.\n\n"
            ++ "```note-ml a\naccess orders ()\n  |> selectAll\n```\n\n"
            ++ "Middle prose.\n\n"
            ++ "```note-ml b\naccess a ()\n  |> selectAll\n```\n"
        )
        sampleText
    , equal "notebook: reading order is preserved, not sorted into dependency order"
        (Ok [ "b", "a" ])
        (Notebook.parse "```note-ml b\naccess a () |> selectAll\n```\n\n```note-ml a\naccess orders () |> selectAll\n```"
            |> Result.map (.cells >> List.filter (\c -> c.kind == Query) >> List.map .id)
        )
    , equal "notebook: prose carries no identity"
        (Ok [ "" ])
        (Notebook.parse "Just some prose."
            |> Result.map (.cells >> List.map .id)
        )
    , equal "notebook: a missing frontmatter block yields the default title"
        (Ok "Untitled notebook")
        (Notebook.parse "Some prose." |> Result.map .title)
    , equal "notebook: the title is read from frontmatter"
        (Ok "My analysis")
        (Notebook.parse "---\ntitle: My analysis\n---\n\nprose" |> Result.map .title)
    , equal "notebook: a fenced block in another language stays prose"
        (Ok [ Prose ])
        (Notebook.parse "```sql\nSELECT 1\n```" |> Result.map (.cells >> List.map .kind))
    , equal "notebook: blank space between blocks does not become a prose cell"
        (Ok 2)
        (Notebook.parse "```note-ml a\naccess t () |> selectAll\n```\n\n\n\n```note-ml b\naccess t () |> selectAll\n```"
            |> Result.map (.cells >> List.length)
        )
    , equal "notebook: indentation inside a cell survives the trip"
        (Ok "access orders ()\n  |> filter (\\o -> o.x > 1)\n  |> selectAll")
        (Notebook.parse sampleWithIndent
            |> Result.map (.cells >> List.map .source >> String.join "")
        )
    , equal "notebook: carriage returns are normalised away"
        (Ok [ "a" ])
        (Notebook.parse "```note-ml a\r\naccess t () |> selectAll\r\n```\r\n"
            |> Result.map (.cells >> List.map .id)
        )
    , isErr "notebook: two cells cannot share a name"
        (Notebook.parse "```note-ml a\naccess t () |> selectAll\n```\n\n```note-ml a\naccess t () |> selectAll\n```")
    , isErr "notebook: a query block has to be named"
        (Notebook.parse "```note-ml\naccess t () |> selectAll\n```")
    , isErr "notebook: a name has to be usable as a binding"
        (Notebook.parse "```note-ml Not-A-Name\naccess t () |> selectAll\n```")
    , assert "notebook: an empty notebook round-trips"
        (Notebook.parse (Notebook.serialize Notebook.blank) == Ok Notebook.blank)
    ]


sampleWithIndent : String
sampleWithIndent =
    "```note-ml a\naccess orders ()\n  |> filter (\\o -> o.x > 1)\n  |> selectAll\n```"



-- DIFF BEHAVIOUR


{-| The property the whole format choice is for: editing one cell should touch
only that cell's lines. A JSON notebook fails this — it re-encodes the
document and buries the edit in structural churn.
-}
diffChecks : List Check
diffChecks =
    let
        edited =
            { sample
                | cells =
                    sample.cells
                        |> List.map
                            (\c ->
                                if c.id == "a" then
                                    { c | source = "access orders ()\n  |> select" }

                                else
                                    c
                            )
            }

        before =
            String.lines sampleText

        after =
            String.lines (Notebook.serialize edited)
    in
    [ equal "notebook: an edit of equal length does not move any other line"
        (List.length before)
        (List.length after)
    , equal "notebook: editing one cell changes exactly the line it changed"
        [ 8 ]
        (changedLines before after)
    , equal "notebook: renaming a cell touches only its fence line"
        [ 6 ]
        (changedLines before
            (String.lines
                (Notebook.serialize
                    { sample
                        | cells =
                            sample.cells
                                |> List.map
                                    (\c ->
                                        if c.id == "a" then
                                            { c | id = "aa" }

                                        else
                                            c
                                    )
                    }
                )
            )
        )
    ]


changedLines : List String -> List String -> List Int
changedLines before after =
    List.map2 Tuple.pair before after
        |> List.indexedMap
            (\i ( x, y ) ->
                if x == y then
                    Nothing

                else
                    Just i
            )
        |> List.filterMap identity
