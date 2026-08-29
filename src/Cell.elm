module Cell exposing (Cell, Kind(..), Status(..), isRunnable, kindLabel, statusLabel)

{-| A cell is one named top-level binding.

Identity is the binding name, not a hidden UUID. That is a deliberate
departure from Pluto: renaming a cell really is an identity change here,
because downstream cells refer to it *by that name*, so the rename has to
invalidate them. In exchange, diffs and errors talk about names the author
recognises instead of opaque ids.

-}


type alias Cell =
    { id : String
    , kind : Kind
    , source : String
    }


type Kind
    = Query
      -- External data the notebook reads but does not compute. A source is a
      -- graph node like any other, so cells that read it are ordered after it.
    | Source
    | Prose


{-| Where a cell is in the reactive lifecycle.

`Stale` and `Blocked` exist to make Jupyter's worst failure mode
unrepresentable: a cell whose displayed output no longer corresponds to the
code above it. A cell is never allowed to keep showing a value that the graph
knows is out of date.

-}
type Status
    = NeverRun
    | Stale
    | Queued
    | Running
    | Fresh { cached : Bool, millis : Float }
    | Failed String
      -- The cell did not compile. Distinct from `Failed`, which is DuckDB
      -- rejecting a query the compiler was happy with.
    | Invalid String
    | Blocked String
    | InCycle (List String)


isRunnable : Cell -> Bool
isRunnable cell =
    case cell.kind of
        Query ->
            String.trim cell.source /= ""

        Source ->
            String.trim cell.source /= ""

        Prose ->
            False


kindLabel : Kind -> String
kindLabel kind =
    case kind of
        Query ->
            "query"

        Source ->
            "source"

        Prose ->
            "prose"


statusLabel : Status -> String
statusLabel status =
    case status of
        NeverRun ->
            "never run"

        Stale ->
            "stale"

        Queued ->
            "queued"

        Running ->
            "running"

        Fresh { cached } ->
            if cached then
                "cached"

            else
                "fresh"

        Failed _ ->
            "failed"

        Invalid _ ->
            "does not compile"

        Blocked upstream ->
            "blocked by " ++ upstream

        InCycle _ ->
            "cycle"
