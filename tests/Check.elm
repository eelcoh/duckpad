module Check exposing (Check, assert, equal, isErr)

{-| The shared vocabulary for the test modules. Kept separate so the harness,
the engine tests and the DSL tests do not have to import each other.
-}


type alias Check =
    { name : String
    , ok : Bool
    , detail : String
    }


assert : String -> Bool -> Check
assert name ok =
    { name = name, ok = ok, detail = "" }


equal : String -> a -> a -> Check
equal name expected actual =
    { name = name
    , ok = expected == actual
    , detail =
        if expected == actual then
            ""

        else
            "expected " ++ Debug.toString expected ++ "\n      got      " ++ Debug.toString actual
    }


{-| For cases where the point is that compilation refuses, and pinning the
exact message would make the test brittle.
-}
isErr : String -> Result e a -> Check
isErr name result =
    case result of
        Err _ ->
            { name = name, ok = True, detail = "" }

        Ok value ->
            { name = name, ok = False, detail = "expected a failure, got " ++ Debug.toString value }
