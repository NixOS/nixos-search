module Route exposing
    ( Route(..)
    , SearchArgs
    , SearchRoute
    , SearchType(..)
    , allTypes
    , fromUrl
    , href
    , routeToString
    , searchTypeToTitle
    )

import AppUrl exposing (AppUrl)
import Dict
import Html
import Html.Attributes
import Maybe.Extra
import Url



-- ROUTING


type alias SearchArgs =
    { query : Maybe String
    , channel : Maybe String
    , show : Maybe String
    , from : Maybe Int
    , size : Maybe Int
    , buckets : Maybe String
    , sort : Maybe String
    , type_ : Maybe SearchType
    }


type SearchType
    = OptionSearch
    | PackageSearch



-- | FlakeSearch


allTypes : List SearchType
allTypes =
    [ PackageSearch, OptionSearch ]


searchTypeFromString : String -> Maybe SearchType
searchTypeFromString string =
    case string of
        "options" ->
            Just OptionSearch

        "packages" ->
            Just PackageSearch

        -- "flakes" ->
        --     Just FlakeSearch
        _ ->
            Nothing


searchTypeToString : SearchType -> String
searchTypeToString stype =
    case stype of
        OptionSearch ->
            "options"

        PackageSearch ->
            "packages"



-- FlakeSearch ->
--     "flakes"


searchTypeToTitle : SearchType -> String
searchTypeToTitle stype =
    case stype of
        OptionSearch ->
            "Options"

        PackageSearch ->
            "Packages"



-- FlakeSearch ->
--     "flakes"


type alias SearchRoute =
    SearchArgs -> Route


searchQueryParser : AppUrl -> SearchArgs
searchQueryParser appUrl =
    let
        string : String -> Maybe String
        string k =
            case Dict.get k appUrl.queryParameters of
                Just [ v ] ->
                    Just v

                _ ->
                    Nothing

        int : String -> Maybe Int
        int k =
            case Dict.get k appUrl.queryParameters of
                Just [ v ] ->
                    String.toInt v

                _ ->
                    Nothing
    in
    { query = string "query"
    , channel = string "channel"
    , show = string "show"
    , from = int "from"
    , size = int "size"
    , buckets = string "buckets"
    , sort = string "sort"
    , type_ = Maybe.andThen searchTypeFromString (string "type")
    }


searchArgsToUrl : SearchArgs -> AppUrl.QueryParameters
searchArgsToUrl args =
    let
        string : String -> Maybe String -> Maybe ( String, List String )
        string k v =
            Maybe.map (\s -> ( k, [ s ] )) v

        int : String -> Maybe Int -> Maybe ( String, List String )
        int k v =
            Maybe.map (\i -> ( k, [ String.fromInt i ] )) v
    in
    [ string "channel" args.channel
    , string "show" args.show
    , int "from" args.from
    , int "size" args.size
    , string "buckets" args.buckets
    , string "sort" args.sort
    , string "type" <| Maybe.map searchTypeToString args.type_
    , string "query" args.query
    ]
        |> Maybe.Extra.values
        |> Dict.fromList


type Route
    = NotFound
    | Home
    | Packages SearchArgs
    | Options SearchArgs
    | Flakes SearchArgs


fromUrl : Url.Url -> Route
fromUrl url =
    let
        appUrl : AppUrl
        appUrl =
            AppUrl.fromUrl url
    in
    case appUrl.path of
        [] ->
            Home

        [ "packages" ] ->
            Packages (searchQueryParser appUrl)

        [ "options" ] ->
            Options (searchQueryParser appUrl)

        [ "flakes" ] ->
            Flakes (searchQueryParser appUrl)

        _ ->
            NotFound



-- PUBLIC HELPERS


href : Route -> Html.Attribute msg
href targetRoute =
    Html.Attributes.href (routeToString targetRoute)



-- INTERNAL


routeToString : Route -> String
routeToString route =
    let
        ( path, queryParameters ) =
            case route of
                Home ->
                    ( [], Dict.empty )

                NotFound ->
                    ( [ "not-found" ], Dict.empty )

                Packages searchArgs ->
                    ( [ "packages" ], searchArgsToUrl searchArgs )

                Options searchArgs ->
                    ( [ "options" ], searchArgsToUrl searchArgs )

                Flakes searchArgs ->
                    ( [ "flakes" ], searchArgsToUrl searchArgs )
    in
    AppUrl.toString { path = path, queryParameters = queryParameters, fragment = Nothing }
