port module Ports exposing (dbReady, dropTable, fileOpened, loadSource, materialize, persist, queryOutcome, requestOpen, requestSave)

import Json.Decode as D


{-| Ask DuckDB to materialise a cell as a temp table named after the cell, and
send back a preview plus a content hash of the whole result.

`orderSignificant` selects how that hash is computed. The cheap hash folds
rows in sorted order, which is deterministic but blind to a reordering; a cell
that asked for an order needs the stricter one that folds them as they lie.

-}
port materialize : { cellId : String, sql : String, orderSignificant : Bool } -> Cmd msg


{-| Point a source cell at external data.

The result comes back on `queryOutcome` like a query does, but carries the
schema DuckDB inferred, because for a source that is the only place a row type
can come from.

-}
port loadSource : { cellId : String, format : String, uri : String } -> Cmd msg


{-| Forget a cell's table or view, when it is deleted or renamed. Without this
a renamed cell leaves its old one behind and a later cell of that name would
silently read a ghost.
-}
port dropTable : String -> Cmd msg


port queryOutcome : (D.Value -> msg) -> Sub msg


port dbReady : (D.Value -> msg) -> Sub msg


{-| Keep the current buffer in browser storage so a reload does not lose work.
This is a safety net, not the document: the file the user saves is the
document.
-}
port persist : String -> Cmd msg


port requestSave : { name : String, content : String } -> Cmd msg


port requestOpen : () -> Cmd msg


port fileOpened : (D.Value -> msg) -> Sub msg
