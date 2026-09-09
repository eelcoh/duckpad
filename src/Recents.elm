module Recents exposing
    ( Entry
    , decoder
    , entryDecoder
    , describeAge
    )

{-| The recents index: what the reader has opened, and where it was.

The index is a pointer list, never a store. It carries a name, a location if
the host can name one, when the document was last opened, and whether the
recovery mirror is holding edits for it — and deliberately no file contents.
Anything that would let this become a second copy of the notebook belongs in
the file the reader saved, not here.

A `key` is whatever the host needs to reopen the entry: an absolute path on
desktop, an opaque handle id in a browser that can persist one. Elm treats it
as opaque and hands it straight back.

-}

import Json.Decode as D



-- ENTRIES


type alias Entry =
    { key : String
    , name : String

    -- Shown when the host can say where the document lives. A browser with
    -- only a file handle cannot, so this stays absent rather than inventing a
    -- path that would not survive being clicked.
    , path : Maybe String
    , opened : Int

    -- Whether the recovery mirror still holds edits that never reached the
    -- file. It is what makes a recent entry worth reopening rather than
    -- discarding, so it is surfaced next to the name.
    , unsaved : Bool

    -- A host that can no longer reach the entry — the file moved, or the
    -- browser dropped the handle's permission — reports it here. The entry
    -- stays in the list so it can be located rather than silently vanishing.
    , reachable : Bool
    }


decoder : D.Decoder (List Entry)
decoder =
    D.list entryDecoder


entryDecoder : D.Decoder Entry
entryDecoder =
    D.map6 Entry
        (D.field "key" D.string)
        (D.field "name" D.string)
        (D.maybe (D.field "path" D.string))
        (D.field "opened" D.int)
        (optionalBool "unsaved")
        (D.oneOf [ D.field "reachable" D.bool, D.succeed True ])


optionalBool : String -> D.Decoder Bool
optionalBool field =
    D.oneOf [ D.field field D.bool, D.succeed False ]



-- PRESENTATION


{-| How long ago, in the coarsest unit that still says something.

The index stores an absolute time; the reader wants to know whether this is
the thing they were just working on. Anything older than a week is not, so it
stops resolving and says the number of days.

-}
describeAge : Int -> Int -> String
describeAge now opened =
    let
        seconds =
            (now - opened) // 1000
    in
    if seconds < 90 then
        "just now"

    else if seconds < 3600 then
        plural (seconds // 60) "minute"

    else if seconds < 86400 then
        plural (seconds // 3600) "hour"

    else
        plural (seconds // 86400) "day"


plural : Int -> String -> String
plural n unit =
    String.fromInt n
        ++ " "
        ++ unit
        ++ (if n == 1 then
                ""

            else
                "s"
           )
        ++ " ago"
