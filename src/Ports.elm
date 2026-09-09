port module Ports exposing (clearNotebook, dbReady, dropTable, exportStatic, fileOpened, fileSaved, forgetRecent, loadSource, materialize, openRecent, persist, queryOutcome, recentsChanged, requestOpen, requestSave, setCaret)

import Json.Decode as D


{-| Ask DuckDB to materialise a cell as a temp table named after the cell, and
send back a preview plus a content hash of the whole result.

`orderSignificant` selects how that hash is computed. The cheap hash folds
rows in sorted order, which is deterministic but blind to a reordering; a cell
that asked for an order needs the stricter one that folds them as they lie.

-}
port materialize : { cellId : String, sql : String, orderSignificant : Bool, rowLimit : Int } -> Cmd msg


{-| Point a data cell at external data.

The result comes back on `queryOutcome` like a query does, but carries the
schema DuckDB inferred, because for a source that is the only place a row type
can come from.

-}
port loadSource : { cellId : String, format : String, uri : String, options : String } -> Cmd msg


{-| Forget a cell's table or view, when it is deleted or renamed. Without this
a renamed cell leaves its old one behind and a later cell of that name would
silently read a ghost.
-}
port dropTable : String -> Cmd msg


{-| Forget the file association at a document boundary. Runtime tables are
dropped separately so this has exactly one responsibility.
-}
port clearNotebook : () -> Cmd msg


port queryOutcome : (D.Value -> msg) -> Sub msg


port dbReady : (D.Value -> msg) -> Sub msg


{-| Keep the current buffer in browser storage so a reload does not lose work.
This is a safety net, not the document: the file the user saves is the
document.
-}
port persist : String -> Cmd msg


port requestSave : { name : String, content : String, revision : Int, saveAs : Bool } -> Cmd msg


port requestOpen : () -> Cmd msg


port fileOpened : (D.Value -> msg) -> Sub msg


port fileSaved : (D.Value -> msg) -> Sub msg


{-| Put the caret back after an edit the keyboard handler made itself.

Elm owns the textarea's value, so replacing it moves the caret to the end.
Enter and Tab compute where it should be instead, and this puts it there once
the new value has been rendered.
-}
port setCaret : { id : String, pos : Int } -> Cmd msg


{-| Save the notebook as it currently stands: a single page with its results
already in it, no database and no network.
-}
port exportStatic : String -> Cmd msg


{-| Reopen something the reader picked off the home screen.

The key is the host's own, so this says which entry rather than where it
lives: a path that Elm never parsed cannot be a path Elm gets wrong. The
document comes back on `fileOpened` like any other open, which is what keeps
the home screen from being a second way to load a notebook.

`locate` turns the same call into a picker when the entry has gone missing,
so reconnecting a moved file reuses the open path rather than a parallel one.

-}
port openRecent : { key : String, locate : Bool } -> Cmd msg


{-| Drop an entry from the index.

Used when the reader dismisses one, and when a `Locate` is abandoned for a
file that is never coming back. It removes the pointer only; a recovery
mirror for that document is a separate thing and outlives it.

-}
port forgetRecent : String -> Cmd msg


{-| The index, whenever the host has rewritten it.

Opening, saving and forgetting all change it, and the home screen is often on
screen while they happen, so the host pushes rather than Elm polling.

-}
port recentsChanged : (D.Value -> msg) -> Sub msg
