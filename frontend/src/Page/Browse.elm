module Page.Browse exposing
    ( App
    , BrowseResult
    , CategoryResult
    , Entry
    , Model
    , Msg
    , init
    , matches
    , update
    , view
    )

{-| A catalog of the applications in a channel, by freedesktop.org category.

The overview shows the most popular applications of each category, and a
category shows all of its applications. An application is a package that shows
a desktop entry. The index lists each application once: `flake-info` sets
`package_app_categories` on one attribute of each.

-}

import Browser.Navigation
import Dict exposing (Dict)
import Html
    exposing
        ( Html
        , a
        , aside
        , button
        , div
        , h2
        , h4
        , img
        , li
        , p
        , span
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( alt
        , attribute
        , class
        , src
        )
import Html.Events exposing (onClick)
import Http
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Material.Icons as Icons
import RemoteData exposing (RemoteData(..), WebData)
import Route exposing (BrowseArgs)
import Search exposing (NixOSChannel)
import Task



-- MODEL


type alias Model =
    { channel : String
    , category : Maybe String
    , size : Int
    , saveData : Bool
    , result : WebData BrowseResult
    }


type alias BrowseResult =
    { total : Int
    , apps : List App
    , categories : List CategoryResult
    }


type alias CategoryResult =
    { category : String
    , count : Int
    , top : List App
    }


{-| The part of a package document that a card shows.
-}
type alias App =
    { attrName : String
    , pname : String
    , description : Maybe String
    , entries : List Entry
    , icons : Dict String String
    }


type alias Entry =
    { name : Maybe String
    , comment : Maybe String
    , icon : Maybe String
    , noDisplay : Bool
    }


{-| The freedesktop.org main categories, with the label the page shows for each.
An entry must have at least one of them, thus each application is in one or
more of them.
-}
mainCategories : List ( String, String )
mainCategories =
    [ ( "AudioVideo", "Audio and video" )
    , ( "Development", "Development" )
    , ( "Education", "Education" )
    , ( "Game", "Games" )
    , ( "Graphics", "Graphics" )
    , ( "Network", "Internet" )
    , ( "Office", "Office" )
    , ( "Science", "Science" )
    , ( "Settings", "Settings" )
    , ( "System", "System" )
    , ( "Utility", "Utilities" )
    ]


categoryLabel : String -> String
categoryLabel category =
    mainCategories
        |> List.filter (\( id, _ ) -> id == category)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault category


{-| The applications the overview shows of each category.
-}
overviewSize : Int
overviewSize =
    8


{-| The applications a category shows at first, and the number more each click
on "Show more" adds.
-}
pageSize : Int
pageSize =
    48


init :
    Search.Options
    -> List NixOSChannel
    -> String
    -> Bool
    -> BrowseArgs
    -> ( Model, Cmd Msg )
init options nixosChannels defaultChannel saveData args =
    let
        model : Model
        model =
            { channel = Maybe.withDefault defaultChannel args.channel
            , category = args.category
            , size = pageSize
            , saveData = saveData
            , result = Loading
            }
    in
    ( model, makeRequest options nixosChannels model )


{-| True when two models show the same page, thus a change of the URL to the
second does not need a new request.
-}
matches : Model -> Model -> Bool
matches a b =
    a.channel == b.channel && a.category == b.category



-- UPDATE


type Msg
    = Loaded (WebData BrowseResult)
    | ChannelChange String
    | CategoryChange (Maybe String)
    | ShowMore


update :
    Browser.Navigation.Key
    -> Search.Options
    -> List NixOSChannel
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update navKey options nixosChannels msg model =
    case msg of
        Loaded result ->
            ( { model | result = result }, Cmd.none )

        ChannelChange channel ->
            ( model
            , Browser.Navigation.pushUrl navKey <|
                Route.routeToString (Route.Browse { channel = Just channel, category = model.category })
            )

        CategoryChange category ->
            ( model
            , Browser.Navigation.pushUrl navKey <|
                Route.routeToString (Route.Browse { channel = Just model.channel, category = category })
            )

        ShowMore ->
            let
                newModel : Model
                newModel =
                    { model | size = model.size + pageSize }
            in
            ( newModel, makeRequest options nixosChannels newModel )



-- REQUEST


{-| The applications of the channel, most popular first. The number of
distributions that package an application tells how popular it is, and an
application that ships AppStream data gets a small boost over one that does
not: such data is a sign of an application made for end users, rather than a
tool that a library ships with a desktop entry.

The category counts come from the full set, as the category filter is a
`post_filter`.

-}
makeRequest : Search.Options -> List NixOSChannel -> Model -> Cmd Msg
makeRequest options nixosChannels model =
    let
        field : String
        field =
            "package_app_categories"

        object : List ( String, Json.Encode.Value ) -> Json.Encode.Value
        object =
            Json.Encode.object

        string : String -> Json.Encode.Value
        string =
            Json.Encode.string

        sourceFields : Json.Encode.Value
        sourceFields =
            Json.Encode.list string
                [ "package_attr_name"
                , "package_pname"
                , "package_description"
                , "package_desktop_entries"
                , "package_desktop_icons"
                ]

        categoryTerms : List ( String, Json.Encode.Value )
        categoryTerms =
            [ ( "field", string field )
            , ( "size", Json.Encode.int (List.length mainCategories) )
            , ( "include", Json.Encode.list (Tuple.first >> string) mainCategories )
            ]

        categoriesAggregation : Json.Encode.Value
        categoriesAggregation =
            case model.category of
                Just _ ->
                    object [ ( "terms", object categoryTerms ) ]

                Nothing ->
                    object
                        [ ( "terms", object categoryTerms )
                        , ( "aggs"
                          , object
                                [ ( "top"
                                  , object
                                        [ ( "top_hits"
                                          , object
                                                [ ( "size", Json.Encode.int overviewSize )
                                                , ( "_source", sourceFields )
                                                ]
                                          )
                                        ]
                                  )
                                ]
                          )
                        ]

        query : Json.Encode.Value
        query =
            object
                [ ( "bool"
                  , object
                        [ ( "filter"
                          , Json.Encode.list identity
                                [ object [ ( "term", object [ ( "type", string "package" ) ] ) ]
                                , object [ ( "exists", object [ ( "field", string field ) ] ) ]
                                ]
                          )
                        , ( "should"
                          , Json.Encode.list identity
                                [ object
                                    [ ( "rank_feature"
                                      , object [ ( "field", string "package_repology_repos" ) ]
                                      )
                                    ]
                                , object
                                    [ ( "constant_score"
                                      , object
                                            [ ( "filter"
                                              , object [ ( "exists", object [ ( "field", string "package_component_ids" ) ] ) ]
                                              )
                                            , ( "boost", Json.Encode.float 0.1 )
                                            ]
                                      )
                                    ]
                                ]
                          )
                        ]
                  )
                ]

        body : Json.Encode.Value
        body =
            object
                ([ ( "query", query )
                 , ( "_source", sourceFields )
                 , ( "aggs", object [ ( "categories", categoriesAggregation ) ] )
                 ]
                    ++ (case model.category of
                            Just category ->
                                [ ( "size", Json.Encode.int model.size )
                                , ( "post_filter", object [ ( "term", object [ ( field, string category ) ] ) ] )
                                ]

                            Nothing ->
                                [ ( "size", Json.Encode.int 0 ) ]
                       )
                )
    in
    Search.makeRequestTask
        (Http.jsonBody body)
        nixosChannels
        model.channel
        decodeApp
        decodeCategories
        options
        |> Task.map
            (\result ->
                { total = result.hits.total.value
                , apps = List.map .source result.hits.hits
                , categories = result.aggregations
                }
            )
        |> Task.attempt (RemoteData.fromResult >> Loaded)


decodeCategories : Json.Decode.Decoder (List CategoryResult)
decodeCategories =
    Json.Decode.at [ "categories", "buckets" ]
        (Json.Decode.list
            (Json.Decode.map3 CategoryResult
                (Json.Decode.field "key" Json.Decode.string)
                (Json.Decode.field "doc_count" Json.Decode.int)
                (Json.Decode.oneOf
                    [ Json.Decode.at [ "top", "hits", "hits" ]
                        (Json.Decode.list (Json.Decode.field "_source" decodeApp))
                    , Json.Decode.succeed []
                    ]
                )
            )
        )


decodeApp : Json.Decode.Decoder App
decodeApp =
    Json.Decode.succeed App
        |> Json.Decode.Pipeline.required "package_attr_name" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_pname" Json.Decode.string
        |> Json.Decode.Pipeline.optional "package_description" (Json.Decode.nullable Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "package_desktop_entries" (Json.Decode.list decodeEntry) []
        |> Json.Decode.Pipeline.optional "package_desktop_icons" (Json.Decode.dict Json.Decode.string) Dict.empty


decodeEntry : Json.Decode.Decoder Entry
decodeEntry =
    Json.Decode.succeed Entry
        |> Json.Decode.Pipeline.optional "desktopName" (Json.Decode.nullable Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "comment" (Json.Decode.nullable Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "icon" (Json.Decode.nullable Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "noDisplay" Json.Decode.bool False



-- VIEW


view : List NixOSChannel -> Model -> Html Msg
view nixosChannels model =
    div [ class "search-page browse-page" ]
        (Search.viewChannels ChannelChange nixosChannels model.channel
            ++ (case model.result of
                    NotAsked ->
                        []

                    Loading ->
                        [ div [ class "loader" ] [ text "Loading..." ] ]

                    Failure error ->
                        [ div [ class "alert alert-error" ]
                            [ h4 [] [ text "The applications could not be loaded." ]
                            , text (errorToString error)
                            ]
                        ]

                    Success result ->
                        if List.isEmpty result.categories then
                            [ div [ class "search-no-results" ]
                                [ h2 [] [ text "No applications found!" ]
                                , p [] [ text "The index of this channel does not contain application data yet." ]
                                ]
                            ]

                        else
                            [ div [ class "search-results" ]
                                [ aside [ class "search-sidebar" ] (viewCategoryBucket model result)
                                , div [ class "search-results-main" ] (viewResult model result)
                                ]
                            ]
               )
        )


errorToString : Http.Error -> String
errorToString error =
    case error of
        Http.BadUrl url ->
            "The URL is not valid: " ++ url

        Http.Timeout ->
            "The request to the server timed out."

        Http.NetworkError ->
            "A network request to the search backend failed. This is either due to a content blocker or a networking issue."

        Http.BadStatus code ->
            "The server returned status " ++ String.fromInt code ++ "."

        Http.BadBody message ->
            message


{-| The category filter in the sidebar. It works as the radio filters on the
search pages: a click on the selected category clears it and shows the overview.
The bucket keys are the labels, as `Search.viewBucket` shows the keys.
-}
viewCategoryBucket : Model -> BrowseResult -> List (Html Msg)
viewCategoryBucket model result =
    let
        categories : List CategoryResult
        categories =
            sortCategories result.categories

        toMsg : String -> Msg
        toMsg label =
            categories
                |> List.filter (\c -> categoryLabel c.category == label)
                |> List.head
                |> Maybe.map .category
                |> Maybe.andThen
                    (\category ->
                        if Just category == model.category then
                            Nothing

                        else
                            Just category
                    )
                |> CategoryChange
    in
    Search.viewBucket
        Search.RadioInput
        "Categories"
        Icons.category
        (List.map (\c -> { key = categoryLabel c.category, doc_count = c.count }) categories)
        toMsg
        (model.category |> Maybe.map categoryLabel |> Maybe.map List.singleton |> Maybe.withDefault [])
        []


{-| The categories in the order of `mainCategories`, which is alphabetical by
label, not by count.
-}
sortCategories : List CategoryResult -> List CategoryResult
sortCategories categories =
    List.filterMap
        (\( id, _ ) -> List.head (List.filter (\c -> c.category == id) categories))
        mainCategories


viewResult : Model -> BrowseResult -> List (Html Msg)
viewResult model result =
    case model.category of
        Nothing ->
            List.map
                (\c ->
                    div [ class "browse-category" ]
                        [ h2 []
                            [ a [ Route.href (Route.Browse { channel = Just model.channel, category = Just c.category }) ]
                                [ text (categoryLabel c.category) ]
                            ]
                        , viewApps model c.top
                        , a
                            [ class "browse-category-more"
                            , Route.href (Route.Browse { channel = Just model.channel, category = Just c.category })
                            ]
                            [ text ("All " ++ String.fromInt c.count ++ " applications") ]
                        ]
                )
                (sortCategories result.categories)

        Just category ->
            [ div [ class "browse-category" ]
                (h2 [] [ text (categoryLabel category) ]
                    :: viewApps model result.apps
                    :: (if List.length result.apps < result.total then
                            [ div [ class "browse-show-more" ]
                                [ button [ class "btn", onClick ShowMore ] [ text "Show more" ] ]
                            ]

                        else if List.isEmpty result.apps then
                            [ p [] [ text "No applications in this category." ] ]

                        else
                            []
                       )
                )
            ]


viewApps : Model -> List App -> Html Msg
viewApps model apps =
    ul [ class "browse-apps" ] (List.map (viewApp model) apps)


viewApp : Model -> App -> Html Msg
viewApp model app =
    let
        entries : List Entry
        entries =
            List.filter (not << .noDisplay) app.entries

        appName : String
        appName =
            entries
                |> List.filterMap .name
                |> List.head
                |> Maybe.withDefault app.pname

        description : Maybe String
        description =
            case app.description of
                Just d ->
                    Just d

                Nothing ->
                    List.head (List.filterMap .comment entries)

        iconFile : Maybe String
        iconFile =
            if model.saveData then
                Nothing

            else
                entries
                    |> List.filterMap (\entry -> Maybe.andThen (\icon -> Dict.get icon app.icons) entry.icon)
                    |> List.head

        target : Route.Route
        target =
            Route.Packages
                { query = Just app.attrName
                , channel = Just model.channel
                , show = Just app.attrName
                , from = Nothing
                , size = Nothing
                , buckets = Nothing
                , sort = Nothing
                , type_ = Nothing
                , activeOptionSource = Route.defaultOptionSource
                }
    in
    li [ class "browse-app" ]
        [ a [ Route.href target ]
            [ case iconFile of
                Just file ->
                    -- Decorative: the name is beside it.
                    img [ class "browse-app-icon", src ("/icons/" ++ file), alt "", attribute "loading" "lazy" ] []

                Nothing ->
                    span [ class "browse-app-icon" ] []
            , span [ class "browse-app-name" ] [ text appName ]
            , span [ class "browse-app-attr" ] [ text app.attrName ]
            ]
        , case description of
            Just d ->
                p [ class "browse-app-description" ] [ text d ]

            Nothing ->
                text ""
        ]
