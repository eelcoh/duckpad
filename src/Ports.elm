port module Ports exposing (dbReady, dropTable, materialize, queryOutcome)

import Json.Decode as D


{-| Ask DuckDB to materialise a cell as a temp table named after the cell, and
send back a preview plus a content hash of the whole result.

`orderSignificant` selects how that hash is computed. The cheap hash folds
rows in sorted order, which is deterministic but blind to a reordering; a cell
that asked for an order needs the stricter one that folds them as they lie.

-}
port materialize : { cellId : String, sql : String, orderSignificant : Bool } -> Cmd msg


{-| Forget a cell's table, when it is deleted or renamed. Without this a
renamed cell leaves its old table behind and a later cell of that name would
silently read a ghost.
-}
port dropTable : String -> Cmd msg


port queryOutcome : (D.Value -> msg) -> Sub msg


port dbReady : (D.Value -> msg) -> Sub msg
