module RecentsTests exposing (checks)

import Check exposing (Check, equal)
import Json.Decode as D
import Recents


entry : String -> String
entry extra =
    "{\"key\":\"/n.duckpad.md\",\"name\":\"n.duckpad.md\"" ++ extra ++ "}"


decode : String -> Result String (List Recents.Entry)
decode text =
    D.decodeString Recents.decoder text |> Result.mapError (always "no")


checks : List Check
checks =
    [ equal "recents: an entry keeps the host's key and location"
        (Ok [ ( "/n.duckpad.md", Just "/notes/n.duckpad.md", 7 ) ])
        (decode ("[" ++ entry ",\"path\":\"/notes/n.duckpad.md\",\"opened\":7" ++ "]")
            |> Result.map (List.map (\e -> ( e.key, e.path, e.opened )))
        )

    -- A browser handle has no path to show. The entry must still decode, and
    -- must not invent a location it cannot navigate to.
    , equal "recents: an entry without a path decodes as having none"
        (Ok [ Nothing ])
        (decode ("[" ++ entry ",\"opened\":1" ++ "]") |> Result.map (List.map .path))

    -- Both flags default to the safe reading: nothing is being held back, and
    -- the entry is assumed openable until a host says otherwise.
    , equal "recents: unsaved and reachable have safe defaults"
        (Ok [ ( False, True ) ])
        (decode ("[" ++ entry ",\"opened\":1" ++ "]")
            |> Result.map (List.map (\e -> ( e.unsaved, e.reachable )))
        )
    , equal "recents: a host can mark an entry unreachable"
        (Ok [ ( True, False ) ])
        (decode ("[" ++ entry ",\"opened\":1,\"unsaved\":true,\"reachable\":false" ++ "]")
            |> Result.map (List.map (\e -> ( e.unsaved, e.reachable )))
        )

    -- An index that cannot be read must not take the home screen down with
    -- it; Main falls back to an empty list, so a failure here is expected.
    , equal "recents: a malformed index fails rather than half-decoding"
        True
        (decode "[{\"name\":\"n\"}]" |> (\r -> r == Err "no"))

    -- The age is the reason an entry is worth clicking, so it resolves to the
    -- coarsest unit that still distinguishes "just now" from "last week".
    , equal "recents: ages resolve to a readable unit"
        [ "just now", "5 minutes ago", "1 hour ago", "3 days ago" ]
        (List.map (Recents.describeAge 1000000000)
            [ 1000000000 - 30000
            , 1000000000 - (5 * 60 * 1000)
            , 1000000000 - (60 * 60 * 1000)
            , 1000000000 - (3 * 86400 * 1000)
            ]
        )
    , equal "recents: a single unit is not pluralised"
        "1 minute ago"
        (Recents.describeAge 1000000000 (1000000000 - 100000))
    ]
