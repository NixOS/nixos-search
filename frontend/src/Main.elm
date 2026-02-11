module Main exposing (Flags, Model, Msg, Page, main)

import Browser
import Browser.Dom
import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , div
        , footer
        , header
        , img
        , li
        , small
        , span
        , sup
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( alt
        , class
        , classList
        , href
        , id
        , src
        )
import Json.Decode
import Page.Flakes exposing (Model(..))
import Page.Options
import Page.Packages
import RemoteData exposing (RemoteData(..))
import Route exposing (SearchType(..))
import Search
    exposing
        ( NixOSChannel
        , decodeNixOSChannels
        , defaultFlakeId
        )
import Shortcut
import Task
import Url



-- MODEL


type alias Flags =
    { elasticsearchMappingSchemaVersion : Int
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    , nixosChannels : Json.Decode.Value
    }


type alias Model =
    { navKey : Browser.Navigation.Key
    , route : Route.Route
    , elasticsearch : Search.Options
    , defaultNixOSChannel : String
    , nixosChannels : List NixOSChannel
    , page : Page
    }


type Page
    = NotFound
    | Packages Page.Packages.Model
    | Options Page.Options.Model
    | Flakes Page.Flakes.Model


init :
    Flags
    -> Url.Url
    -> Browser.Navigation.Key
    -> ( Model, Cmd Msg )
init flags url navKey =
    let
        nixosChannels : Search.NixOSChannels
        nixosChannels =
            case Json.Decode.decodeValue decodeNixOSChannels flags.nixosChannels of
                Ok c ->
                    c

                Err _ ->
                    { default = "", channels = [] }

        elasticSearch : Search.Options
        elasticSearch =
            { mappingSchemaVersion = flags.elasticsearchMappingSchemaVersion
            , url = flags.elasticsearchUrl
            , username = flags.elasticsearchUsername
            , password = flags.elasticsearchPassword
            }

        model : Model
        model =
            { navKey = navKey
            , elasticsearch = elasticSearch
            , defaultNixOSChannel = nixosChannels.default
            , nixosChannels = nixosChannels.channels
            , page = NotFound
            , route = Route.Home
            }
    in
    changeRouteTo model url



-- UPDATE


type Msg
    = ChangedUrl Url.Url
    | ClickedLink Browser.UrlRequest
    | PackagesMsg Page.Packages.Msg
    | OptionsMsg Page.Options.Msg
    | FlakesMsg Page.Flakes.Msg
    | CtrlKRegistered
    | SearchFocusResult


updateWith :
    (subModel -> Page)
    -> (subMsg -> Msg)
    -> Model
    -> ( subModel, Cmd subMsg )
    -> ( Model, Cmd Msg )
updateWith toPage toMsg model ( subModel, subCmd ) =
    ( { model | page = toPage subModel }
    , Cmd.map toMsg subCmd
    )


attemptQuery : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
attemptQuery (( model, _ ) as pair) =
    let
        -- We intentially throw away Cmd
        -- because we don't want to perform any effects
        -- in this cases where route itself doesn't change
        noEffects =
            Tuple.mapSecond (always Cmd.none)

        submitQuery msg makeRequest searchModel =
            Tuple.mapSecond
                (\cmd ->
                    Cmd.batch
                        [ cmd
                        , Cmd.map msg <|
                            makeRequest
                                model.elasticsearch
                                model.nixosChannels
                                searchModel.searchType
                                searchModel.channel
                                searchModel.query
                                searchModel.from
                                searchModel.size
                                searchModel.buckets
                                searchModel.sort
                        ]
                )
                pair
    in
    case model.page of
        Packages searchModel ->
            if Search.shouldLoad searchModel then
                submitQuery PackagesMsg Page.Packages.makeRequest { searchModel | searchType = PackageSearch }

            else
                noEffects pair

        Options searchModel ->
            if Search.shouldLoad searchModel then
                submitQuery OptionsMsg Page.Options.makeRequest { searchModel | searchType = OptionSearch }

            else
                noEffects pair

        Flakes (OptionModel searchModel) ->
            if Search.shouldLoad searchModel then
                submitQuery FlakesMsg Page.Flakes.makeRequest { searchModel | channel = defaultFlakeId }

            else
                noEffects pair

        Flakes (PackagesModel searchModel) ->
            if Search.shouldLoad searchModel then
                submitQuery FlakesMsg Page.Flakes.makeRequest { searchModel | channel = defaultFlakeId }

            else
                noEffects pair

        _ ->
            pair


