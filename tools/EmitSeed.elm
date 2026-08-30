port module EmitSeed exposing (main)

{-| Writes the seeded notebook out as a file.

`Seed.notebook` is what the app opens on and `Tutorial.notebook` teaches the
language; both are serialised through the same `Notebook.serialize` the Save
button uses, so what ships is the real thing rather than a copy that has to be
kept in step.

-}

import Notebook
import Seed
import Tutorial


port emit : List { name : String, markdown : String, roundTripped : String } -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), emit (List.map payload notebooks) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


notebooks : List ( String, Notebook.Notebook )
notebooks =
    [ ( "flights.duckpad.md", Seed.notebook )
    , ( "tutorial.duckpad.md", Tutorial.notebook )
    ]


{-| The file, and the file read back and written out again. The emitter
compares them, which checks the format round-trips on real content rather than
only on the fixtures in the test suite.
-}
payload : ( String, Notebook.Notebook ) -> { name : String, markdown : String, roundTripped : String }
payload ( name, notebook ) =
    let
        markdown =
            Notebook.serialize notebook
    in
    { name = name
    , markdown = markdown
    , roundTripped =
        Notebook.parse markdown
            |> Result.map Notebook.serialize
            |> Result.withDefault "<did not parse>"
    }
