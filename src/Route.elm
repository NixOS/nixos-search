module Route exposing (Route(..), fromUrl, href, replaceUrl, routeToString)

import Browser.Navigation
import Html
import Html.Attributes
import Url
import Url.Builder exposing (QueryParameter)
import Url.Parser exposing ((<?>))
import Url.Parser.Query


{-| This is type safe wrapper for working with search queries in url
-}
type SearchQuery
    = SearchQuery String


unSearchQuery : SearchQuery -> String
unSearchQuery (SearchQuery str) =
    str



-- ROUTING


type Route
    = NotFound
    | Home
    | Packages (Maybe String) (Maybe String) (Maybe String) (Maybe Int) (Maybe Int) (Maybe String)
    | Options (Maybe String) (Maybe String) (Maybe String) (Maybe Int) (Maybe Int) (Maybe String)


{-| Decode from url with browser search support
-}
querySearchString : String -> Url.Parser.Query.Parser (Maybe SearchQuery)
querySearchString =
    Url.Parser.Query.map (Maybe.map (SearchQuery << String.replace "+" " "))
        << Url.Parser.Query.string


parser : Url.Parser.Parser (Route -> msg) msg
parser =
    Url.Parser.oneOf
        [ Url.Parser.map Home Url.Parser.top
        , Url.Parser.map NotFound (Url.Parser.s "not-found")
        , Url.Parser.map Packages
            (Url.Parser.s "packages"
                <?> Url.Parser.Query.string "channel"
                <?> Url.Parser.Query.map (Maybe.map unSearchQuery) (querySearchString "query")
                <?> Url.Parser.Query.string "show"
                <?> Url.Parser.Query.int "from"
                <?> Url.Parser.Query.int "size"
                <?> Url.Parser.Query.string "sort"
            )
        , Url.Parser.map Options
            (Url.Parser.s "options"
                <?> Url.Parser.Query.string "channel"
                <?> Url.Parser.Query.map (Maybe.map unSearchQuery) (querySearchString "query")
                <?> Url.Parser.Query.string "show"
                <?> Url.Parser.Query.int "from"
                <?> Url.Parser.Query.int "size"
                <?> Url.Parser.Query.string "sort"
            )
        ]



-- PUBLIC HELPERS


href : Route -> Html.Attribute msg
href targetRoute =
    Html.Attributes.href (routeToString targetRoute)


replaceUrl : Browser.Navigation.Key -> Route -> Cmd msg
replaceUrl navKey route =
    Browser.Navigation.replaceUrl navKey (routeToString route)


fromUrl : Url.Url -> Maybe Route
fromUrl url =
    -- The RealWorld spec treats the fragment like a path.
    -- This makes it *literally* the path, so we can proceed
    -- with parsing as if it had been a normal path all along.
    --{ url | path = Maybe.withDefault "" url.fragment, fragment = Nothing }
    Url.Parser.parse parser url



-- INTERNAL


routeToString : Route -> String
routeToString =
    let
        buildString ( path, query, searchQuery ) =
            Url.Builder.absolute path query
                |> (\str ->
                        case searchQuery of
                            Just ( name, SearchQuery val ) ->
                                case query of
                                    [] ->
                                        str ++ "?" ++ name ++ "=" ++ val

                                    _ ->
                                        str ++ "&" ++ name ++ "=" ++ val

                            Nothing ->
                                str
                   )

        -- \( path, query, searchQuery ) -> Url.Builder.absolute path query
    in
    buildString << routeToPieces


{-| Encode the url with browser search support
-}
builderSearchString : String -> String -> ( String, SearchQuery )
builderSearchString name query =
    ( name, SearchQuery <| String.replace "%20" "+" <| Url.percentEncode query )


routeToPieces : Route -> ( List String, List QueryParameter, Maybe ( String, SearchQuery ) )
routeToPieces page =
    let
        channelQ =
            Maybe.map (Url.Builder.string "channel")

        queryQ =
            Maybe.map (builderSearchString "query")

        showQ =
            Maybe.map (Url.Builder.string "show")

        fromQ =
            Maybe.map (Url.Builder.int "from")

        sizeQ =
            Maybe.map (Url.Builder.int "size")

        sortQ =
            Maybe.map (Url.Builder.string "sort")
    in
    (\( path, urlQ, searchQuery ) -> ( path, List.filterMap identity urlQ, searchQuery )) <|
        case page of
            Home ->
                ( [], [], Nothing )

            NotFound ->
                ( [ "not-found" ], [], Nothing )

            Packages channel query show from size sort ->
                ( [ "packages" ]
                , [ channelQ channel
                  , showQ show
                  , fromQ from
                  , sizeQ size
                  , sortQ sort
                  ]
                , queryQ query
                )

            Options channel query show from size sort ->
                ( [ "options" ]
                , [ channelQ channel
                  , showQ show
                  , fromQ from
                  , sizeQ size
                  , sortQ sort
                  ]
                , queryQ query
                )
