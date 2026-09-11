module ProseTests exposing (checks)

{-| Every prose cell duckpad ships has to survive its own renderer.

`Prose.view` has no failure mode a reader would recognise: a document that
does not parse is shown as its own source instead. That is the right choice
for a notebook someone else wrote, but it means a broken table or a stray
construct in the shipped notebooks degrades silently into a wall of Markdown
punctuation, which no test would otherwise catch.

-}

import Cell exposing (Kind(..))
import Check exposing (Check, assert)
import Markdown.Parser
import Markdown.Renderer
import Notebook exposing (Notebook)
import Seed
import Tutorial


checks : List Check
checks =
    prose Tutorial.notebook ++ prose Seed.notebook


prose : Notebook -> List Check
prose notebook =
    notebook.cells
        |> List.filter (\cell -> cell.kind == Prose)
        |> List.map
            (\cell ->
                assert ("prose: " ++ cell.id ++ " renders as Markdown")
                    (renders cell.source)
            )


renders : String -> Bool
renders source =
    Markdown.Parser.parse source
        |> Result.mapError (always ())
        |> Result.andThen
            (\blocks ->
                Markdown.Renderer.render Markdown.Renderer.defaultHtmlRenderer blocks
                    |> Result.mapError (always ())
            )
        |> (\result ->
                case result of
                    Ok _ ->
                        True

                    Err _ ->
                        False
           )
