module Page.Flakes exposing (Model(..), Msg(..), init, makeRequest, update, view)

import Browser.Navigation
import Html exposing (Html, a, code, div, li, nav, pre, strong, text, ul)
import Html.Attributes exposing (class, classList, href, target)
import Html.Events exposing (onClick)
import Html.Parser
import Html.Parser.Util
import Http exposing (Body)
import Json.Decode exposing (Decoder)
import Page.Options
import Page.Packages exposing (Msg(..))
import Route exposing (Route(..), SearchArgs, SearchType(..))
import Search
import View.Components



-- MODEL


type Model
    = OptionModel Page.Options.Model
    | PackagesModel Page.Packages.Model


init : Route.SearchArgs -> Maybe Model -> ( Model, Cmd Msg )
init searchArgs model =
    let
        -- _ =
        --     Debug.log "Flakes" "init"
        --  init with respective module or with packages by default
        searchType =
            Maybe.withDefault PackageSearch searchArgs.type_

        mapEitherModel m =
            case ( searchType, m ) of
                ( OptionSearch, OptionModel model_ ) ->
                    Tuple.mapBoth OptionModel (Cmd.map OptionsMsg) <| Page.Options.init searchArgs <| Just model_

                ( PackageSearch, PackagesModel model_ ) ->
                    Tuple.mapBoth PackagesModel (Cmd.map PackagesMsg) <| Page.Packages.init searchArgs <| Just model_

                _ ->
                    default

        default =
            case searchType of
                PackageSearch ->
                    Tuple.mapBoth PackagesModel (Cmd.map PackagesMsg) <| Page.Packages.init searchArgs Nothing

                OptionSearch ->
                    Tuple.mapBoth OptionModel (Cmd.map OptionsMsg) <| Page.Options.init searchArgs Nothing

        ( newModel, newCmd ) =
            Maybe.withDefault default <| Maybe.map mapEitherModel model

        -- _ =
        --     Debug.log "mapped Model" <| Maybe.map mapEitherModel model
    in
    ( newModel
    , newCmd
    )



-- UPDATE


type Msg
    = OptionsMsg Page.Options.Msg
    | PackagesMsg Page.Packages.Msg


update :
    Browser.Navigation.Key
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update navKey msg model =
    -- let
    --     _ =
    --         Debug.log "Flake update" ( msg, model )
    -- in
    case ( msg, model ) of
        ( OptionsMsg msg_, OptionModel model_ ) ->
            case msg_ of
                Page.Options.SearchMsg subMsg ->
                    let
                        -- _ =
                        --     Debug.log "update - options"
                        ( newModel, newCmd ) =
                            Search.update
                                Route.Flakes
                                navKey
                                subMsg
                                model_
                    in
                    ( newModel, Cmd.map Page.Options.SearchMsg newCmd ) |> Tuple.mapBoth OptionModel (Cmd.map OptionsMsg)

        ( PackagesMsg msg_, PackagesModel model_ ) ->
            case msg_ of
                Page.Packages.SearchMsg subMsg ->
                    let
                        -- _ =
                        --     Debug.log "Flakes" "update - packages"
                        ( newModel, newCmd ) =
                            Search.update
                                Route.Flakes
                                navKey
                                subMsg
                                model_
                    in
                    ( newModel, Cmd.map Page.Packages.SearchMsg newCmd ) |> Tuple.mapBoth PackagesModel (Cmd.map PackagesMsg)

        _ ->
            ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    let
        mkBody =
            View.Components.body { toRoute = Route.Flakes, categoryName = "options" }
                [ text "Search more than "
                , strong [] [ text "10 000 options" ]
                ]

        -- _ =
        --     Debug.log "flakes view renders" model
        body =
            case model of
                OptionModel model_ ->
                    Html.map OptionsMsg <| mkBody model_ Page.Options.viewSuccess Page.Options.viewBuckets Page.Options.SearchMsg

                PackagesModel model_ ->
                    Html.map PackagesMsg <| mkBody model_ Page.Packages.viewSuccess Page.Packages.viewBuckets Page.Packages.SearchMsg
    in
    body



-- API


makeRequest :
    Search.Options
    -> SearchType
    -> String
    -> String
    -> Int
    -> Int
    -> Maybe String
    -> Search.Sort
    -> Cmd Msg
makeRequest options searchType channel query from size maybeBuckets sort =
    let
        cmd =
            case searchType of
                PackageSearch ->
                    Search.makeRequest
                        (makeRequestBody searchType query from size maybeBuckets sort)
                        (String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
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
                        (String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
                        Page.Options.decodeResultItemSource
                        Page.Options.decodeResultAggregations
                        options
                        Search.QueryResponse
                        (Just "query-options")
                        |> Cmd.map Page.Options.SearchMsg
                        |> Cmd.map OptionsMsg

        -- FlakeSearch ->
        --     Debug.todo "branch 'FlakeSearch' not implemented"
    in
    cmd


makeRequestBody : SearchType -> String -> Int -> Int -> Maybe String -> Search.Sort -> Body
makeRequestBody searchType query from size maybeBuckets sort =
    case searchType of
        OptionSearch ->
            Page.Options.makeRequestBody query from size sort

        PackageSearch ->
            Page.Packages.makeRequestBody query from size maybeBuckets sort



-- FlakeSearch ->
--     Debug.todo "branch 'FlakeSearch' not implemented"
