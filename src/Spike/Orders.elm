module Spike.Orders exposing (Order, OrderId(..), Status(..), decoder, statusLabel)

{-| The Phase 2 typed-handoff spike, written by hand.

This module is exactly what the query compiler will have to emit in Phase 3:
a record type for the row, a custom type recovered from the columns, and a
decoder co-derived with them. It is hand-written here on purpose, so that the
awkward parts of the JS/Arrow boundary (BigInt, NULL, timestamps, a tag column
plus a payload column) are discovered *before* a compiler is written to
generate this shape automatically.

Nothing else in the notebook is allowed to import this: it is a stand-in for
generated code, not a library.

-}

import Json.Decode as D exposing (Decoder)
import Time


type OrderId
    = OrderId Int


type Status
    = Submitted
    | InTransit
    | Delivered Time.Posix


type alias Order =
    { id : OrderId
    , owner : String
    , status : Status
    , total : Float
    }


decoder : Decoder Order
decoder =
    D.map4 Order
        (D.field "id" (D.map OrderId D.int))
        (D.field "owner" D.string)
        statusDecoder
        (D.field "total" D.float)


{-| The interesting case: one Elm constructor is reconstructed from two SQL
columns, and an unknown tag is a decode failure rather than a silent default.
-}
statusDecoder : Decoder Status
statusDecoder =
    D.field "status" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "submitted" ->
                        D.succeed Submitted

                    "in_transit" ->
                        D.succeed InTransit

                    "delivered" ->
                        D.map Delivered (D.field "delivered_at" posix)

                    other ->
                        D.fail ("unknown order status: " ++ other)
            )


{-| DuckDB timestamps cross the bridge as epoch milliseconds. They arrive as a
float because the bridge widens BigInt rather than letting JSON.stringify throw.
-}
posix : Decoder Time.Posix
posix =
    D.map (Time.millisToPosix << round) D.float


statusLabel : Status -> String
statusLabel status =
    case status of
        Submitted ->
            "Submitted"

        InTransit ->
            "In transit"

        Delivered at ->
            "Delivered @" ++ String.fromInt (Time.posixToMillis at // 1000)
