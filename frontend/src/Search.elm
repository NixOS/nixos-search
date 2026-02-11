module Search exposing
    ( Aggregation
    , AggregationsBucketItem
    , Details(..)
    , Model
    , Msg(..)
    , NixOSChannel
    , NixOSChannelStatus
    , NixOSChannels
    , Options
    , ResultHits
    , ResultHitsTotal
    , ResultItem
    , SearchResult
    , Sort
    , decodeAggregation
    , decodeNixOSChannels
    , decodeResolvedFlake
    , defaultFlakeId
    , elementId
    , init
    , makeRequest
    , makeRequestBody
    , onClickStop
    , shouldLoad
    , showMoreButton
    , trapClick
    , update
    , view
    , viewBucket
    , viewFlakes
    , viewResult
    , viewSearchInput
    )

import Array
import Base64
import Browser.Dom
import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , button
        , code
        , div
        , form
        , h1
        , h2
        , h4
        , input
        , li
        , p
        , span
        , strong
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( attribute
        , autofocus
        , class
        , classList
        , disabled
        , href
        , id
        , placeholder
        , type_
        , value
        )
import Html.Events
    exposing
        ( onClick
        , onInput
        , onSubmit
        )
import Http
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import List.Extra
import RemoteData
import Route
    exposing
        ( SearchType
        , allTypes
        , searchTypeToTitle
        )
import Task


type alias Model a b =
    { channel : String
    , flake : String
    , query : String
    , result : RemoteData.WebData (SearchResult a b)
    , show : Maybe String
    , from : Int
    , size : Int
    , buckets : Maybe String
    , sort : Sort
    , showSort : Bool
    , showInstallDetails : Details
    , searchType : Route.SearchType
    }


type alias SearchResult a b =
    { hits : ResultHits a
    , aggregations : b
    }


type alias ResultHits a =
    { total : ResultHitsTotal
    , max_score : Maybe Float
    , hits : List (ResultItem a)
    }


type alias ResultHitsTotal =
    { value : Int
    , relation : String
    }


type alias ResultItem a =
    { index : String
    , id : String
    , score : Maybe Float
    , source : a
    , text : Maybe String
    , matched_queries : Maybe (List String)
    }


type alias Aggregation =
    { doc_count_error_upper_bound : Int
    , sum_other_doc_count : Int
    , buckets : List AggregationsBucketItem
    }


type alias AggregationsBucketItem =
    { doc_count : Int
    , key : String
    }


type Sort
    = Relevance
    | AlphabeticallyAsc
    | AlphabeticallyDesc


type alias NixOSChannels =
    { default : String
    , channels : List NixOSChannel
    }


type alias NixOSChannel =
    { id : String
    , status : NixOSChannelStatus
    , jobset : String
    , branch : String
    }


type NixOSChannelStatus
    = Rolling
    | Beta
    | Stable
    | Deprecated


channelBadge : NixOSChannelStatus -> List (Html msg)
channelBadge status =
    case status of
        Rolling ->
            -- [ span [ class "label label-success" ] [ text "Rolling" ] ]
            []

        Beta ->
            [ span [ class "label label-info" ] [ text "Beta" ] ]

        Stable ->
            -- [ span [ class "label label-success" ] [ text "Stable" ] ]
            []

        Deprecated ->
            [ span [ class "label label-warning" ] [ text "Deprecated" ] ]


decodeNixOSChannels : Json.Decode.Decoder NixOSChannels
decodeNixOSChannels =
    Json.Decode.map2 NixOSChannels
        (Json.Decode.field "default" Json.Decode.string)
        (Json.Decode.field "channels" (Json.Decode.list decodeNixOSChannel))


decodeNixOSChannel : Json.Decode.Decoder NixOSChannel
decodeNixOSChannel =
    Json.Decode.map4 NixOSChannel
        (Json.Decode.field "id" Json.Decode.string)
        (Json.Decode.field "status"
            (Json.Decode.string
                |> Json.Decode.andThen
                    (\status ->
                        case status of
                            "rolling" ->
                                Json.Decode.succeed Rolling

                            "beta" ->
                                Json.Decode.succeed Beta

                            "stable" ->
                                Json.Decode.succeed Stable

                            "deprecated" ->
                                Json.Decode.succeed Deprecated

                            _ ->
                                Json.Decode.fail ("Unknown status: " ++ status)
                    )
            )
        )
        (Json.Decode.field "jobset" Json.Decode.string)
        (Json.Decode.field "branch" Json.Decode.string)