pageMatch : Page -> Page -> Bool
pageMatch m1 m2 =
    case ( m1, m2 ) of
        ( NotFound, NotFound ) ->
            True

        ( Packages model_a, Packages model_b ) ->
            { model_a | show = Nothing, showInstallDetails = Search.Unset, result = NotAsked }
                == { model_b | show = Nothing, showInstallDetails = Search.Unset, result = NotAsked }

        ( Options model_a, Options model_b ) ->
            { model_a | show = Nothing, result = NotAsked } == { model_b | show = Nothing, result = NotAsked }

        ( Flakes (OptionModel model_a), Flakes (OptionModel model_b) ) ->
            { model_a | show = Nothing, result = NotAsked } == { model_b | show = Nothing, result = NotAsked }

        ( Flakes (PackagesModel model_a), Flakes (PackagesModel model_b) ) ->
            { model_a | show = Nothing, result = NotAsked } == { model_b | show = Nothing, result = NotAsked }

        _ ->
            False


changeRouteTo :
    Model
    -> Url.Url
    -> ( Model, Cmd Msg )
changeRouteTo currentModel url =
    let
        route : Route.Route
        route =
            Route.fromUrl url

        model =
            { currentModel | route = route }

        avoidReinit ( newModel, cmd ) =
            if pageMatch currentModel.page newModel.page then
                ( model, Cmd.none )

            else
                ( newModel, cmd )
    in
    case route of
        Route.NotFound ->
            ( { model | page = NotFound }, Cmd.none )

        Route.Home ->
            -- Always redirect to /packages until we have something to show
            -- on the home page
            ( model, Browser.Navigation.replaceUrl model.navKey "/packages" )

        Route.Packages searchArgs ->
            let
                modelPage =
                    case model.page of
                        Packages x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Packages.init searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels modelPage
                |> updateWith Packages PackagesMsg model
                |> avoidReinit
                |> attemptQuery

        Route.Options searchArgs ->
            let
                modelPage =
                    case model.page of
                        Options x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Options.init searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels modelPage
                |> updateWith Options OptionsMsg model
                |> avoidReinit
                |> attemptQuery

        Route.Flakes searchArgs ->
            let
                modelPage =
                    case model.page of
                        Flakes x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Flakes.init searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels modelPage
                |> updateWith Flakes FlakesMsg model
                |> avoidReinit
                |> attemptQuery


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.page ) of
        ( ClickedLink urlRequest, _ ) ->
            case urlRequest of
                Browser.Internal url ->
                    ( model
                    , Browser.Navigation.pushUrl model.navKey <| Url.toString url
                    )

                Browser.External href ->
                    ( model
                    , case href of
                        -- ignore links with no `href` attribute
                        "" ->
                            Cmd.none

                        _ ->
                            Browser.Navigation.load href
                    )

        ( ChangedUrl url, _ ) ->
            changeRouteTo model url

        ( PackagesMsg subMsg, Packages subModel ) ->
            Page.Packages.update model.navKey subMsg subModel model.nixosChannels
                |> updateWith Packages PackagesMsg model

        ( OptionsMsg subMsg, Options subModel ) ->
            Page.Options.update model.navKey subMsg subModel model.nixosChannels
                |> updateWith Options OptionsMsg model

        ( FlakesMsg subMsg, Flakes subModel ) ->
            Page.Flakes.update model.navKey subMsg subModel model.nixosChannels
                |> updateWith Flakes FlakesMsg model

        ( CtrlKRegistered, _ ) ->
            ( model, Browser.Dom.focus "search-query-input" |> Task.attempt (\_ -> SearchFocusResult) )

        _ ->
            -- Disregard messages that arrived for the wrong page.
            ( model, Cmd.none )



-- VIEW


view :
    Model
    ->
        { title : String
        , body : List (Html Msg)
        }
