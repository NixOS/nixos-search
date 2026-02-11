module Page.Flakes exposing
    ( Model(..)
    , Msg
    , init
    , makeRequest
    , update
    , view
    )

import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , div
        , h1
        , strong
        , text
        )
import Html.Attributes
    exposing
        ( class
        , href
        )
import Html.Events exposing (onClick)
import Http exposing (Body)
import Page.Options exposing (Msg(..))
import Page.Packages exposing (Msg(..))
import RemoteData
import Route
    exposing
        ( SearchType(..)
        )
import Search
    exposing
        ( Msg(..)
        , NixOSChannel
        , viewFlakes
        , viewResult
        , viewSearchInput
        )



-- MODEL


type Model
    = OptionModel Page.Options.Model
    | PackagesModel Page.Packages.Model


init :
    Route.SearchArgs
    -> String
    -> List NixOSChannel
    -> Maybe Model
    -> ( Model, Cmd Msg )
init searchArgs defaultNixOSChannel nixosChannels model =
    let
        --  init with respective module or with packages by default
        searchType : SearchType
        searchType =
            Maybe.withDefault PackageSearch searchArgs.type_
    in
    case searchType of
        OptionSearch ->
            Tuple.mapBoth OptionModel (Cmd.map OptionsMsg) <|
                Page.Options.init searchArgs defaultNixOSChannel nixosChannels <|
                    case model of
                        Just (OptionModel model_) ->
                            Just model_

                        _ ->
                            Nothing

        PackageSearch ->
            Tuple.mapBoth PackagesModel (Cmd.map PackagesMsg) <|
                Page.Packages.init searchArgs defaultNixOSChannel nixosChannels <|
                    case model of
                        Just (PackagesModel model_) ->
                            Just model_

                        _ ->
                            Nothing



-- UPDATE


type Msg
    = OptionsMsg Page.Options.Msg
    | PackagesMsg Page.Packages.Msg


update :
    Browser.Navigation.Key
    -> Msg
    -> Model
    -> List NixOSChannel
    -> ( Model, Cmd Msg )
update navKey msg model nixosChannels =
    case ( msg, model ) of
        ( OptionsMsg msg_, OptionModel model_ ) ->
            case msg_ of
                Page.Options.SearchMsg subMsg ->
                    let
                        ( newModel, newCmd ) =
                            Search.update
                                Route.Flakes
                                navKey
                                subMsg
                                model_
                                nixosChannels
                    in
                    ( newModel, Cmd.map Page.Options.SearchMsg newCmd ) |> Tuple.mapBoth OptionModel (Cmd.map OptionsMsg)

        ( PackagesMsg msg_, PackagesModel model_ ) ->
            case msg_ of
                Page.Packages.SearchMsg subMsg ->
                    let
                        ( newModel, newCmd ) =
                            Search.update
                                Route.Flakes
                                navKey
                                subMsg
                                model_
                                nixosChannels
                    in
                    ( newModel, Cmd.map Page.Packages.SearchMsg newCmd ) |> Tuple.mapBoth PackagesModel (Cmd.map PackagesMsg)

        _ ->
            ( model, Cmd.none )



-- VIEW


view :
    List NixOSChannel
    -> Model
    -> Html Msg
view nixosChannels model =
    let
        resultStatus result =
            case result of
                RemoteData.NotAsked ->
                    "not-asked"

                RemoteData.Loading ->
                    "loading"

                RemoteData.Success _ ->
                    "success"

                RemoteData.Failure _ ->
                    "failure"

        bodyTitle =
            [ text "Search packages and options of "
            , strong []
                [ a
                    [ href "https://github.com/NixOS/nixos-search/blob/main/flakes/manual.toml" ]
                    [ text "public flakes" ]
                ]
            ]

        mkBody categoryName model_ viewSuccess viewBuckets outMsg =
            div
                (List.append
                    [ class <| "search-page " ++ resultStatus model_.result ]
                    (if model_.showSort then
                        [ onClick (outMsg ToggleSort) ]

                     else
                        []
                    )
                )
                [ h1 [] bodyTitle
                , viewSearchInput nixosChannels outMsg categoryName Nothing model_.query
                , viewResult nixosChannels outMsg categoryName model_ viewSuccess viewBuckets <|
                    viewFlakes outMsg model_.searchType
                ]
    in
    case model of
        OptionModel model_ ->
            Html.map OptionsMsg <| mkBody "Options" model_ Page.Options.viewSuccess Page.Options.viewBuckets Page.Options.SearchMsg

        PackagesModel model_ ->
            Html.map PackagesMsg <| mkBody "Packages" model_ Page.Packages.viewSuccess Page.Packages.viewBuckets Page.Packages.SearchMsg



-- API


makeRequest :
    Search.Options
    -> List NixOSChannel
    -> SearchType
    -> String
    -> String
    -> Int
    -> Int
    -> Maybe String
    -> Search.Sort
    -> Cmd Msg
makeRequest options nixosChannels searchType index_id query from size maybeBuckets sort =
    case searchType of
        PackageSearch ->
            Search.makeRequest
                (makeRequestBody searchType query from size maybeBuckets sort)
                nixosChannels
                index_id
                Page.Packages.decodeResultItemSource
                Page.Packages.decodeResultAggregations
                options
                Search.QueryResponse
                (Just "query-packages")
                |> Cmd.map Page.Packages.SearchMsg
                |> Cmd.map PackagesMsg

        OptionSearch ->
            Search.makeRequest
                (makeRequestBody searchType query from size maybeBuckets sort)
                nixosChannels
                index_id
                Page.Options.decodeResultItemSource
                Page.Options.decodeResultAggregations
                options
                Search.QueryResponse
                (Just "query-options")
                |> Cmd.map Page.Options.SearchMsg
                |> Cmd.map OptionsMsg


makeRequestBody : SearchType -> String -> Int -> Int -> Maybe String -> Search.Sort -> Body
makeRequestBody searchType query from size maybeBuckets sort =
    case searchType of
        OptionSearch ->
            Page.Options.makeRequestBody query from size sort

        PackageSearch ->
            Page.Packages.makeRequestBody query from size maybeBuckets sort