type alias ResolvedFlake =
    { type_ : String
    , owner : Maybe String
    , repo : Maybe String
    , url : Maybe String
    }


decodeResolvedFlake : Json.Decode.Decoder String
decodeResolvedFlake =
    let
        resolved =
            Json.Decode.succeed ResolvedFlake
                |> Json.Decode.Pipeline.required "type" Json.Decode.string
                |> Json.Decode.Pipeline.optional "owner" (Json.Decode.map Just Json.Decode.string) Nothing
                |> Json.Decode.Pipeline.optional "repo" (Json.Decode.map Just Json.Decode.string) Nothing
                |> Json.Decode.Pipeline.optional "url" (Json.Decode.map Just Json.Decode.string) Nothing
    in
    Json.Decode.map
        (\resolved_ ->
            let
                repoPath =
                    case ( resolved_.owner, resolved_.repo ) of
                        ( Just owner, Just repo ) ->
                            Just <| owner ++ "/" ++ repo

                        _ ->
                            Nothing

                result =
                    case resolved_.type_ of
                        "github" ->
                            Maybe.map (\repoPath_ -> "https://github.com/" ++ repoPath_) repoPath

                        "gitlab" ->
                            Maybe.map (\repoPath_ -> "https://gitlab.com/" ++ repoPath_) repoPath

                        "sourcehut" ->
                            Maybe.map (\repoPath_ -> "https://sr.ht/" ++ repoPath_) repoPath

                        "git" ->
                            resolved_.url

                        _ ->
                            Nothing
            in
            Maybe.withDefault "INVALID FLAKE ORIGIN" result
        )
        resolved


init :
    Route.SearchArgs
    -> String
    -> List NixOSChannel
    -> Maybe (Model a b)
    -> ( Model a b, Cmd (Msg a b) )
init args defaultNixOSChannel nixosChannels maybeModel =
    let
        getField getFn default =
            maybeModel
                |> Maybe.map getFn
                |> Maybe.withDefault default

        modelChannel =
            getField .channel defaultNixOSChannel
    in
    ( { channel =
            args.channel
                |> Maybe.withDefault modelChannel
      , flake = defaultFlakeId
      , query =
            case args.query of
                Just q ->
                    q

                Nothing ->
                    args.show
                        |> Maybe.withDefault defaultSearchArgs.query
      , result = getField .result RemoteData.NotAsked
      , show = args.show
      , from =
            args.from
                |> Maybe.withDefault defaultSearchArgs.from
      , size =
            args.size
                |> Maybe.withDefault defaultSearchArgs.size
      , buckets = args.buckets
      , sort =
            args.sort
                |> Maybe.andThen fromSortId
                |> Maybe.withDefault defaultSearchArgs.sort
      , showSort = False
      , showInstallDetails = Unset
      , searchType =
            args.type_
                |> Maybe.withDefault defaultSearchArgs.searchType
      }
        |> ensureLoading nixosChannels
    , Browser.Dom.focus "search-query-input" |> Task.attempt (\_ -> NoOp)
    )


defaultSearchArgs :
    { query : String
    , from : Int
    , size : Int
    , sort : Sort
    , searchType : SearchType
    }
defaultSearchArgs =
    { query = ""
    , from = 0
    , size = 50
    , sort = Relevance
    , searchType = Route.PackageSearch
    }


shouldLoad :
    Model a b
    -> Bool
shouldLoad model =
    model.result == RemoteData.Loading


ensureLoading :
    List NixOSChannel
    -> Model a b
    -> Model a b
ensureLoading nixosChannels model =
    if
        not (String.isEmpty model.query)
            && List.any (\channel -> channel.id == model.channel) nixosChannels
    then
        { model | result = RemoteData.Loading }

    else
        model


elementId : String -> Html.Attribute msg
elementId str =
    Html.Attributes.id <| "result-" ++ str



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg a b
    = NoOp
    | SortChange Sort
    | ToggleSort
    | BucketsChange String
    | ChannelChange String
    | SubjectChange SearchType
    | QueryInput String
    | QueryInputSubmit
    | QueryResponse (RemoteData.WebData (SearchResult a b))
    | ShowDetails String
    | ChangePage Int
    | ShowInstallDetails Details


