module QueryTests exposing (checks)

import Check exposing (Check, equal)
import Json.Decode as D
import Query


checks : List Check
checks =
    [ equal "query schema: keeps an original-to-normalized heading mapping"
        (Ok [ { originalName = "Player Name", name = "player_name", sqlType = "VARCHAR", nullable = False } ])
        (D.decodeString Query.describedDecoder "[{\"originalName\":\"Player Name\",\"name\":\"player_name\",\"type\":\"VARCHAR\",\"nullable\":false}]")
    , equal "query schema: older outcomes use the field as its original heading"
        (Ok [ { originalName = "goals", name = "goals", sqlType = "BIGINT", nullable = True } ])
        (D.decodeString Query.describedDecoder "[{\"name\":\"goals\",\"type\":\"BIGINT\",\"nullable\":true}]")
    ]
