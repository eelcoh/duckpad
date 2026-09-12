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

    -- A double drops the trailing zero `roundTo 2` asked for, so the column
    -- arrives ragged and the table pads it back.
    , equal "decimals: a short fraction is padded out"
        "12.50"
        (Query.padDecimals (Just 2) "12.5")
    , equal "decimals: a whole number gains a fractional part"
        "8.00"
        (Query.padDecimals (Just 2) "8")
    , equal "decimals: a negative number pads on the right, not the left"
        "-3.40"
        (Query.padDecimals (Just 2) "-3.4")
    , equal "decimals: a value already at the asked-for places is untouched"
        "12.34"
        (Query.padDecimals (Just 2) "12.34")
    , equal "decimals: a longer fraction is never trimmed"
        "12.3456"
        (Query.padDecimals (Just 2) "12.3456")
    , equal "decimals: a column that asked for nothing is left alone"
        "12.5"
        (Query.padDecimals Nothing "12.5")
    , equal "decimals: a null renders as its dash, not as a padded zero"
        "—"
        (Query.padDecimals (Just 2) "—")
    , equal "decimals: an exponent is not a decimal numeral and is passed through"
        "1.2e-7"
        (Query.padDecimals (Just 2) "1.2e-7")
    ]
