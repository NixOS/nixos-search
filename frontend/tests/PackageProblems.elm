module PackageProblems exposing (problemKindsFilter, toggle)

import Expect
import Json.Decode as D
import Page.Packages exposing (toggleProblemKind)
import Search
import Search.Query exposing (problemKindsField)
import Test exposing (Test)


toggle : Test
toggle =
    Test.describe "toggleProblemKind"
        [ Test.test "selects a value" <|
            \_ -> toggleProblemKind [ "not removal" ] "broken" |> List.sort |> Expect.equal [ "broken", "not removal" ]
        , Test.test "clears a selected value" <|
            \_ -> toggleProblemKind [ "broken" ] "broken" |> Expect.equal []
        , Test.test "selecting `not broken` clears `broken`" <|
            \_ -> toggleProblemKind [ "broken", "removal" ] "not broken" |> List.sort |> Expect.equal [ "not broken", "removal" ]
        , Test.test "selecting `broken` clears `not broken`" <|
            \_ -> toggleProblemKind [ "not broken" ] "broken" |> Expect.equal [ "broken" ]
        ]


{-| The filter clauses of one facet, under the given `bool` occurrence type.
-}
bucketClauses : String -> String -> List String -> Result D.Error Int
bucketClauses occurrence field values =
    Search.Query.packagesBody "" 0 10 Search.Relevance [ ( field, values ) ]
        |> D.decodeValue
            (D.at [ "post_filter", "bool", "must" ]
                (D.index 0 (D.at [ "bool", occurrence ] (D.list D.value) |> D.map List.length))
            )


problemKindsFilter : Test
problemKindsFilter =
    Test.describe "bucket filters"
        [ Test.test "values of the problems facet narrow the results" <|
            \_ ->
                bucketClauses "must" problemKindsField [ "not broken", "not removal" ]
                    |> Expect.equal (Ok 2)
        , Test.test "values of another facet extend the results" <|
            \_ ->
                bucketClauses "should" "package_license_set" [ "MIT", "BSD" ]
                    |> Expect.equal (Ok 2)
        ]
