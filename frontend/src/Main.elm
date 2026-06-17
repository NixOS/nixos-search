port module Main exposing (Flags, Model, Msg, Page, main)

import Browser
import Browser.Dom
import Browser.Navigation
import Dict
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
        , small
        , span
        , sup
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( alt
        , attribute
        , class
        , classList
        , href
        , id
        , src
        , target
        , title
        )
import Html.Events exposing (onClick)
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
import Svg exposing (Svg, path, svg)
import Svg.Attributes exposing (d, fill, height, viewBox, width)
import Task
import Url



-- MODEL


type alias Flags =
    { elasticsearchMappingSchemaVersion : Int
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    , nixosChannels : Json.Decode.Value
    , theme : String
    }


type Theme
    = Auto
    | Light
    | Dark


themeFromString : String -> Theme
themeFromString s =
    case s of
        "light" ->
            Light

        "dark" ->
            Dark

        _ ->
            Auto


themeToString : Theme -> String
themeToString t =
    case t of
        Auto ->
            "auto"

        Light ->
            "light"

        Dark ->
            "dark"


themeLabel : Theme -> String
themeLabel t =
    case t of
        Auto ->
            "Auto"

        Light ->
            "Light"

        Dark ->
            "Dark"


type alias Model =
    { navKey : Browser.Navigation.Key
    , route : Route.Route
    , elasticsearch : Search.Options
    , defaultNixOSChannel : String
    , nixosChannels : List NixOSChannel
    , page : Page
    , theme : Theme
    }


port setTheme : String -> Cmd msg


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
            , theme = themeFromString flags.theme
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
    | SetTheme Theme


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
                Tuple.mapSecond
                    (\cmd ->
                        Cmd.batch
                            [ cmd
                            , Cmd.map OptionsMsg <|
                                Page.Options.makeRequest
                                    model.elasticsearch
                                    model.nixosChannels
                                    OptionSearch
                                    searchModel.channel
                                    searchModel.query
                                    searchModel.from
                                    searchModel.size
                                    searchModel.buckets
                                    searchModel.sort
                                    searchModel.activeOptionSource
                            ]
                    )
                    pair

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
            { model_a | show = Nothing, showInstallDetails = Search.Unset, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }
                == { model_b | show = Nothing, showInstallDetails = Search.Unset, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }

        ( Options model_a, Options model_b ) ->
            { model_a | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }
                == { model_b | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }

        ( Flakes (OptionModel model_a), Flakes (OptionModel model_b) ) ->
            { model_a | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }
                == { model_b | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }

        ( Flakes (PackagesModel model_a), Flakes (PackagesModel model_b) ) ->
            { model_a | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }
                == { model_b | show = Nothing, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }

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
            Page.Packages.init searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels True modelPage
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
            Page.Options.init searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels True modelPage
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

        ( SetTheme theme, _ ) ->
            ( { model | theme = theme }
            , setTheme (themeToString theme)
            )

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
                    "NixOS Search - 3rd-party Flakes" ++ maybeFlakeQuery m

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
                                    [ img [ alt "NixOS logo", src "/images/nix-logo-pride.png", class "logo" ] []
                                    ]
                                , ul [ class "nav" ]
                                    (viewNavigation model.route)
                                , viewThemeSelector model.theme
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
                        Route.SearchArgs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Route.defaultOptionSource
    in
    li [] [ a [ href "https://nixos.org" ] [ text "Back to nixos.org" ] ]
        :: List.map
            (viewNavigationItem route)
            [ ( Route.Packages searchArgs, text "Packages" )
            , ( Route.Options searchArgs, text "Options" )
            , ( Route.Flakes searchArgs, text "3rd-party Flakes" )
            ]
        ++ [ li [ class "external" ] [ a [ href "https://noogle.dev", target "_blank", Html.Attributes.rel "noopener noreferrer" ] [ text "Functions" ] ]
           , li [ class "external" ] [ a [ href "https://wiki.nixos.org", target "_blank", Html.Attributes.rel "noopener noreferrer" ] [ text "NixOS Wiki" ] ]
           ]


viewNavigationItem :
    Route.Route
    -> ( Route.Route, Html Msg )
    -> Html Msg
viewNavigationItem currentRoute ( route, title ) =
    li
        [ classList [ ( "active", currentRoute == route ) ] ]
        [ a [ Route.href route ] [ title ] ]



-- Material Design Icons by Google
-- Licensed under Apache License 2.0
-- https://github.com/google/material-design-icons


