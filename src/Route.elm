module Route exposing
    ( Route(..)
    , SearchArgs
    , SearchRoute
    , fromUrl
    , href
    , replaceUrl
    , routeToString
    )

import Browser.Navigation
import Html
import Html.Attributes
import Route.SearchQuery exposing (SearchQuery)
import Url
import Url.Builder exposing (QueryParameter)
import Url.Parser exposing ((</>), (<?>))
import Url.Parser.Query



-- ROUTING


type alias SearchArgs =
    { query : Maybe SearchQuery
    , channel : Maybe String
    , show : Maybe String
    , from : Maybe Int
    , size : Maybe Int
    , buckets : Maybe String

    -- TODO: embed sort type
    , sort : Maybe String
    }


type alias SearchRoute =
    SearchArgs -> Route


searchQueryParser : Url.Url -> Url.Parser.Parser (SearchArgs -> msg) msg
searchQueryParser url =
    let
        rawQuery =
            Route.SearchQuery.toRawQuery url

        maybeQuery =
            Maybe.andThen (Route.SearchQuery.searchString "query") rawQuery
    in
    Url.Parser.map (SearchArgs maybeQuery) <|
        Url.Parser.top
            <?> Url.Parser.Query.string "channel"
            <?> Url.Parser.Query.string "show"
            <?> Url.Parser.Query.int "from"
            <?> Url.Parser.Query.int "size"
            <?> Url.Parser.Query.string "buckets"
            <?> Url.Parser.Query.string "sort"


searchArgsToUrl : SearchArgs -> ( List QueryParameter, Maybe ( String, Route.SearchQuery.SearchQuery ) )
searchArgsToUrl args =
    ( List.filterMap identity
        [ Maybe.map (Url.Builder.string "channel") args.channel
        , Maybe.map (Url.Builder.string "show") args.show
        , Maybe.map (Url.Builder.int "from") args.from
        , Maybe.map (Url.Builder.int "size") args.size
        , Maybe.map (Url.Builder.string "buckets") args.buckets
        , Maybe.map (Url.Builder.string "sort") args.sort
        ]
    , Maybe.map (Tuple.pair "query") args.query
    )


type Route
    = NotFound
    | Home
    | Packages SearchArgs
    | Options SearchArgs


parser : Url.Url -> Url.Parser.Parser (Route -> msg) msg
parser url =
    Url.Parser.oneOf
        [ Url.Parser.map Home Url.Parser.top
        , Url.Parser.map NotFound <| Url.Parser.s "not-found"
        , Url.Parser.map Packages <| Url.Parser.s "packages" </> searchQueryParser url
        , Url.Parser.map Options <| Url.Parser.s "options" </> searchQueryParser url
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
    Url.Parser.parse (parser url) url



-- INTERNAL


routeToString : Route -> String
routeToString =
    let
        buildString ( path, query, searchQuery ) =
            Route.SearchQuery.absolute path query <|
                Maybe.withDefault [] <|
                    Maybe.map List.singleton searchQuery
    in
    buildString << routeToPieces


routeToPieces : Route -> ( List String, List QueryParameter, Maybe ( String, Route.SearchQuery.SearchQuery ) )
routeToPieces page =
    case page of
        Home ->
            ( [], [], Nothing )

        NotFound ->
            ( [ "not-found" ], [], Nothing )

        Packages searchArgs ->
            searchArgsToUrl searchArgs
                |> (\( query, raw ) -> ( [ "packages" ], query, raw ))

        Options searchArgs ->
            searchArgsToUrl searchArgs
                |> (\( query, raw ) -> ( [ "options" ], query, raw ))
