module HistoryTests exposing (checks)

import Check exposing (Check, equal)
import History


checks : List Check
checks =
    [ equal "history: a recorded value can be undone"
        (Just 1)
        (History.empty |> History.record 1 |> History.undo 2 |> Maybe.map Tuple.first)
    , equal "history: undo makes the current value redoable"
        (Just 2)
        (History.empty
            |> History.record 1
            |> History.undo 2
            |> Maybe.andThen (\( previous, history ) -> History.redo previous history)
            |> Maybe.map Tuple.first
        )
    , equal "history: a new edit clears the redo branch"
        Nothing
        (History.empty
            |> History.record 1
            |> History.undo 2
            |> Maybe.map (\( _, history ) -> History.record 3 history)
            |> Maybe.andThen (History.redo 4)
        )
    , equal "history: empty history disables both directions"
        ( False, False )
        ( History.canUndo History.empty, History.canRedo History.empty )
    , equal "history: only the latest one hundred snapshots are retained"
        100
        (List.range 1 110
            |> List.foldl History.record History.empty
            |> countUndos 111
        )
    ]


countUndos : a -> History.History a -> Int
countUndos current history =
    case History.undo current history of
        Just ( previous, remaining ) ->
            1 + countUndos previous remaining

        Nothing ->
            0
