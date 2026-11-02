module QueryGolden exposing (requestBodies)

import Dict
import Expect
import Json.Encode
import QueryGolden.Cases exposing (cases)
import QueryGolden.Expected exposing (expected)
import Test exposing (Test)


requestBodies : Test
requestBodies =
    let
        expectedBodies =
            Dict.fromList expected
    in
    cases
        |> List.map (requestBody expectedBodies)
        |> (::) (sameCases expectedBodies)
        |> Test.describe "Request bodies"


requestBody : Dict.Dict String String -> ( String, Json.Encode.Value ) -> Test
requestBody expectedBodies ( name, body ) =
    Test.test name <|
        \_ ->
            Dict.get name expectedBodies
                |> Expect.equal (Just (Json.Encode.encode 4 body))


sameCases : Dict.Dict String String -> Test
sameCases expectedBodies =
    Test.test "has an expected body for each case and no other" <|
        \_ ->
            Dict.keys expectedBodies
                |> Expect.equalLists (List.sort (List.map Tuple.first cases))
