port module TestRunner exposing (main)

{-| A dependency-free test harness.

Run with `mise run test`. This deliberately avoids elm-test: the modules under
test have no effects, so a `Platform.worker` that reports a list of checks is
enough, and it keeps the project free of an npm toolchain it does not
otherwise need.

-}

import Check exposing (Check)
import DslTests
import EngineTests
import IndentTests
import NotebookTests
import SourceTests
import Json.Encode as E


port report : E.Value -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), report (E.list encode allChecks) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


allChecks : List Check
allChecks =
    EngineTests.checks ++ DslTests.checks ++ NotebookTests.checks ++ SourceTests.checks ++ IndentTests.checks


encode : Check -> E.Value
encode c =
    E.object
        [ ( "name", E.string c.name )
        , ( "ok", E.bool c.ok )
        , ( "detail", E.string c.detail )
        ]
