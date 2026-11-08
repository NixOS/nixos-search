port module Main exposing (Flags, Model, Msg, Page, Theme, main)

import Browser
import Browser.Dom
import Browser.Navigation
import Components.Button exposing (viewButton)
import Dict exposing (Dict)
import Html
    exposing
        ( Html
        , a
        , div
        , footer
        , header
        , img
        , li
        , main_
        , span
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
import Http
import Json.Decode
import Material.Icons as Icons
import Material.Icons.Types exposing (Coloring(..))
import Page.Browse
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
import Svg exposing (Svg)
import Svg.Attributes exposing (width)
import Task
import Url
import Utils exposing (basicTextIcon)



-- MODEL


type alias Flags =
    { elasticsearchMappingSchemaVersion : Int
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    , nixosChannels : Json.Decode.Value
    , theme : String
    , systemDark : Bool
    , isPrideMonth : Bool
    , saveData : Bool
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


{-| The palette that shows: the OS palette in `Auto`, else the pinned palette.
-}
resolveTheme : Bool -> Theme -> Theme
resolveTheme systemDark t =
    case t of
        Auto ->
            systemTheme systemDark

        _ ->
            t


systemTheme : Bool -> Theme
systemTheme systemDark =
    if systemDark then
        Dark

    else
        Light


{-| The theme a click on the toggle gives. When the other palette is the OS
palette, the toggle clears the pin and goes back to `Auto`; otherwise it pins
the other palette. Thus from `Auto` a click pins the palette the OS does not
use, and a second click goes back to `Auto`.
-}
toggleTheme : Bool -> Theme -> Theme
toggleTheme systemDark t =
    let
        other : Theme
        other =
            if resolveTheme systemDark t == Dark then
                Light

            else
                Dark
    in
    if other == systemTheme systemDark then
        Auto

    else
        other


type alias Model =
    { navKey : Browser.Navigation.Key
    , route : Route.Route
    , elasticsearch : Search.Options
    , defaultNixOSChannel : String
    , nixosChannels : List NixOSChannel
    , page : Page
    , theme : Theme
    , systemDark : Bool
    , isPrideMonth : Bool
    , preferStatic : Bool

    -- The number of documents of each type, for each channel. One request
    -- gets the counts of all channels, the first time that a page needs them.
    , docCounts : RemoteData.WebData (Dict String (Dict String Int))
    }


port setTheme : String -> Cmd msg


port systemDarkChanged : (Bool -> msg) -> Sub msg


type Page
    = NotFound
    | Browse Page.Browse.Model
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
            , systemDark = flags.systemDark
            , isPrideMonth = flags.isPrideMonth
            , preferStatic = not flags.saveData
            , docCounts = NotAsked
            }
    in
    changeRouteTo model url



-- UPDATE


type Msg
    = ChangedUrl Url.Url
    | ClickedLink Browser.UrlRequest
    | BrowseMsg Page.Browse.Msg
    | PackagesMsg Page.Packages.Msg
    | OptionsMsg Page.Options.Msg
    | FlakesMsg Page.Flakes.Msg
    | CtrlKRegistered
    | SearchFocusResult
    | ToggleTheme
    | SystemDarkChanged Bool
    | DocCountsResponse (Result Http.Error (Dict String (Dict String Int)))


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
                                makeOptionsRequest model.elasticsearch model.nixosChannels searchModel
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


{-| Request the document counts of all channels, if the page shows them and no
request started before.
-}
attemptDocCounts : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
attemptDocCounts (( model, cmd ) as pair) =
    let
        pageShowsCounts =
            case model.page of
                Packages _ ->
                    True

                Options _ ->
                    True

                _ ->
                    False
    in
    if pageShowsCounts && model.docCounts == NotAsked then
        ( { model | docCounts = Loading }
        , Cmd.batch
            [ cmd
            , Search.makeDocCountsRequest model.elasticsearch model.nixosChannels DocCountsResponse
            ]
        )

    else
        pair


makeOptionsRequest : Search.Options -> List NixOSChannel -> Page.Options.Model -> Cmd Page.Options.Msg
makeOptionsRequest elasticsearch nixosChannels searchModel =
    Page.Options.makeRequest
        elasticsearch
        nixosChannels
        OptionSearch
        searchModel.channel
        searchModel.query
        searchModel.from
        searchModel.size
        searchModel.buckets
        searchModel.sort
        searchModel.activeOptionSource


pageMatch : Page -> Page -> Bool
pageMatch m1 m2 =
    case ( m1, m2 ) of
        ( NotFound, NotFound ) ->
            True

        ( Browse model_a, Browse model_b ) ->
            Page.Browse.matches model_a model_b

        ( Packages model_a, Packages model_b ) ->
            { model_a | show = Nothing, showUsageDetails = Search.Unset, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }
                == { model_b | show = Nothing, showUsageDetails = Search.Unset, result = NotAsked, sourceCounts = Dict.empty, previousResult = Nothing }

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

        Route.Browse browseArgs ->
            Page.Browse.init currentModel.elasticsearch currentModel.nixosChannels currentModel.defaultNixOSChannel (not currentModel.preferStatic) browseArgs
                |> updateWith Browse BrowseMsg model
                |> avoidReinit

        Route.Packages searchArgs ->
            let
                modelPage =
                    case model.page of
                        Packages x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Packages.init currentModel.elasticsearch currentModel.preferStatic searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels True modelPage
                |> updateWith Packages PackagesMsg model
                |> avoidReinit
                |> attemptQuery
                |> attemptDocCounts

        Route.Options searchArgs ->
            let
                modelPage =
                    case model.page of
                        Options x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Options.init currentModel.elasticsearch currentModel.preferStatic searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels True modelPage
                |> updateWith Options OptionsMsg model
                |> avoidReinit
                |> attemptQuery
                |> attemptDocCounts

        Route.Flakes searchArgs ->
            let
                modelPage =
                    case model.page of
                        Flakes x ->
                            Just x

                        _ ->
                            Nothing
            in
            Page.Flakes.init currentModel.elasticsearch currentModel.preferStatic searchArgs currentModel.defaultNixOSChannel currentModel.nixosChannels modelPage
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

        ( BrowseMsg subMsg, Browse subModel ) ->
            Page.Browse.update model.navKey model.elasticsearch model.nixosChannels subMsg subModel
                |> updateWith Browse BrowseMsg model

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

        ( ToggleTheme, _ ) ->
            let
                theme : Theme
                theme =
                    toggleTheme model.systemDark model.theme
            in
            ( { model | theme = theme }
            , setTheme (themeToString theme)
            )

        ( SystemDarkChanged systemDark, _ ) ->
            -- A pin that now equals the OS palette stays, so the next click
            -- pins the other palette.
            ( { model | systemDark = systemDark }, Cmd.none )

        ( DocCountsResponse result, _ ) ->
            ( { model | docCounts = RemoteData.fromResult result }
            , Cmd.none
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
                Browse _ ->
                    "NixOS Search - Browse"

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
                                [ viewBrand model.isPrideMonth
                                , ul [ class "nav" ] (viewNavigation model.route)
                                , viewThemeToggle (resolveTheme model.systemDark model.theme)
                                ]
                            ]
                        ]
                    ]
                , div [ class "container main" ]
                    [ main_ [ id "content" ] [ viewPage model ]
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


viewBrand : Bool -> Html msg
viewBrand isPrideMonth =
    let
        variant : String
        variant =
            if isPrideMonth then
                "rainbow"

            else
                "default"

        logo : String
        logo =
            "/images/nixos-logomark-" ++ variant ++ "-gradient-none.svg"
    in
    a [ class "brand", href "https://nixos.org" ]
        [ img
            [ width "28px"
            , alt "NixOS logo"
            , src logo
            , class "logo"
            ]
            []
        ]


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

                    Route.Browse args ->
                        Route.SearchArgs Nothing args.channel Nothing Nothing Nothing Nothing Nothing Nothing Route.defaultOptionSource

                    _ ->
                        Route.SearchArgs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Route.defaultOptionSource

        -- All categories of Browse are in the same navigation item
        activeRoute =
            case route of
                Route.Browse args ->
                    Route.Browse { args | category = Nothing }

                _ ->
                    route
    in
    li [] []
        :: List.map
            (viewNavigationItem activeRoute)
            [ ( Route.Browse { channel = searchArgs.channel, category = Nothing }, basicTextIcon Icons.explore "Browse" )
            , ( Route.Packages searchArgs, basicTextIcon Icons.widgets "Packages" )
            , ( Route.Options searchArgs, basicTextIcon Icons.tune "Options" )
            , ( Route.Flakes searchArgs, basicTextIcon Icons.ac_unit "3rd-party Flakes" )
            ]
        ++ [ li [ class "external" ]
                [ a [ href "https://noogle.dev", target "_blank", Html.Attributes.rel "noopener noreferrer" ]
                    [ basicTextIcon Icons.functions "Functions" ]
                ]
           , li [ class "external" ]
                [ a [ href "https://wiki.nixos.org", target "_blank", Html.Attributes.rel "noopener noreferrer" ]
                    [ basicTextIcon Icons.local_library "NixOS wiki" ]
                ]
           ]


viewNavigationItem :
    Route.Route
    -> ( Route.Route, Html Msg )
    -> Html Msg
viewNavigationItem currentRoute ( route, title ) =
    li
        [ classList [ ( "active", currentRoute == route ) ] ]
        [ a [ Route.href route ] [ title ] ]


getThemeIcon : Theme -> ( Svg msg, String )
getThemeIcon theme =
    case theme of
        Dark ->
            ( Icons.dark_mode 16 Inherit, "Switch to the light theme" )

        _ ->
            ( Icons.light_mode 16 Inherit, "Switch to the dark theme" )


{-| The toggle shows the palette a click gives: a moon on the light theme and
a sun on the dark theme. The label names the same action.
-}
viewThemeToggle : Theme -> Html Msg
viewThemeToggle resolvedTheme =
    let
        ( icon, label ) =
            getThemeIcon resolvedTheme
    in
    -- The wrapper sets the position in the navbar. The dark theme sets
    -- `margin: 0` on all `.btn` elements.
    div [ class "theme-toggle" ]
        [ viewButton
            [ title label
            , attribute "aria-label" label
            , onClick ToggleTheme
            ]
            [ span [ class "theme-icon" ] [ icon ] ]
        ]


viewPage : Model -> Html Msg
viewPage model =
    let
        docCountsOf channel =
            RemoteData.toMaybe model.docCounts
                |> Maybe.andThen (Dict.get channel)
                |> Maybe.withDefault Dict.empty
    in
    case model.page of
        NotFound ->
            div [] [ text "Not Found" ]

        Browse browseModel ->
            Html.map BrowseMsg <| Page.Browse.view model.nixosChannels browseModel

        Packages packagesModel ->
            Html.map (\m -> PackagesMsg m) <| Page.Packages.view model.nixosChannels (docCountsOf packagesModel.channel) packagesModel

        Options optionsModel ->
            Html.map (\m -> OptionsMsg m) <| Page.Options.view model.nixosChannels (docCountsOf optionsModel.channel) optionsModel

        Flakes flakesModel ->
            Html.map (\m -> FlakesMsg m) <| Page.Flakes.view model.nixosChannels flakesModel



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    systemDarkChanged SystemDarkChanged



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
