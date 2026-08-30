module Ui exposing
    ( accent
    , bad
    , bg
    , card
    , good
    , ink
    , line
    , mono
    , monoSize
    , muted
    , dropOnExport
    , pill
    , sans
    , stale
    , tinyCaps
    )

{-| The design tokens, as values rather than as custom properties.

Having them here is the point of building the view on elm-ui: a colour or a
font stack is something the compiler knows about, so a name that no longer
exists is an error rather than a rule that silently stops applying.

What stays in the stylesheet is what elm-ui is deliberately bad at — the
editor overlay, which needs two layers to agree on exact text metrics, the
rendered Markdown of a prose cell, and the result table's sticky header.

-}

import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Html.Attributes



-- COLOUR


ink : Element.Color
ink =
    Element.rgb255 0x1B 0x1F 0x23


muted : Element.Color
muted =
    Element.rgb255 0x6B 0x72 0x80


line : Element.Color
line =
    Element.rgb255 0xE3 0xE6 0xEA


bg : Element.Color
bg =
    Element.rgb255 0xFB 0xFB 0xFA


card : Element.Color
card =
    Element.rgb255 0xFF 0xFF 0xFF


accent : Element.Color
accent =
    Element.rgb255 0x2F 0x5D 0x8A


stale : Element.Color
stale =
    Element.rgb255 0xB8 0x86 0x0B


bad : Element.Color
bad =
    Element.rgb255 0xB4 0x43 0x3A


good : Element.Color
good =
    Element.rgb255 0x2F 0x7A 0x4F



-- TYPE


sans : List Font.Font
sans =
    [ Font.typeface "IBM Plex Sans", Font.sansSerif ]


mono : List Font.Font
mono =
    [ Font.typeface "Fira Code", Font.typeface "IBM Plex Mono", Font.monospace ]


monoSize : Int
monoSize =
    12



-- PIECES


{-| The small capitalised labels that name a thing without competing with it.
-}
tinyCaps : Element.Color -> String -> Element msg
tinyCaps colour label =
    Element.el
        [ Font.size 9
        , Font.color colour
        , Font.letterSpacing 0.8
        , Font.family sans
        ]
        (Element.text (String.toUpper label))


{-| A status chip. Outlined rather than filled, so a row of them reads as
annotation and not as a row of buttons.
-}
pill : Element.Color -> String -> Element msg
pill colour label =
    Element.el
        [ Font.size 9
        , Font.color colour
        , Font.letterSpacing 0.6
        , Font.family sans
        , Border.width 1
        , Border.color colour
        , Border.rounded 999
        , Element.paddingXY 8 3
        ]
        (Element.text (String.toUpper label))


{-| Marks a control that has no meaning in an exported notebook.

Export snapshots the page as it stands, so anything that only works because
the app is running — a button, a delete cross — has to be identifiable and
removed rather than left in place looking clickable.

-}
dropOnExport : Element.Attribute msg
dropOnExport =
    Element.htmlAttribute (Html.Attributes.attribute "data-export" "drop")
