port module EmitSeed exposing (main)

{-| Writes the seeded notebook out as a file.

`Seed.notebook` is what the app opens on; this serialises it through the same
`Notebook.serialize` the Save button uses, so the shipped example is the
starting notebook rather than a copy of it that has to be kept in step.

-}

import Notebook
import Seed


port emit : { markdown : String, roundTripped : String } -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), emit payload )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| The file, and the file read back and written out again. The emitter
compares them, which checks the format round-trips on real content rather than
only on the fixtures in the test suite.
-}
payload : { markdown : String, roundTripped : String }
payload =
    let
        markdown =
            Notebook.serialize Seed.notebook
    in
    { markdown = markdown
    , roundTripped =
        Notebook.parse markdown
            |> Result.map Notebook.serialize
            |> Result.withDefault "<did not parse>"
    }
