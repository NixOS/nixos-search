module Route exposing
    ( OptionSource(..)
    , Route(..)
    , SearchArgs
    , SearchRoute
    , SearchType(..)
    , allOptionSources
    , allTypes
    , fromUrl
    , href
    , optionSourceDocType
    , optionSourceId
    , optionSourceLabel
    , routeToString
    , searchTypeToTitle
    )

import AppUrl exposing (AppUrl)
import Dict
import Html
import Html.Attributes
import Maybe.Extra
import Set exposing (Set)
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
    , excludedOptionSources : Set String
    }


{-| Kinds of options that can be shown on the Options page. Each source maps
to an Elasticsearch document `type` and has its own checkbox in the UI.
Add a new variant here (plus its cases below) to expose it to the page.
-}
type OptionSource
    = NixosOptions
    | ModularServiceOptions


allOptionSources : List OptionSource
allOptionSources =
    [ NixosOptions, ModularServiceOptions ]


{-| Stable identifier used in URL parameter names and the excluded-sources set.
-}
optionSourceId : OptionSource -> String
optionSourceId source =
    case source of
        NixosOptions ->
            "nixos"

        ModularServiceOptions ->
            "modular_service"


{-| Elasticsearch document `type` field value.
-}
optionSourceDocType : OptionSource -> String
optionSourceDocType source =
    case source of
        NixosOptions ->
            "option"

        ModularServiceOptions ->
            "service"


{-| Human-readable checkbox label.
-}
optionSourceLabel : OptionSource -> String
optionSourceLabel source =
    case source of
        NixosOptions ->
            "NixOS"

        ModularServiceOptions ->
            "Modular services"


optionSourceUrlParam : OptionSource -> String
optionSourceUrlParam source =
    "include_" ++ optionSourceId source ++ "_options"


type SearchType
    = OptionSearch
    | PackageSearch



-- | FlakeSearch
-- Sub-navigation inside the 3rd-party Flakes page.


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
    , excludedOptionSources =
        -- Each source defaults to included; URL explicitly says "0" to exclude.
        allOptionSources
            |> List.filterMap
                (\source ->
                    if string (optionSourceUrlParam source) == Just "0" then
                        Just (optionSourceId source)

                    else
                        Nothing
                )
            |> Set.fromList
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
        ++ List.map
            (\source ->
                let
                    value =
                        if Set.member (optionSourceId source) args.excludedOptionSources then
                            "0"

                        else
                            "1"
                in
                string (optionSourceUrlParam source) (Just value)
            )
            allOptionSources
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
