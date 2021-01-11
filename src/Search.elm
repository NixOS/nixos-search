module Search exposing
    ( Aggregation
    , AggregationsBucketItem
    , Model
    , Msg(..)
    , Options
    , ResultItem
    , SearchResult
    , Sort(..)
    , channelDetailsFromId
    , channels
    , decodeAggregation
    , decodeResult
    , elementId
    , fromSortId
    , init
    , makeRequest
    , makeRequestBody
    , shouldLoad
    , update
    , view
    )

import Base64
import Browser.Dom
import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , button
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
import Json.Encode
import RemoteData
import Route
import Route.SearchQuery
import Set
import Task


type alias Model a b =
    { channel : String
    , query : Maybe String
    , result : RemoteData.WebData (SearchResult a b)
    , show : Maybe String
    , from : Int
    , size : Int
    , buckets : Maybe String
    , sort : Sort
    , showNixOSDetails : Bool
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


init :
    Route.SearchArgs
    -> Maybe (Model a b)
    -> ( Model a b, Cmd (Msg a b) )
init args maybeModel =
    let
        getField getFn default =
            maybeModel
                |> Maybe.map getFn
                |> Maybe.withDefault default

        modelChannel =
            getField .channel defaultChannel

        modelFrom =
            getField .from 0

        modelSize =
            getField .size 50
    in
    ( { channel =
            args.channel
                |> Maybe.withDefault modelChannel
      , query =
            args.query
                |> Maybe.andThen Route.SearchQuery.searchQueryToString
      , result = getField .result RemoteData.NotAsked
      , show = args.show
      , from =
            args.from
                |> Maybe.withDefault modelFrom
      , size =
            args.size
                |> Maybe.withDefault modelSize
      , buckets = args.buckets
      , sort =
            args.sort
                |> Maybe.withDefault ""
                |> fromSortId
                |> Maybe.withDefault Relevance
      , showNixOSDetails = False
      }
        |> ensureLoading
    , Browser.Dom.focus "search-query-input" |> Task.attempt (\_ -> NoOp)
    )


shouldLoad :
    Model a b
    -> Bool
shouldLoad model =
    model.result == RemoteData.Loading


ensureLoading :
    Model a b
    -> Model a b
ensureLoading model =
    if model.query /= Nothing && model.query /= Just "" && List.member model.channel channels then
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
    | SortChange String
    | BucketsChange String
    | ChannelChange String
    | QueryInput String
    | QueryInputSubmit
    | QueryResponse (RemoteData.WebData (SearchResult a b))
    | ShowDetails String
    | ChangePage Int
    | ShowNixOSDetails Bool


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
    -> ( Model a b, Cmd (Msg a b) )
update toRoute navKey msg model =
    case msg of
        NoOp ->
            ( model
            , Cmd.none
            )

        SortChange sortId ->
            { model
                | sort = fromSortId sortId |> Maybe.withDefault Relevance
                , from = 0
            }
                |> ensureLoading
                |> pushUrl toRoute navKey

        BucketsChange buckets ->
            { model
                | buckets =
                    if buckets == "" then
                        Nothing

                    else
                        Just buckets
                , from = 0
            }
                |> ensureLoading
                |> pushUrl toRoute navKey

        ChannelChange channel ->
            { model
                | channel = channel
                , from = 0
            }
                |> ensureLoading
                |> pushUrl toRoute navKey

        QueryInput query ->
            ( { model | query = Just query }
            , Cmd.none
            )

        QueryInputSubmit ->
            { model
                | from = 0
                , buckets = Nothing
            }
                |> ensureLoading
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
                |> ensureLoading
                |> pushUrl toRoute navKey

        ShowNixOSDetails show ->
            { model | showNixOSDetails = show }
                |> pushUrl toRoute navKey


pushUrl :
    Route.SearchRoute
    -> Browser.Navigation.Key
    -> Model a b
    -> ( Model a b, Cmd msg )
pushUrl toRoute navKey model =
    Tuple.pair model <|
        if model.query == Nothing || model.query == Just "" then
            Cmd.none

        else
            Browser.Navigation.pushUrl navKey <| createUrl toRoute model


createUrl :
    Route.SearchRoute
    -> Model a b
    -> String
createUrl toRoute model =
    Route.routeToString <|
        toRoute
            { channel = Just model.channel
            , query = Maybe.map Route.SearchQuery.toSearchQuery model.query
            , show = model.show
            , from = Just model.from
            , size = Just model.size
            , buckets = model.buckets
            , sort = Just <| toSortId model.sort
            }



-- VIEW


type Channel
    = Unstable
    | Release_20_03
    | Release_20_09


{-| TODO: we should consider using more dynamic approach here
and load channels from apis similar to what status page does
-}
type alias ChannelDetails =
    { id : String
    , title : String
    , jobset : String
    , branch : String
    }


defaultChannel : String
defaultChannel =
    "20.09"


channelDetails : Channel -> ChannelDetails
channelDetails channel =
    case channel of
        Unstable ->
            ChannelDetails "unstable" "unstable" "nixos/trunk-combined" "nixos-unstable"

        Release_20_03 ->
            ChannelDetails "20.03" "20.03" "nixos/release-20.03" "nixos-20.03"

        Release_20_09 ->
            ChannelDetails "20.09" "20.09" "nixos/release-20.09" "nixos-20.09"


channelFromId : String -> Maybe Channel
channelFromId channel_id =
    case channel_id of
        "unstable" ->
            Just Unstable

        "20.03" ->
            Just Release_20_03

        "20.09" ->
            Just Release_20_09

        _ ->
            Nothing


channelDetailsFromId : String -> Maybe ChannelDetails
channelDetailsFromId channel_id =
    channelFromId channel_id
        |> Maybe.map channelDetails


channels : List String
channels =
    [ "20.03"
    , "20.09"
    , "unstable"
    ]


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
    ( "aggregations"
    , Json.Encode.object <|
        List.append fields allFields
    )


toSortQuery :
    Sort
    -> String
    -> ( String, Json.Encode.Value )
toSortQuery sort field =
    ( "sort"
    , case sort of
        AlphabeticallyAsc ->
            Json.Encode.list Json.Encode.object
                [ [ ( field, Json.Encode.string "asc" )
                  ]
                ]

        AlphabeticallyDesc ->
            Json.Encode.list Json.Encode.object
                [ [ ( field, Json.Encode.string "desc" )
                  ]
                ]

        Relevance ->
            Json.Encode.list Json.Encode.string
                [ "_score"
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
    { toRoute : Route.SearchRoute
    , categoryName : String
    }
    -> List (Html c)
    -> Model a b
    ->
        (String
         -> Bool
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
    -> Html c
view { toRoute, categoryName } title model viewSuccess viewBuckets outMsg =
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
    div [ class <| "search-page " ++ resultStatus ]
        [ h1 [] title
        , viewSearchInput outMsg categoryName model.channel model.query
        , viewResult outMsg toRoute categoryName model viewSuccess viewBuckets
        ]


viewResult :
    (Msg a b -> c)
    -> Route.SearchRoute
    -> String
    -> Model a b
    ->
        (String
         -> Bool
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> Html c
viewResult outMsg toRoute categoryName model viewSuccess viewBuckets =
    case model.result of
        RemoteData.NotAsked ->
            div [] [ text "" ]

        RemoteData.Loading ->
            div [ class "loader-wrapper" ]
                [ div [ class "loader" ] [ text "Loading..." ]
                , h2 [] [ text "Searching..." ]
                ]

        RemoteData.Success result ->
            if result.hits.total.value == 0 then
                viewNoResults categoryName

            else
                let
                    buckets =
                        viewBuckets model.buckets result
                in
                if List.length buckets > 0 then
                    div [ class "search-results" ]
                        [ ul [] buckets
                        , div []
                            (viewResults model result viewSuccess toRoute outMsg categoryName)
                        ]

                else
                    div [ class "search-results" ]
                        [ div []
                            (viewResults model result viewSuccess toRoute outMsg categoryName)
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
                            ( "Network Error!", "A network request bonsaisearch.net domain failed. This is either due to a content blocker or a networking issue." )

                        Http.BadStatus code ->
                            ( "Bad Status", "Server returned " ++ String.fromInt code )

                        Http.BadBody text ->
                            ( "Bad Body", text )
            in
            div []
                [ div [ class "alert alert-error" ]
                    [ h4 [] [ text errorTitle ]
                    , text errorMessage
                    ]
                ]


viewNoResults :
    String
    -> Html c
viewNoResults categoryName =
    div [ class "search-no-results" ]
        [ h2 [] [ text <| "No " ++ categoryName ++ " found!" ]
        , text "How to "
        , Html.a [ href "https://nixos.org/manual/nixpkgs/stable/#chap-quick-start" ] [ text "add" ]
        , text " or "
        , a [ href "https://github.com/NixOS/nixpkgs/issues/new?assignees=&labels=0.kind%3A+packaging+request&template=packaging_request.md&title=" ] [ text "request" ]
        , text " package to nixpkgs?"
        ]


viewSearchInput :
    (Msg a b -> c)
    -> String
    -> String
    -> Maybe String
    -> Html c
viewSearchInput outMsg categoryName selectedChannel searchQuery =
    form
        [ onSubmit (outMsg QueryInputSubmit)
        , class "search-input"
        ]
        [ div []
            [ div []
                [ input
                    [ type_ "text"
                    , id "search-query-input"
                    , autofocus True
                    , placeholder <| "Search for " ++ categoryName
                    , onInput (outMsg << QueryInput)
                    , value <| Maybe.withDefault "" searchQuery
                    ]
                    []
                ]
            , button [ class "btn", type_ "submit" ]
                [ text "Search" ]
            ]
        , div [] (viewChannels outMsg selectedChannel)
        ]


viewChannels :
    (Msg a b -> c)
    -> String
    -> List (Html c)
viewChannels outMsg selectedChannel =
    List.append
        [ div []
            [ h4 [] [ text "Channel: " ]
            , div
                [ class "btn-group"
                , attribute "data-toggle" "buttons-radio"
                ]
                (List.filterMap
                    (\channelId ->
                        channelDetailsFromId channelId
                            |> Maybe.map
                                (\channel ->
                                    button
                                        [ type_ "button"
                                        , classList
                                            [ ( "btn", True )
                                            , ( "active", channel.id == selectedChannel )
                                            ]
                                        , onClick <| outMsg (ChannelChange channel.id)
                                        ]
                                        [ text channel.title ]
                                )
                    )
                    channels
                )
            ]
        ]
        (if List.member selectedChannel channels then
            []

         else
            [ p [ class "alert alert-error" ]
                [ h4 [] [ text "Wrong channel selected!" ]
                , text <| "Please select one of the channels above!"
                ]
            ]
        )


viewResults :
    Model a b
    -> SearchResult a b
    ->
        (String
         -> Bool
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    -> Route.SearchRoute
    -> (Msg a b -> c)
    -> String
    -> List (Html c)
viewResults model result viewSuccess toRoute outMsg categoryName =
    let
        from =
            String.fromInt model.from

        to =
            String.fromInt
                (if model.from + model.size > result.hits.total.value then
                    result.hits.total.value

                 else
                    model.from + model.size
                )

        total =
            String.fromInt result.hits.total.value
    in
    [ div []
        [ viewSortSelection toRoute model
        , div []
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
    , viewSuccess model.channel model.showNixOSDetails model.show result.hits.hits
    , viewPager outMsg model result.hits.total.value
    ]


viewSortSelection :
    Route.SearchRoute
    -> Model a b
    -> Html c
viewSortSelection toRoute model =
    div [ class "btn-group dropdown pull-right" ]
        [ button
            [ class "btn"
            , attribute "data-toggle" "dropdown"
            ]
            [ span [] [ text <| "Sort: " ]
            , span [ class "selected" ] [ text <| toSortTitle model.sort ]
            , span [ class "caret" ] []
            ]
        , ul [ class "dropdown-menu pull-right" ]
            (List.append
                [ li [ class " header" ] [ text "Sort options" ]
                , li [ class "divider" ] []
                ]
                (List.map
                    (\sort ->
                        let
                            url =
                                createUrl toRoute
                                    { model | sort = sort }
                        in
                        li
                            [ classList
                                [ ( "selected", model.sort == sort )
                                ]
                            ]
                            [ a
                                [ href url ]
                                [ text <| toSortTitle sort ]
                            ]
                    )
                    sortBy
                )
            )
        ]



--form [ class "form-horizontal pull-right sort-form" ]
--    [ div [ class "control-group sort-group" ]
--        [ label [ class "control-label" ] [ text "Sort by:" ]
--        , div
--            [ class "controls" ]
--            [ select
--                [ onInput (\x -> outMsg (SortChange x))
--                ]
--                (List.map
--                    (\sort ->
--                        option
--                            [ selected (model.sort == sort)
--                            , value (toSortId sort)
--                            ]
--                            [ text <| toSortTitle sort ]
--                    )
--                    sortBy
--                )
--            ]
--        ]
--    ]


viewPager :
    (Msg a b -> c)
    -> Model a b
    -> Int
    -> Html c
viewPager outMsg model total =
    Html.map outMsg <|
        div []
            [ ul [ class "pager" ]
                [ li [ classList [ ( "disabled", model.from == 0 ) ] ]
                    [ a
                        [ Html.Events.onClick <|
                            if model.from == 0 then
                                NoOp

                            else
                                ChangePage 0
                        ]
                        [ text "First" ]
                    ]
                , li [ classList [ ( "disabled", model.from == 0 ) ] ]
                    [ a
                        [ Html.Events.onClick <|
                            if model.from - model.size < 0 then
                                NoOp

                            else
                                ChangePage <| model.from - model.size
                        ]
                        [ text "Previous" ]
                    ]
                , li [ classList [ ( "disabled", model.from + model.size >= total ) ] ]
                    [ a
                        [ Html.Events.onClick <|
                            if model.from + model.size >= total then
                                NoOp

                            else
                                ChangePage <| model.from + model.size
                        ]
                        [ text "Next" ]
                    ]
                , li [ classList [ ( "disabled", model.from + model.size >= total ) ] ]
                    [ a
                        [ Html.Events.onClick <|
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
    String
    -> List ( String, Float )
    -> List (List ( String, Json.Encode.Value ))
searchFields query fields =
    let
        queryVariations q =
            case ( List.head q, List.tail q ) of
                ( Just h, Just t ) ->
                    let
                        tail : List (List String)
                        tail =
                            queryVariations t
                    in
                    List.append
                        (List.map (\x -> List.append [ h ] x) tail)
                        (List.map (\x -> List.append [ String.reverse h ] x) tail)
                        |> Set.fromList
                        |> Set.toList

                ( Just h, Nothing ) ->
                    [ [ h ], [ String.reverse h ] ]

                ( _, _ ) ->
                    [ [], [] ]

        reverseFields =
            List.map (\( field, score ) -> ( field ++ "_reverse", score * 0.8 )) fields

        allFields =
            List.append fields reverseFields
                |> List.map (\( field, score ) -> [ field ++ "^" ++ String.fromFloat score, field ++ ".edge^" ++ String.fromFloat score ])
                |> List.concat
    in
    List.map
        (\queryWords ->
            [ ( "multi_match"
              , Json.Encode.object
                    [ ( "type", Json.Encode.string "cross_fields" )
                    , ( "query", Json.Encode.string <| String.join " " queryWords )
                    , ( "analyzer", Json.Encode.string "whitespace" )
                    , ( "auto_generate_synonyms_phrase_query", Json.Encode.bool False )
                    , ( "operator", Json.Encode.string "and" )
                    , ( "_name", Json.Encode.string <| "multi_match_" ++ String.join "_" queryWords )
                    , ( "fields", Json.Encode.list Json.Encode.string allFields )
                    ]
              )
            ]
        )
        (queryVariations (String.words query))


makeRequestBody :
    String
    -> Int
    -> Int
    -> Sort
    -> String
    -> String
    -> List String
    -> List ( String, Json.Encode.Value )
    -> List ( String, Float )
    -> Http.Body
makeRequestBody query from sizeRaw sort type_ sortField bucketsFields filterByBuckets fields =
    let
        -- you can not request more then 10000 results otherwise it will return 404
        size =
            if from + sizeRaw > 10000 then
                10000 - from

            else
                sizeRaw
    in
    Http.jsonBody
        (Json.Encode.object
            (List.append
                [ ( "from"
                  , Json.Encode.int from
                  )
                , ( "size"
                  , Json.Encode.int size
                  )
                , toSortQuery sort sortField
                , toAggregations bucketsFields
                , ( "query"
                  , Json.Encode.object
                        [ ( "bool"
                          , Json.Encode.object
                                [ ( "filter"
                                  , Json.Encode.list Json.Encode.object
                                        [ filterByType type_ ]
                                  )
                                , ( "must"
                                  , Json.Encode.list Json.Encode.object
                                        [ [ ( "dis_max"
                                            , Json.Encode.object
                                                [ ( "tie_breaker", Json.Encode.float 0.7 )
                                                , ( "queries"
                                                  , Json.Encode.list Json.Encode.object
                                                        (searchFields query fields)
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
                (if List.isEmpty filterByBuckets then
                    []

                 else
                    [ ( "post_filter", Json.Encode.object filterByBuckets ) ]
                )
            )
        )


makeRequest :
    Http.Body
    -> String
    -> Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Options
    -> (RemoteData.WebData (SearchResult a b) -> Msg a b)
    -> Maybe String
    -> Cmd (Msg a b)
makeRequest body index decodeResultItemSource decodeResultAggregations options responseMsg tracker =
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
