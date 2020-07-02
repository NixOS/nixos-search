module Main exposing (main)

--exposing (UrlRequest(..))

import Browser
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
        , span
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , classList
        , href
        , id
        , src
        )
import Page.Home
import Page.Options
import Page.Packages
import Route
import Search
import Url
import Url.Builder



-- MODEL


type alias Flags =
    { elasticsearchMappingSchemaVersion : Int
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    }


type alias Model =
    { navKey : Browser.Navigation.Key
    , url : Url.Url
    , elasticsearch : Search.Options
    , page : Page
    }


type Page
    = NotFound
    | Home Page.Home.Model
    | Packages Page.Packages.Model
    | Options Page.Options.Model


init :
    Flags
    -> Url.Url
    -> Browser.Navigation.Key
    -> ( Model, Cmd Msg )
init flags url navKey =
    let
        model =
            { navKey = navKey
            , url = url
            , elasticsearch =
                Search.Options
                    flags.elasticsearchMappingSchemaVersion
                    flags.elasticsearchUrl
                    flags.elasticsearchUsername
                    flags.elasticsearchPassword
            , page = NotFound
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


submitQuery :
    Model
    -> ( Model, Cmd Msg )
    -> ( Model, Cmd Msg )
submitQuery old ( new, cmd ) =
    let
        triggerSearch _ newModel msg makeRequest =
            if newModel.query /= Nothing && newModel.query /= Just "" then
                ( new
                , Cmd.batch
                    [ cmd
                    , makeRequest
                        new.elasticsearch
                        newModel.channel
                        (Maybe.withDefault "" newModel.query)
                        newModel.from
                        newModel.size
                        |> Cmd.map msg
                    ]
                )

            else
                ( new, cmd )
    in
    case ( old.page, new.page ) of
        ( Packages oldModel, Packages newModel ) ->
            triggerSearch oldModel newModel PackagesMsg Page.Packages.makeRequest

        ( NotFound, Packages newModel ) ->
            triggerSearch newModel newModel PackagesMsg Page.Packages.makeRequest

        ( Options oldModel, Options newModel ) ->
            triggerSearch oldModel newModel OptionsMsg Page.Options.makeRequest

        ( NotFound, Options newModel ) ->
            triggerSearch newModel newModel OptionsMsg Page.Options.makeRequest

        ( _, _ ) ->
            ( new, cmd )


changeRouteTo :
    Model
    -> Url.Url
    -> ( Model, Cmd Msg )
changeRouteTo model url =
    let
        newModel =
            { model | url = url }

        maybeRoute =
            Route.fromUrl url
    in
    case maybeRoute of
        Nothing ->
            ( { newModel
                | page = NotFound
              }
            , Cmd.none
            )

        Just Route.NotFound ->
            ( { newModel
                | page = NotFound
              }
            , Cmd.none
            )

        Just Route.Home ->
            -- Always redirect to /packages until we have something to show
            -- on the home page
            ( newModel, Browser.Navigation.pushUrl newModel.navKey "/packages" )

        Just (Route.Packages channel query show from size) ->
            let
                modelPage =
                    case newModel.page of
                        Packages x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Packages.init channel query show from size modelPage
                |> updateWith Packages PackagesMsg newModel
                |> submitQuery newModel

        Just (Route.Options channel query show from size) ->
            let
                modelPage =
                    case newModel.page of
                        Options x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Options.init channel query show from size modelPage
                |> updateWith Options OptionsMsg newModel
                |> submitQuery newModel


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.page ) of
        ( ClickedLink urlRequest, _ ) ->
            case urlRequest of
                Browser.Internal url ->
                    ( model
                    , if url.fragment == Just "disabled" then
                        Cmd.none

                      else
                        Browser.Navigation.pushUrl model.navKey <| Url.toString url
                    )

                Browser.External href ->
                    ( model
                    , Browser.Navigation.load href
                    )

        ( ChangedUrl url, _ ) ->
            changeRouteTo model url

        ( HomeMsg subMsg, Home subModel ) ->
            Page.Home.update subMsg subModel
                |> updateWith Home HomeMsg model

        ( PackagesMsg subMsg, Packages subModel ) ->
            Page.Packages.update model.navKey model.elasticsearch subMsg subModel
                |> updateWith Packages PackagesMsg model

        ( OptionsMsg subMsg, Options subModel ) ->
            Page.Options.update model.navKey model.elasticsearch subMsg subModel
                |> updateWith Options OptionsMsg model

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
                            , div [ class "nav-collapse collapse" ]
                                [ ul [ class "nav pull-left" ]
                                    (viewNavigation model.page model.url)
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
                        [ span [] [ text "Elasticsearch instance graciously provided by " ]
                        , a [ href "https://bonsai.io" ] [ text "Bonsai" ]
                        , span [] [ text "." ]
                        ]
                    , div []
                        [ span [] [ text "❤️  Thank you ❤️ " ]
                        ]
                    ]
                ]
            ]
        ]
    }


viewNavigation : Page -> Url.Url -> List (Html Msg)
viewNavigation page url =
    let
        preserveSearchOptions =
            case page of
                Packages model ->
                    model.query
                        |> Maybe.map (\q -> [ Url.Builder.string "query" q ])
                        |> Maybe.withDefault []
                        |> List.append [ Url.Builder.string "channel" model.channel ]

                Options model ->
                    model.query
                        |> Maybe.map (\q -> [ Url.Builder.string "query" q ])
                        |> Maybe.withDefault []
                        |> List.append [ Url.Builder.string "channel" model.channel ]

                _ ->
                    []

        createUrl path =
            []
                |> List.append preserveSearchOptions
                |> Url.Builder.absolute [ path ]
    in
    List.map
        (viewNavigationItem url)
        [ ( "https://nixos.org", "Back to nixos.org" )
        , ( createUrl "packages", "Packages" )
        , ( createUrl "options", "Options" )
        ]


viewNavigationItem :
    Url.Url
    -> ( String, String )
    -> Html Msg
viewNavigationItem url ( path, title ) =
    li
        [ classList [ ( "active", path == url.path ) ] ]
        [ a [ href path ] [ text title ] ]


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
