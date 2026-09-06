module History exposing (History, canRedo, canUndo, empty, record, redo, undo)

{-| A bounded, branching history for document snapshots.

The value being edited lives outside this structure. Recording stores the
value before an edit and clears the redo branch; undo and redo exchange the
current value with one side of the history.
-}


type History a
    = History
        { past : List a
        , future : List a
        }


limit : Int
limit =
    100


empty : History a
empty =
    History { past = [], future = [] }


record : a -> History a -> History a
record current (History history) =
    History
        { past = List.take limit (current :: history.past)
        , future = []
        }


undo : a -> History a -> Maybe ( a, History a )
undo current (History history) =
    case history.past of
        previous :: rest ->
            Just
                ( previous
                , History { past = rest, future = current :: history.future }
                )

        [] ->
            Nothing


redo : a -> History a -> Maybe ( a, History a )
redo current (History history) =
    case history.future of
        next :: rest ->
            Just
                ( next
                , History { past = current :: history.past, future = rest }
                )

        [] ->
            Nothing


canUndo : History a -> Bool
canUndo (History history) =
    not (List.isEmpty history.past)


canRedo : History a -> Bool
canRedo (History history) =
    not (List.isEmpty history.future)