view model =
    let
        maybeQuery q =
            if String.isEmpty q then
                ""

            else
                " - " ++ q

        maybeFlakeQuery m =
            case m of
                OptionModel m_ ->
                    maybeQuery m_.query

                PackagesModel m_ ->
                    maybeQuery m_.query

        title =
            case model.page of
                Packages m ->
                    "NixOS Search - Packages" ++ maybeQuery m.query

                Options m ->
                    "NixOS Search - Options" ++ maybeQuery m.query

                Flakes m ->
                    "NixOS Search - Flakes (Experimental)" ++ maybeFlakeQuery m

                _ ->
                    "NixOS Search"
    in
    { title = title
    , body =
        [ Shortcut.shortcutElement
            [ { msg = CtrlKRegistered
              , keyCombination =
                    { baseKey = Shortcut.Regular "K"
                    , shift = Nothing
                    , alt = Nothing
                    , meta = Nothing
                    , ctrl = Just True
                    }
              }
            , Shortcut.simpleShortcut (Shortcut.Regular "/") <| CtrlKRegistered
            ]
            [ id "shortcut-list-el" ]
            [ div []
                [ header []
                    [ div [ class "navbar navbar-static-top" ]
                        [ div [ class "navbar-inner" ]
                            [ div [ class "container" ]
                                [ a [ class "brand", href "https://nixos.org" ]
                                    [ img [ alt "NixOS logo", src "/images/nix-logo.png", class "logo" ] []
                                    ]
                                , div []
                                    [ ul [ class "nav pull-left" ]
                                        (viewNavigation model.route)
                                    ]
                                ]
                            ]
                        ]
                    ]
                , div [ class "container main" ]
                    [ div [ id "content" ] [ viewPage model ]
                    , footer
                        [ class "container text-center" ]
                        [ div []
                            [ span [] [ text "Please help us improve the search by " ]
                            , a
                                [ href "https://github.com/NixOS/nixos-search/issues"
                                ]
                                [ text "reporting issues" ]
                            , span [] [ text "." ]
                            ]
                        , div []
                            [ span [] [ text "❤️  " ]
                            , span [] [ text "Elasticsearch instance graciously provided by " ]
                            , a [ href "https://bonsai.io" ] [ text "Bonsai" ]
                            , span [] [ text ". Thank you! ❤️ " ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }


viewNavigation : Route.Route -> List (Html Msg)
viewNavigation route =
    let
        -- Preserve most arguments
        searchArgs =
            (\args -> { args | from = Nothing, buckets = Nothing }) <|
                case route of
                    Route.Packages args ->
                        args

                    Route.Options args ->
                        args

                    Route.Flakes args ->
                        args

                    _ ->
                        Route.SearchArgs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    in
    li [] [ a [ href "https://nixos.org" ] [ text "Back to nixos.org" ] ]
        :: List.map
            (viewNavigationItem route)
            [ ( Route.Packages searchArgs, text "Packages" )
            , ( Route.Options searchArgs, text "NixOS options" )
            , ( Route.Flakes searchArgs, span [] [ text "Flakes", sup [] [ span [ class "label label-info" ] [ small [] [ text "Experimental" ] ] ] ] )
            ]
        ++ [ li [] [ a [ href "https://wiki.nixos.org" ] [ text "NixOS Wiki" ] ] ]


viewNavigationItem :
    Route.Route
    -> ( Route.Route, Html Msg )
    -> Html Msg
viewNavigationItem currentRoute ( route, title ) =
    li
        [ classList [ ( "active", currentRoute == route ) ] ]
        [ a [ Route.href route ] [ title ] ]


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        NotFound ->
            div [] [ text "Not Found" ]

        Packages packagesModel ->
            Html.map (\m -> PackagesMsg m) <| Page.Packages.view model.nixosChannels packagesModel

        Options optionsModel ->
            Html.map (\m -> OptionsMsg m) <| Page.Options.view model.nixosChannels optionsModel

        Flakes flakesModel ->
            Html.map (\m -> FlakesMsg m) <| Page.Flakes.view model.nixosChannels flakesModel



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- MAIN


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , onUrlRequest = ClickedLink
        , onUrlChange = ChangedUrl
        , subscriptions = subscriptions
        , update = update
        , view = view
        }
