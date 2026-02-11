module UrlRoundtrip exposing (routeRoundtrips, searchQueryRoundtrips)

import Expect
import Fuzz exposing (Fuzzer)
import Route exposing (Route, SearchArgs, SearchType)
import Route.SearchQuery as SearchQuery exposing (SearchQuery)
import Test exposing (Test)
import Url


routeRoundtrips : Test
routeRoundtrips =
    Test.fuzz routeFuzzer "Route roundtrips" <|
        \route ->
            ("http://localhost" ++ Route.routeToString route)
                |> Url.fromString
                |> Maybe.andThen Route.fromUrl
                |> Expect.equal (Just route)


searchQueryRoundtrips : Test
searchQueryRoundtrips =
    Test.fuzz searchQueryFuzzer "Search query roundtrips" <|
        \searchQuery ->
            searchQuery
                |> SearchQuery.searchQueryToString
                |> Maybe.map SearchQuery.toSearchQuery
                |> Expect.equal (Just searchQuery)


routeFuzzer : Fuzzer Route
routeFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Route.NotFound
        , Fuzz.constant Route.Home
        , Fuzz.map Route.Packages searchArgsFuzzer
        , Fuzz.map Route.Options searchArgsFuzzer
        , Fuzz.map Route.Flakes searchArgsFuzzer
        ]


searchArgsFuzzer : Fuzzer SearchArgs
searchArgsFuzzer =
    Fuzz.constant SearchArgs
        |> Fuzz.andMap (Fuzz.maybe searchQueryFuzzer)
        |> Fuzz.andMap (Fuzz.maybe Fuzz.string)
        |> Fuzz.andMap (Fuzz.maybe Fuzz.string)
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.intAtLeast 0))
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.intAtLeast 0))
        |> Fuzz.andMap (Fuzz.maybe Fuzz.string)
        |> Fuzz.andMap (Fuzz.maybe Fuzz.string)
        |> Fuzz.andMap (Fuzz.maybe searchTypeFuzzer)


searchQueryFuzzer : Fuzzer SearchQuery
searchQueryFuzzer =
    Fuzz.map SearchQuery.toSearchQuery Fuzz.string


searchTypeFuzzer : Fuzzer SearchType
searchTypeFuzzer =
    Fuzz.oneOfValues [ Route.OptionSearch, Route.PackageSearch ]
