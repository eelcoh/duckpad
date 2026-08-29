module Hash exposing (Hash, combine, ofString, toString)

{-| FNV-1a over UTF-16 code units.

Not cryptographic, and not trying to be: this only has to be stable across
runs and well-distributed enough to key the notebook's compile and value
caches. A collision would mean reusing a stale cached value, so the cost of
being wrong is bounded by "user presses Run again".

-}

import Bitwise


type Hash
    = Hash Int


offsetBasis : Int
offsetBasis =
    2166136261


prime : Int
prime =
    16777619


ofString : String -> Hash
ofString s =
    Hash (String.foldl step offsetBasis s)


step : Char -> Int -> Int
step c acc =
    mul32 (Bitwise.xor acc (Char.toCode c)) prime


{-| 32-bit multiply. Elm's `*` runs on JS doubles, so the naive version loses
low bits once the product exceeds 2^53. Split into 16-bit halves to keep the
result exact, then force back to an unsigned 32-bit range.
-}
mul32 : Int -> Int -> Int
mul32 a b =
    let
        lo =
            Bitwise.and a 0xFFFF

        hi =
            Bitwise.shiftRightZfBy 16 a
    in
    Bitwise.shiftRightZfBy 0
        (Bitwise.shiftLeftBy 16 (hi * b) + (lo * b))


{-| Fold one hash into another so a cache key can be built from several parts
without paying to concatenate their sources.

The second hash is folded in a byte at a time rather than XORed wholesale:
XOR is commutative, which would make `combine a b` and `combine b a` collide
and let two different upstream orderings share a cache entry.

-}
combine : Hash -> Hash -> Hash
combine (Hash a) (Hash b) =
    List.foldl
        (\shift acc ->
            mul32 (Bitwise.xor acc (Bitwise.and 0xFF (Bitwise.shiftRightZfBy shift b))) prime
        )
        a
        [ 0, 8, 16, 24 ]
        |> Hash


toString : Hash -> String
toString (Hash n) =
    String.fromInt n
