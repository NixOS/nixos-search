module Route.SearchQuery exposing
    ( RawQuery
    , SearchQuery
    , absolute
    , searchQueryToString
    , searchString
    , toRawQuery
    , toSearchQuery
    )

import Dict exposing (Dict)
import Url
import Url.Builder



-- RawQuery


type RawQuery
    = RawQuery (Dict String String)


chunk : String -> String -> Maybe ( String, String )
chunk sep str =
    case String.split sep str of
        [] ->
            Nothing

        [ key ] ->
            Just ( key, "" )

        key :: xs ->
            Just ( key, String.join sep xs )


toRawQuery : Url.Url -> Maybe RawQuery
toRawQuery =
    Maybe.map (RawQuery << Dict.fromList << List.filterMap (chunk "=") << String.split "&")
        << .query



-- SearchQuery


{-| This is type safe wrapper for working with search queries in url
-}
type SearchQuery
    = SearchQuery String


searchString : String -> RawQuery -> Maybe SearchQuery
searchString name (RawQuery dict) =
    Maybe.map SearchQuery <| Dict.get name dict


searchQueryToString : SearchQuery -> Maybe String
searchQueryToString (SearchQuery str) =
    Url.percentDecode <| String.replace "+" "%20" str


toSearchQuery : String -> SearchQuery
toSearchQuery query =
    SearchQuery <| String.replace "%20" "+" <| Url.percentEncode query


{-| Build absolute URL with support for search query strings
-}
absolute : List String -> List Url.Builder.QueryParameter -> List ( String, SearchQuery ) -> String
absolute path query searchQuery =
    let
        searchStrings =
            List.map (\( name, SearchQuery val ) -> name ++ "=" ++ val) searchQuery
                |> String.join "&"
    in
    Url.Builder.absolute path query
        |> (\str ->
                str
                    ++ (case query of
                            [] ->
                                "?" ++ searchStrings

                            _ ->
                                "&" ++ searchStrings
                       )
           )