type Details
    = ViaNixShell
    | ViaNixOS
    | ViaNixProfile
    | ViaNixEnv
    | FromFlake
    | Unset


scrollToEntry :
    Maybe String
    -> Cmd (Msg a b)
scrollToEntry val =
    let
        doScroll id =
            Browser.Dom.getElement ("result-" ++ id)
                |> Task.andThen (\{ element } -> Browser.Dom.setViewport element.x element.y)
                |> Task.attempt (always NoOp)
    in
    Maybe.withDefault Cmd.none <| Maybe.map doScroll val


update :
    Route.SearchRoute
    -> Browser.Navigation.Key
    -> Msg a b
    -> Model a b
    -> List NixOSChannel
    -> ( Model a b, Cmd (Msg a b) )
update toRoute navKey msg model nixosChannels =
    case msg of
        NoOp ->
            ( model
            , Cmd.none
            )

        SortChange sort ->
            { model
                | sort = sort
                , show = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        ToggleSort ->
            ( { model
                | showSort = not model.showSort
              }
            , Cmd.none
            )

        BucketsChange buckets ->
            { model
                | buckets =
                    if String.isEmpty buckets then
                        Nothing

                    else
                        Just buckets
                , show = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        ChannelChange channel ->
            { model
                | channel = channel
                , show = Nothing
                , buckets = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        SubjectChange subject ->
            { model
                | searchType = subject
                , show = Nothing
                , buckets = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        QueryInput query ->
            ( { model | query = query }
            , Cmd.none
            )

        QueryInputSubmit ->
            { model
                | from = 0
                , show = Nothing
                , buckets = Nothing
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        QueryResponse result ->
            ( { model
                | result = result
              }
            , scrollToEntry model.show
            )

        ShowDetails selected ->
            { model
                | show =
                    if model.show == Just selected then
                        Nothing

                    else
                        Just selected
            }
                |> pushUrl toRoute navKey

        ChangePage from ->
            { model | from = from }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        ShowInstallDetails details ->
            { model | showInstallDetails = details }
                |> pushUrl toRoute navKey


pushUrl :
    Route.SearchRoute
    -> Browser.Navigation.Key
    -> Model a b
    -> ( Model a b, Cmd msg )
pushUrl toRoute navKey model =
    ( model
    , Browser.Navigation.pushUrl navKey <| createUrl toRoute model
    )


createUrl :
    Route.SearchRoute
    -> Model a b
    -> String
createUrl toRoute model =
    let
        justIfNotDefault : t -> t -> Maybe t
        justIfNotDefault fromModel fromDefault =
            if fromModel == fromDefault then
                Nothing

            else
                Just fromModel
    in
    Route.routeToString <|
        toRoute
            { channel = Just model.channel
            , query = justIfNotDefault model.query defaultSearchArgs.query
            , show = model.show
            , from = justIfNotDefault model.from defaultSearchArgs.from
            , size = justIfNotDefault model.size defaultSearchArgs.size
            , buckets = model.buckets
            , sort =
                justIfNotDefault model.sort defaultSearchArgs.sort
                    |> Maybe.map toSortId
            , type_ = justIfNotDefault model.searchType defaultSearchArgs.searchType
            }



-- VIEW


defaultFlakeId : String
defaultFlakeId =
    "group-manual"


sortBy : List Sort
sortBy =
    [ Relevance
    , AlphabeticallyAsc
    , AlphabeticallyDesc
    ]


toAggregations :
    List String
    -> ( String, Json.Encode.Value )
toAggregations bucketsFields =
    let
        fields =
            List.map
                (\field ->
                    ( field
                    , Json.Encode.object
                        [ ( "terms"
                          , Json.Encode.object
                                [ ( "field"
                                  , Json.Encode.string field
                                  )
                                , ( "size"
                                  , Json.Encode.int 20
                                  )
                                ]
                          )
                        ]
                    )
                )
                bucketsFields

        allFields =
            [ ( "all"
              , Json.Encode.object
                    [ ( "global"
                      , Json.Encode.object []
                      )
                    , ( "aggregations"
                      , Json.Encode.object fields
                      )
                    ]
              )
            ]
    in
    ( "aggs"
    , Json.Encode.object <| fields ++ allFields
    )


toSortQuery :
    Sort
    -> String
    -> List String
    -> ( String, Json.Encode.Value )
toSortQuery sort field fields =
    ( "sort"
    , case sort of
        AlphabeticallyAsc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "asc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "asc" ))
                        fields
                ]

        AlphabeticallyDesc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "desc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "desc" ))
                        fields
                ]

        Relevance ->
            Json.Encode.list Json.Encode.object
                [ ( "_score", Json.Encode.string "desc" )
                    :: ( field, Json.Encode.string "desc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "desc" ))
                        fields
                ]
    )


toSortTitle : Sort -> String
toSortTitle sort =
    case sort of
        AlphabeticallyAsc ->
            "Alphabetically Ascending"

        AlphabeticallyDesc ->
            "Alphabetically Descending"

        Relevance ->
            "Best match"


toSortId : Sort -> String
toSortId sort =
    case sort of
        AlphabeticallyAsc ->
            "alpha_asc"

        AlphabeticallyDesc ->
            "alpha_desc"

        Relevance ->
            "relevance"


fromSortId : String -> Maybe Sort
fromSortId id =
    case id of
        "alpha_asc" ->
            Just AlphabeticallyAsc

        "alpha_desc" ->
            Just AlphabeticallyDesc

        "relevance" ->
            Just Relevance

        _ ->
            Nothing


view :
    { categoryName : String
    }
    -> List (Html c)
    -> List NixOSChannel
    -> Model a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> (Msg a b -> c)
    -> List (Html c)
    -> Html c
view { categoryName } title nixosChannels model viewSuccess viewBuckets outMsg searchBuckets =
    let
        resultStatus =
            case model.result of
                RemoteData.NotAsked ->
                    "not-asked"

                RemoteData.Loading ->
                    "loading"

                RemoteData.Success _ ->
                    "success"

                RemoteData.Failure _ ->
                    "failure"
    in
    div
        (List.append
            [ class <| "search-page " ++ resultStatus ]
            (if model.showSort then
                [ onClick (outMsg ToggleSort) ]

             else
                []
            )
        )
        [ h1 [] title
        , viewSearchInput nixosChannels outMsg categoryName (Just model.channel) model.query
        , viewResult nixosChannels outMsg categoryName model viewSuccess viewBuckets searchBuckets
        ]


viewFlakes :
    (Msg a b -> msg)
    -> SearchType
    -> List (Html msg)
viewFlakes outMsg selectedCategory =
    [ li []
        [ ul []
            (List.map
                (\category ->
                    li []
                        [ a
                            [ href "#"
                            , onClick <| outMsg (SubjectChange category)
                            , classList
                                [ ( "selected"
                                  , category == selectedCategory
                                  )
                                ]
                            ]
                            [ span [] [ text <| searchTypeToTitle category ]
                            , closeButton
                            ]
                        ]
                )
                allTypes
            )
        ]
    ]


viewResult :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> Model a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> List (Html c)
    -> Html c
viewResult nixosChannels outMsg categoryName model viewSuccess viewBuckets searchBuckets =
    case model.result of
        RemoteData.NotAsked ->
            div [] []

        RemoteData.Loading ->
            div [ class "loader-wrapper" ]
                [ ul [ class "search-sidebar" ] searchBuckets
                , div [ class "loader" ] [ text "Loading..." ]
                , h2 [] [ text "Searching..." ]
                ]

        RemoteData.Success result ->
            let
                buckets =
                    viewBuckets model.buckets result
            in
            if result.hits.total.value == 0 && List.isEmpty buckets then
                div [ class "search-results" ]
                    [ ul [ class "search-sidebar" ] searchBuckets
                    , viewNoResults categoryName model.query
                    ]

            else if not (List.isEmpty buckets) then
                div [ class "search-results" ]
                    [ ul [ class "search-sidebar" ] (searchBuckets ++ buckets)
                    , div []
                        (viewResults nixosChannels model result viewSuccess outMsg categoryName)
                    ]

            else
                div [ class "search-results" ]
                    [ ul [ class "search-sidebar" ] searchBuckets
                    , div []
                        (viewResults nixosChannels model result viewSuccess outMsg categoryName)
                    ]

        RemoteData.Failure error ->
            let
                ( errorTitle, errorMessage ) =
                    case error of
                        Http.BadUrl text ->
                            ( "Bad Url!", text )

                        Http.Timeout ->
                            ( "Timeout!", "Request to the server timeout." )

                        Http.NetworkError ->
                            ( "Network Error!", "A network request to the search backend failed. This is either due to a content blocker or a networking issue." )

                        Http.BadStatus code ->
                            ( "Bad Status", "Server returned " ++ String.fromInt code )

                        Http.BadBody text ->
                            ( "Bad Body", text )
            in
            div []
                [ div [ class "alert alert-error" ]
                    [ ul [ class "search-sidebar" ] searchBuckets
                    , h4 [] [ text errorTitle ]
                    , text errorMessage
                    ]
                ]


viewNoResults :
    String
    -> String
    -> Html c
viewNoResults categoryName query =
    div [ class "search-no-results" ]
        [ h2 [] [ text <| "No " ++ categoryName ++ " found!" ]
        , text "You might want to "
        , Html.a [ href "https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md#quick-start-to-adding-a-package" ] [ text "add a package" ]
        , text " or "
        , Html.a [ href ("https://github.com/NixOS/nixpkgs/issues?q=" ++ query) ] [ text "search nixpkgs issues" ]
        , text "."
        ]


closeButton : Html a
closeButton =
    span [] []


viewBucket :
    String
    -> List AggregationsBucketItem
    -> (String -> a)
    -> List String
    -> List (Html a)
    -> List (Html a)
viewBucket title buckets searchMsgFor selectedBucket sets =
    List.append
        sets
        (if List.isEmpty buckets then
            []

         else
            [ li []
                [ ul []
                    (List.append
                        [ li [ class "header" ] [ text title ] ]
                        (List.map
                            (\bucket ->
                                li []
                                    [ a
                                        [ href "#"
                                        , onClick <| searchMsgFor bucket.key
                                        , classList
                                            [ ( "selected"
                                              , List.member bucket.key selectedBucket
                                              )
                                            ]
                                        ]
                                        [ span [] [ text bucket.key ]
                                        , if List.member bucket.key selectedBucket then
                                            closeButton

                                          else
                                            span [] [ span [ class "badge" ] [ text <| String.fromInt bucket.doc_count ] ]
                                        ]
                                    ]
                            )
                            buckets
                        )
                    )
                ]
            ]
        )


viewSearchInput :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> Maybe String
    -> String
    -> Html c
viewSearchInput nixosChannels outMsg categoryName selectedChannel searchQuery =
    form
        [ onSubmit (outMsg QueryInputSubmit)
        , class "search-input"
        ]
        (div []
            [ div []
                [ input
                    [ type_ "text"
                    , id "search-query-input"
                    , autofocus True
                    , placeholder <| "Search for " ++ categoryName
                    , onInput (outMsg << QueryInput)
                    , value searchQuery
                    ]
                    []
                ]
            , button [ class "btn", type_ "submit" ]
                [ text "Search" ]
            ]
            :: (selectedChannel
                    |> Maybe.map (\x -> [ div [] (viewChannels nixosChannels outMsg x) ])
                    |> Maybe.withDefault []
               )
        )


viewChannels :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> List (Html c)
viewChannels nixosChannels outMsg selectedChannel =
    List.append
        [ div []
            [ h2 [] [ text "Channel: " ]
            , div
                [ class "btn-group"
                , attribute "data-toggle" "buttons-radio"
                ]
                (List.map
                    (\channel ->
                        button
                            [ type_ "button"
                            , classList
                                [ ( "btn", True )
                                , ( "active", channel.id == selectedChannel )
                                ]
                            , onClick <| outMsg (ChannelChange channel.id)
                            ]
                            (List.intersperse (text " ") (text channel.id :: channelBadge channel.status))
                    )
                    nixosChannels
                )
            ]
        ]
        (if List.any (\{ id } -> id == selectedChannel) nixosChannels then
            []

         else
            [ p [ class "alert alert-error" ]
                [ h4 [] [ text "Wrong channel selected!" ]
                , text <| "Please select one of the channels above!"
                ]
            ]
        )


viewResults :
    List NixOSChannel
    -> Model a b
    -> SearchResult a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    -> (Msg a b -> c)
    -> String
    -> List (Html c)
viewResults nixosChannels model result viewSuccess outMsg categoryName =
    let
        from =
            String.fromInt (model.from + 1)

        to =
            String.fromInt
                (if model.from + model.size > result.hits.total.value then
                    result.hits.total.value

                 else
                    model.from + model.size
                )
    in
    [ div []
        (List.append
            [ Html.map outMsg <| viewSortSelection model
            , h2 []
                (List.append
                    [ text "Showing results "
                    , text from
                    , text "-"
                    , text to
                    , text " of "
                    ]
                    (if result.hits.total.value == 10000 then
                        [ text "more than 10000."
                        , p [] [ text "Please provide more precise search terms." ]
                        ]

                     else
                        let
                            total =
                                String.fromInt result.hits.total.value
                        in
                        [ strong []
                            [ text total
                            , text " "
                            , text categoryName
                            ]
                        , text "."
                        ]
                    )
                )
            ]
            (case List.head result.hits.hits of
                Nothing ->
                    []

                Just elem ->
                    case Array.get 3 (Array.fromList (String.split "-" elem.index)) of
                        Nothing ->
                            []

                        Just commit ->
                            [ text "Data from nixpkgs "
                            , a [ href ("https://github.com/NixOS/nixpkgs/tree/" ++ commit) ]
                                [ code [] [ text (String.slice 0 8 commit) ] ]
                            , text "."
                            ]
            )
        )
    , viewSuccess nixosChannels model.channel model.showInstallDetails model.show result.hits.hits
    , Html.map outMsg <| viewPager model result.hits.total.value
    ]


viewSortSelection :
    Model a b
    -> Html (Msg a b)
viewSortSelection model =
    div
        [ class "btn-group dropdown pull-right"
        , classList
            [ ( "open", model.showSort )
            ]
        , onClickStop NoOp
        ]
        [ button
            [ class "btn"
            , onClick ToggleSort
            ]
            [ span [] [ text <| "Sort: " ]
            , span [ class "selected" ] [ text <| toSortTitle model.sort ]
            , span [ class "caret" ] []
            ]
        , ul
            [ class "pull-right dropdown-menu"
            ]
            (List.append
                [ li [ class " header" ] [ text "Sort options" ]
                , li [ class "divider" ] []
                ]
                (List.map
                    (\sort ->
                        li
                            [ classList
                                [ ( "selected", model.sort == sort )
                                ]
                            ]
                            [ a
                                [ href "#"
                                , onClick <| SortChange sort
                                ]
                                [ text <| toSortTitle sort ]
                            ]
                    )
                    sortBy
                )
            )
        ]


viewPager :
    Model a b
    -> Int
    -> Html (Msg a b)
viewPager model total =
    div []
        [ ul [ class "pager" ]
            [ li []
                [ button
                    [ class "btn"
                    , disabled (model.from == 0)
                    , onClick <|
                        if model.from == 0 then
                            NoOp

                        else
                            ChangePage 0
                    ]
                    [ text "First" ]
                ]
            , li []
                [ button
                    [ class "btn"
                    , disabled (model.from == 0)
                    , onClick <|
                        if model.from - model.size < 0 then
                            NoOp

                        else
                            ChangePage <| model.from - model.size
                    ]
                    [ text "Previous" ]
                ]
            , li []
                [ button
                    [ class "btn"
                    , disabled (model.from + model.size >= total)
                    , onClick <|
                        if model.from + model.size >= total then
                            NoOp

                        else
                            ChangePage <| model.from + model.size
                    ]
                    [ text "Next" ]
                ]
            , li []
                [ button
                    [ class "btn"
                    , disabled (model.from + model.size >= total)
                    , onClick <|
                        if model.from + model.size >= total then
                            NoOp

                        else
                            let
                                remainder =
                                    if remainderBy model.size total == 0 then
                                        1

                                    else
                                        0
                            in
                            ChangePage <| ((total // model.size) - remainder) * model.size
                    ]
                    [ text "Last" ]
                ]
            ]
        ]



-- API


type alias Options =
    { mappingSchemaVersion : Int
    , url : String
    , username : String
    , password : String
    }


filterByType :
    String
    -> List ( String, Json.Encode.Value )
filterByType type_ =
    [ ( "term"
      , Json.Encode.object
            [ ( "type"
              , Json.Encode.object
                    [ ( "value", Json.Encode.string type_ )
                    , ( "_name", Json.Encode.string <| "filter_" ++ type_ ++ "s" )
                    ]
              )
            ]
      )
    ]


searchFields :
    List String
    -> String
    -> List ( String, Float )
    -> List (List ( String, Json.Encode.Value ))
searchFields positiveWords mainField fields =
    let
        allFields : List String
        allFields =
            fields
                |> List.concatMap
                    (\( field, score ) ->
                        [ field ++ "^" ++ String.fromFloat score
                        , field ++ ".*^" ++ String.fromFloat (score * 0.6)
                        ]
                    )

        queryWordsWildCard : List String
        queryWordsWildCard =
            positiveWords
                |> List.concatMap dashUnderscoreVariants
                |> List.Extra.unique

        multiMatch : List ( String, Json.Encode.Value )
        multiMatch =
            [ ( "multi_match"
              , Json.Encode.object
                    [ ( "type", Json.Encode.string "cross_fields" )
                    , ( "query", Json.Encode.string (String.join " " positiveWords) )
                    , ( "analyzer", Json.Encode.string "whitespace" )
                    , ( "auto_generate_synonyms_phrase_query", Json.Encode.bool False )
                    , ( "operator", Json.Encode.string "and" )
                    , ( "_name", Json.Encode.string <| "multi_match_" ++ String.join "_" positiveWords )
                    , ( "fields", Json.Encode.list Json.Encode.string allFields )
                    ]
              )
            ]
    in
    multiMatch :: List.map (toWildcardQuery mainField) queryWordsWildCard


makeRequestBody :
    String
    -> Int
    -> Int
    -> Sort
    -> String
    -> String
    -> List String
    -> List String
    -> List ( String, Json.Encode.Value )
    -> String
    -> List ( String, Float )
    -> Http.Body
makeRequestBody query from sizeRaw sort type_ sortField otherSortFields bucketsFields filterByBuckets mainField fields =
    let
        -- you can not request more then 10000 results otherwise it will return 404
        size =
            if from + sizeRaw > 10000 then
                10000 - from

            else
                sizeRaw

        ( negativeWords, positiveWords ) =
            String.toLower query
                |> String.words
                |> List.partition (String.startsWith "-")
                |> Tuple.mapFirst (List.map (String.dropLeft 1))
    in
    Http.jsonBody
        (Json.Encode.object
            [ ( "from"
              , Json.Encode.int from
              )
            , ( "size"
              , Json.Encode.int size
              )
            , toSortQuery sort sortField otherSortFields
            , toAggregations bucketsFields
            , ( "query"
              , Json.Encode.object
                    [ ( "bool"
                      , Json.Encode.object
                            [ ( "filter"
                              , Json.Encode.list Json.Encode.object
                                    (List.append
                                        [ filterByType type_ ]
                                        (if List.isEmpty filterByBuckets then
                                            []

                                         else
                                            [ filterByBuckets ]
                                        )
                                    )
                              )
                            , ( "must_not"
                              , Json.Encode.list Json.Encode.object
                                    (negativeWords
                                        |> List.concatMap dashUnderscoreVariants
                                        |> List.Extra.unique
                                        |> List.map (toWildcardQuery mainField)
                                    )
                              )
                            , ( "must"
                              , Json.Encode.list Json.Encode.object
                                    [ [ ( "dis_max"
                                        , Json.Encode.object
                                            [ ( "tie_breaker", Json.Encode.float 0.7 )
                                            , ( "queries"
                                              , Json.Encode.list Json.Encode.object
                                                    (searchFields positiveWords mainField fields)
                                              )
                                            ]
                                        )
                                      ]
                                    ]
                              )
                            ]
                      )
                    ]
              )
            ]
        )


{-| Given a word, returns all variants of replacing underscores and dashes with each other.
-}
dashUnderscoreVariants : String -> List String
dashUnderscoreVariants word =
    [ String.replace "_" "-" word
    , String.replace "-" "_" word
    , word
    ]


toWildcardQuery : String -> String -> List ( String, Json.Encode.Value )
toWildcardQuery mainField queryWord =
    [ ( "wildcard"
      , Json.Encode.object
            [ ( mainField
              , Json.Encode.object
                    [ ( "value", Json.Encode.string ("*" ++ queryWord ++ "*") )
                    , ( "case_insensitive", Json.Encode.bool True )
                    ]
              )
            ]
      )
    ]


makeRequest :
    Http.Body
    -> List NixOSChannel
    -> String
    -> Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Options
    -> (RemoteData.WebData (SearchResult a b) -> Msg a b)
    -> Maybe String
    -> Cmd (Msg a b)
makeRequest body nixosChannels channel decodeResultItemSource decodeResultAggregations options responseMsg tracker =
    let
        branch : String
        branch =
            nixosChannels
                |> List.filter (\x -> x.id == channel)
                |> List.head
                |> Maybe.map (\x -> x.branch)
                |> Maybe.withDefault channel

        index =
            "latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ branch
    in
    Http.riskyRequest
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = body
        , expect =
            Http.expectJson
                (RemoteData.fromResult >> responseMsg)
                (decodeResult decodeResultItemSource decodeResultAggregations)
        , timeout = Nothing
        , tracker = tracker
        }



-- JSON


decodeResult :
    Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Json.Decode.Decoder (SearchResult a b)
decodeResult decodeResultItemSource decodeResultAggregations =
    Json.Decode.map2 SearchResult
        (Json.Decode.field "hits" (decodeResultHits decodeResultItemSource))
        (Json.Decode.field "aggregations" decodeResultAggregations)


decodeResultHits : Json.Decode.Decoder a -> Json.Decode.Decoder (ResultHits a)
decodeResultHits decodeResultItemSource =
    Json.Decode.map3 ResultHits
        (Json.Decode.field "total" decodeResultHitsTotal)
        (Json.Decode.field "max_score" (Json.Decode.nullable Json.Decode.float))
        (Json.Decode.field "hits" (Json.Decode.list (decodeResultItem decodeResultItemSource)))


decodeResultHitsTotal : Json.Decode.Decoder ResultHitsTotal
decodeResultHitsTotal =
    Json.Decode.map2 ResultHitsTotal
        (Json.Decode.field "value" Json.Decode.int)
        (Json.Decode.field "relation" Json.Decode.string)


decodeResultItem : Json.Decode.Decoder a -> Json.Decode.Decoder (ResultItem a)
decodeResultItem decodeResultItemSource =
    Json.Decode.map6 ResultItem
        (Json.Decode.field "_index" Json.Decode.string)
        (Json.Decode.field "_id" Json.Decode.string)
        (Json.Decode.field "_score" (Json.Decode.nullable Json.Decode.float))
        (Json.Decode.field "_source" decodeResultItemSource)
        (Json.Decode.maybe (Json.Decode.field "text" Json.Decode.string))
        (Json.Decode.maybe (Json.Decode.field "matched_queries" (Json.Decode.list Json.Decode.string)))


decodeAggregation : Json.Decode.Decoder Aggregation
decodeAggregation =
    Json.Decode.map3 Aggregation
        (Json.Decode.field "doc_count_error_upper_bound" Json.Decode.int)
        (Json.Decode.field "sum_other_doc_count" Json.Decode.int)
        (Json.Decode.field "buckets" (Json.Decode.list decodeAggregationBucketItem))


decodeAggregationBucketItem : Json.Decode.Decoder AggregationsBucketItem
decodeAggregationBucketItem =
    Json.Decode.map2 AggregationsBucketItem
        (Json.Decode.field "doc_count" Json.Decode.int)
        (Json.Decode.field "key" Json.Decode.string)



-- Html Helper elemetnts


showMoreButton : msg -> Bool -> Html msg
showMoreButton toggle isOpen =
    div [ class "result-item-show-more-wrapper" ]
        [ a
            [ href "#"
            , onClick toggle
            , class "result-item-show-more"
            ]
            [ text <|
                if isOpen then
                    "▲▲▲ Hide package details ▲▲▲"

                else
                    "▾▾▾ Show more package details ▾▾▾"
            ]
        ]



-- Html Event Helpers


onClickStop : msg -> Html.Attribute msg
onClickStop message =
    Html.Events.custom "click" <|
        Json.Decode.succeed
            { message = message
            , stopPropagation = True
            , preventDefault = True
            }


trapClick : Html.Attribute (Msg a b)
trapClick =
    Html.Events.stopPropagationOn "click" <|
        Json.Decode.succeed ( NoOp, True )