themeAutoIconPath : String
themeAutoIconPath =
    "M80 61.2398L93.24 47.9998L80 34.7598V15.9998H61.24L48 2.75977L34.76 15.9998H16V34.7598L2.76001 47.9998L16 61.2398V79.9998H34.76L48 93.2398L61.24 79.9998H80V61.2398ZM48 71.9998V23.9998C61.24 23.9998 72 34.7598 72 47.9998C72 61.2398 61.24 71.9998 48 71.9998Z"


themeDarkIconPath : String
themeDarkIconPath =
    "M48 12C28.12 12 12 28.12 12 48C12 67.88 28.12 84 48 84C67.88 84 84 67.88 84 48C84 46.16 83.84 44.32 83.6 42.56C79.68 48.04 73.28 51.6 66 51.6C54.08 51.6 44.4 41.92 44.4 30C44.4 22.76 47.96 16.32 53.44 12.4C51.68 12.16 49.84 12 48 12Z"


themeLightIconPath : String
themeLightIconPath =
    "M48 28C36.96 28 28 36.96 28 48C28 59.04 36.96 68 48 68C59.04 68 68 59.04 68 48C68 36.96 59.04 28 48 28ZM8 52H16C18.2 52 20 50.2 20 48C20 45.8 18.2 44 16 44H8C5.8 44 4 45.8 4 48C4 50.2 5.8 52 8 52ZM80 52H88C90.2 52 92 50.2 92 48C92 45.8 90.2 44 88 44H80C77.8 44 76 45.8 76 48C76 50.2 77.8 52 80 52ZM44 8V16C44 18.2 45.8 20 48 20C50.2 20 52 18.2 52 16V8C52 5.8 50.2 4 48 4C45.8 4 44 5.8 44 8ZM44 80V88C44 90.2 45.8 92 48 92C50.2 92 52 90.2 52 88V80C52 77.8 50.2 76 48 76C45.8 76 44 77.8 44 80ZM23.96 18.32C22.4 16.76 19.84 16.76 18.32 18.32C16.76 19.88 16.76 22.44 18.32 23.96L22.56 28.2C24.12 29.76 26.68 29.76 28.2 28.2C29.72 26.64 29.76 24.08 28.2 22.56L23.96 18.32ZM73.44 67.8C71.88 66.24 69.32 66.24 67.8 67.8C66.24 69.36 66.24 71.92 67.8 73.44L72.04 77.68C73.6 79.24 76.16 79.24 77.68 77.68C79.24 76.12 79.24 73.56 77.68 72.04L73.44 67.8ZM77.68 23.96C79.24 22.4 79.24 19.84 77.68 18.32C76.12 16.76 73.56 16.76 72.04 18.32L67.8 22.56C66.24 24.12 66.24 26.68 67.8 28.2C69.36 29.72 71.92 29.76 73.44 28.2L77.68 23.96ZM28.2 73.44C29.76 71.88 29.76 69.32 28.2 67.8C26.64 66.24 24.08 66.24 22.56 67.8L18.32 72.04C16.76 73.6 16.76 76.16 18.32 77.68C19.88 79.2 22.44 79.24 23.96 77.68L28.2 73.44Z"


getThemeSvgIconPath : Theme -> String
getThemeSvgIconPath theme =
    case theme of
        Light ->
            themeLightIconPath

        Dark ->
            themeDarkIconPath

        Auto ->
            themeAutoIconPath


getThemeSvgIcon : Theme -> Svg msg
getThemeSvgIcon theme =
    svg
        [ viewBox "0 0 96 96"
        , fill "currentColor"
        , width "16"
        , height "16"
        ]
        [ path [ d (getThemeSvgIconPath theme) ] [] ]


viewThemeSelector : Theme -> Html Msg
viewThemeSelector currentTheme =
    div
        [ class "btn-group pull-right theme-toggle"
        , attribute "role" "group"
        , attribute "aria-label" "Theme"
        ]
        (List.map
            (\t ->
                button
                    [ class "btn"
                    , classList [ ( "active", t == currentTheme ) ]
                    , title (themeLabel t)
                    , attribute "aria-label" (themeLabel t)
                    , attribute "aria-pressed"
                        (if t == currentTheme then
                            "true"

                         else
                            "false"
                        )
                    , onClick (SetTheme t)
                    ]
                    [ span [ class "theme-icon" ] [ getThemeSvgIcon t ] ]
            )
            [ Auto, Light, Dark ]
        )


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
