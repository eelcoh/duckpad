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
    , disabled
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


{-| Secondary text. Dark enough to be read at the sizes it is actually used
at: WCAG's 4.5:1 assumes body text around 16px, and nothing here is, so this
sits at 6.4:1 against the page rather than scraping the threshold.
-}
muted : Element.Color
muted =
    Element.rgb255 0x56 0x5D 0x68


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


{-| A control that is present but cannot be used — the move arrows on the
first and last cell. Light enough to read as inert, dark enough to still be
seen: `line` at 1.2:1 against the page would make the control look missing
rather than disabled, which is worse than showing it.

Disabled controls are exempt from the contrast minimum, which is why this one
number sits below it deliberately rather than by oversight.
-}
disabled : Element.Color
disabled =
    Element.rgb255 0xA8 0xAD 0xB4


{-| The old gold failed AA outright at 3.1:1, in a 9px pill of all places.
-}
stale : Element.Color
stale =
    Element.rgb255 0x8A 0x65 0x08


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
    13



-- PIECES


{-| The small capitalised labels that name a thing without competing with it.
-}
tinyCaps : Element.Color -> String -> Element msg
tinyCaps colour label =
    Element.el
        [ Font.size 11
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
        [ Font.size 11
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
