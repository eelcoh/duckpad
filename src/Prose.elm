module Prose exposing (view)

{-| Rendering for prose cells.

Prose is Markdown in the file, so it should be Markdown on the page. Until now
it was shown as its own source, which meant a heading appeared as `# Notes`
and the narrative half of a notebook read like a diff.

Raw HTML is not enabled. Prose comes from whoever wrote the notebook, and a
notebook is a thing people pass around, so the renderer stays a fixed set of
block and inline elements with no escape into markup.

-}

import Html exposing (Html)
import Html.Attributes exposing (class)
import Markdown.Parser
import Markdown.Renderer


view : String -> Html msg
view source =
    case render source of
        Ok blocks ->
            Html.div [ class "prose-rendered" ] blocks

        Err problem ->
            -- Markdown has no failure mode a reader would recognise, so a
            -- parse problem is shown as the text that was written rather than
            -- as an error about it.
            Html.div [ class "prose-rendered prose-raw" ] [ Html.text problem ]


render : String -> Result String (List (Html msg))
render source =
    Markdown.Parser.parse source
        |> Result.mapError (\_ -> source)
        |> Result.andThen
            (\blocks ->
                Markdown.Renderer.render Markdown.Renderer.defaultHtmlRenderer blocks
                    |> Result.mapError (\_ -> source)
            )
