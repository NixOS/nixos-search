module Route exposing (Route(..), fromUrl, href, replaceUrl)

import Basics.Extra exposing (uncurry)
import Browser.Navigation
import Html
import Html.Attributes
import Url
import Url.Builder as Builder exposing (QueryParameter)
import Url.Parser exposing ((<?>))
import Url.Parser.Query as Query



-- ROUTING


type Route
    = NotFound
    | Home
    | Packages (Maybe String) (Maybe String) (Maybe String) (Maybe Int) (Maybe Int) (Maybe String)
    | Options (Maybe String) (Maybe String) (Maybe String) (Maybe Int) (Maybe Int) (Maybe String)


{-| Fixes issue with elm/url not properly escaping string
-}
queryString : String -> Query.Parser (Maybe String)
queryString =
    Query.map (Maybe.andThen Url.percentDecode) << Query.string


parser : Url.Parser.Parser (Route -> msg) msg
parser =
    Url.Parser.oneOf
        [ Url.Parser.map Home Url.Parser.top
        , Url.Parser.map NotFound (Url.Parser.s "not-found")
        , Url.Parser.map Packages
            (Url.Parser.s "packages"
                <?> queryString "channel"
                <?> queryString "query"
                <?> queryString "show"
                <?> Query.int "from"
                <?> Query.int "size"
                <?> queryString "sort"
            )
        , Url.Parser.map Options
            (Url.Parser.s "options"
                <?> queryString "channel"
                <?> queryString "query"
                <?> queryString "show"
                <?> Query.int "from"
                <?> Query.int "size"
                <?> queryString "sort"
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
    uncurry Builder.absolute << routeToPieces


{-| Fixes issue with elm/url not properly escaping string
-}
builderString : String -> String -> QueryParameter
builderString name =
    Builder.string name << Url.percentEncode


routeToPieces : Route -> ( List String, List QueryParameter )
routeToPieces page =
    let
        channelQ =
            Maybe.map (builderString "channel")

        queryQ =
            Maybe.map (builderString "query")

        showQ =
            Maybe.map (builderString "show")

        fromQ =
            Maybe.map (Builder.int "from")

        sizeQ =
            Maybe.map (Builder.int "size")

        sortQ =
            Maybe.map (builderString "sort")
    in
    Tuple.mapSecond (List.filterMap identity) <|
        case page of
            Home ->
                ( [], [] )

            NotFound ->
                ( [ "not-found" ], [] )

            Packages channel query show from size sort ->
                ( [ "packages" ]
                , [ channelQ channel
                  , queryQ query
                  , showQ show
                  , fromQ from
                  , sizeQ size
                  , sortQ sort
                  ]
                )

            Options channel query show from size sort ->
                ( [ "options" ]
                , [ channelQ channel
                  , queryQ query
                  , showQ show
                  , fromQ from
                  , sizeQ size
                  , sortQ sort
                  ]
                )
