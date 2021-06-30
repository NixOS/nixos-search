module Main exposing (main)

import Browser
import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , button
        , div
        , footer
        , header
        , img
        , li
        , span
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( attribute
        , class
        , classList
        , href
        , id
        , src
        , type_
        )
import Page.Flakes exposing (Model(..))
import Page.Home
import Page.Options
import Page.Packages
import Route exposing (SearchType(..))
import Search
import Url
import Search exposing (defaultFlakeId)
import Search exposing (channels)



-- MODEL


type alias Flags =
    { elasticsearchMappingSchemaVersion : Int
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    }


type alias Model =
    { navKey : Browser.Navigation.Key
    , route : Route.Route
    , elasticsearch : Search.Options
    , page : Page
    }


type Page
    = NotFound
    | Home Page.Home.Model
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
        model =
            { navKey = navKey
            , elasticsearch =
                Search.Options
                    flags.elasticsearchMappingSchemaVersion
                    flags.elasticsearchUrl
                    flags.elasticsearchUsername
                    flags.elasticsearchPassword
            , page = NotFound
            , route = Route.Home
            }
    in
    changeRouteTo model url



-- UPDATE


type Msg
    = ChangedUrl Url.Url
    | ClickedLink Browser.UrlRequest
    | HomeMsg Page.Home.Msg
    | PackagesMsg Page.Packages.Msg
    | OptionsMsg Page.Options.Msg
    | FlakesMsg Page.Flakes.Msg


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
                                searchModel.searchType
                                searchModel.channel
                                (Maybe.withDefault "" searchModel.query)
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
                submitQuery FlakesMsg Page.Flakes.makeRequest {searchModel | channel = defaultFlakeId }

            else
                noEffects pair

        Flakes (PackagesModel searchModel) ->
            if Search.shouldLoad searchModel then
                -- let
                --     _ = Debug.log "main" "submit flake message"
                -- in
                submitQuery FlakesMsg Page.Flakes.makeRequest {searchModel | channel = defaultFlakeId}

            else
                --   let _ = Debug.log "main" "should not load flakes" in
                noEffects pair

        _ ->
            -- let
            --  _ = Debug.log "pair" <| Debug.toString pair
            -- in
            pair


pageMatch : Page -> Page -> Bool
pageMatch m1 m2 =
    case ( m1, m2 ) of
        ( NotFound, NotFound ) ->
            True

        ( Home _, Home _ ) ->
            True

        ( Packages _, Packages _ ) ->
            True

        ( Options _, Options _ ) ->
            True

        ( Flakes (OptionModel _), Flakes (OptionModel _) ) ->
            True

        ( Flakes (PackagesModel _), Flakes (PackagesModel _) ) ->
            True

        _ ->
            False


changeRouteTo :
    Model
    -> Url.Url
    -> ( Model, Cmd Msg )
changeRouteTo currentModel url =
    case Route.fromUrl url of
        Nothing ->
            ( { currentModel | page = NotFound }
            , Cmd.none
            )

        Just route ->
            let
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
                    Page.Packages.init searchArgs modelPage
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
                    Page.Options.init searchArgs modelPage
                        |> updateWith Options OptionsMsg model
                        |> avoidReinit
                        |> attemptQuery

                Route.Flakes searchArgs ->
                    let
                        -- _ = Debug.log "changeRouteTo" "flakes"
                        modelPage =
                            case model.page of
                                Flakes x ->
                                    Just x

                                _ ->
                                    Nothing
                    in
                    Page.Flakes.init searchArgs modelPage
                        |> updateWith Flakes FlakesMsg model
                        |> avoidReinit
                        |> attemptQuery


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    -- let _ = Debug.log "main" "update"
    -- in
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

        ( HomeMsg subMsg, Home subModel ) ->
            Page.Home.update subMsg subModel
                |> updateWith Home HomeMsg model

        ( PackagesMsg subMsg, Packages subModel ) ->
            Page.Packages.update model.navKey subMsg subModel
                |> updateWith Packages PackagesMsg model

        ( OptionsMsg subMsg, Options subModel ) ->
            Page.Options.update model.navKey subMsg subModel
                |> updateWith Options OptionsMsg model

        ( FlakesMsg subMsg, Flakes subModel ) ->
            Page.Flakes.update model.navKey subMsg subModel
                |> updateWith Flakes FlakesMsg model

        ( _, _ ) ->
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
        title =
            case model.page of
                Packages _ ->
                    "NixOS Search - Packages"

                Options _ ->
                    "NixOS Search - Options"

                Flakes _ ->
                    "NixOS Search - Flakes (Experimental)"

                _ ->
                    "NixOS Search"
    in
    { title = title
    , body =
        [ div []
            [ header []
                [ div [ class "navbar navbar-static-top" ]
                    [ div [ class "navbar-inner" ]
                        [ div [ class "container" ]
                            [ a [ class "brand", href "https://nixos.org" ]
                                [ img [ src "https://nixos.org/logo/nix-wiki.png", class "logo" ] []
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
    }


viewNavigation : Route.Route -> List (Html Msg)
viewNavigation route =
    let
        toRoute f =
            case route of
                -- Preserve arguments
                Route.Packages searchArgs ->
                    f searchArgs

                Route.Options searchArgs ->
                    f searchArgs

                Route.Flakes searchArgs ->
                    f searchArgs

                _ ->
                    f <| Route.SearchArgs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    in
    li [] [ a [ href "https://nixos.org" ] [ text "Back to nixos.org" ] ]
        :: List.map
            (viewNavigationItem route)
            [ ( toRoute Route.Packages, text "Packages" )
            , ( toRoute Route.Options, text "Options" )
            , ( toRoute Route.Flakes, span [] [ text "Flakes", sup [] [span [class "label label-info"][small [] [text "Experimental"]]]] )
            
            ]


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

        Home _ ->
            div [] [ text "Welcome" ]

        Packages packagesModel ->
            Html.map (\m -> PackagesMsg m) <| Page.Packages.view packagesModel

        Options optionsModel ->
            Html.map (\m -> OptionsMsg m) <| Page.Options.view optionsModel

        Flakes flakesModel ->
            Html.map (\m -> FlakesMsg m) <| Page.Flakes.view flakesModel



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
