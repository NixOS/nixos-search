module Search exposing
    ( Model
    , Msg(..)
    , Options
    , ResultItem
    , SearchResult
    , Sort(..)
    , channelDetailsFromId
    , decodeResult
    , fromSortId
    , init
    , makeRequest
    , makeRequestBody
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
        , em
        , form
        , h1
        , h4
        , input
        , label
        , li
        , option
        , p
        , select
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
        , selected
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
import Task
import Url.Builder


type alias Model a =
    { channel : String
    , query : Maybe String
    , result : RemoteData.WebData (SearchResult a)
    , show : Maybe String
    , from : Int
    , size : Int
    , sort : Sort
    }


type alias SearchResult a =
    { hits : ResultHits a
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


type Sort
    = Relevance
    | AlphabeticallyAsc
    | AlphabeticallyDesc


init :
    Maybe String
    -> Maybe String
    -> Maybe String
    -> Maybe Int
    -> Maybe Int
    -> Maybe String
    -> Maybe (Model a)
    -> ( Model a, Cmd (Msg a) )
init channel query show from size sort model =
    let
        defaultChannel =
            model
                |> Maybe.map (\x -> x.channel)
                |> Maybe.withDefault "unstable"

        defaultFrom =
            model
                |> Maybe.map (\x -> x.from)
                |> Maybe.withDefault 0

        defaultSize =
            model
                |> Maybe.map (\x -> x.size)
                |> Maybe.withDefault 15
    in
    ( { channel = Maybe.withDefault defaultChannel channel
      , query = query
      , result =
            model
                |> Maybe.map (\x -> x.result)
                |> Maybe.withDefault RemoteData.NotAsked
      , show = show
      , from = Maybe.withDefault defaultFrom from
      , size = Maybe.withDefault defaultSize size
      , sort =
            sort
                |> Maybe.withDefault ""
                |> fromSortId
                |> Maybe.withDefault Relevance
      }
    , Browser.Dom.focus "search-query-input" |> Task.attempt (\_ -> NoOp)
    )



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg a
    = NoOp
    | SortChange String
    | ChannelChange String
    | QueryInput String
    | QueryInputSubmit
    | QueryResponse (RemoteData.WebData (SearchResult a))
    | ShowDetails String


update :
    String
    -> Browser.Navigation.Key
    -> Msg a
    -> Model a
    -> ( Model a, Cmd (Msg a) )
update path navKey msg model =
    case msg of
        NoOp ->
            ( model
            , Cmd.none
            )

        SortChange sortId ->
            let
                sort =
                    fromSortId sortId |> Maybe.withDefault Relevance
            in
            ( { model | sort = sort }
            , createUrl
                path
                model.channel
                model.query
                model.show
                0
                model.size
                sort
                |> Browser.Navigation.pushUrl navKey
            )

        ChannelChange channel ->
            ( { model
                | channel = channel
                , result =
                    if model.query == Nothing || model.query == Just "" then
                        RemoteData.NotAsked

                    else
                        RemoteData.Loading
              }
            , if model.query == Nothing || model.query == Just "" then
                Cmd.none

              else
                createUrl
                    path
                    channel
                    model.query
                    model.show
                    0
                    model.size
                    model.sort
                    |> Browser.Navigation.pushUrl navKey
            )

        QueryInput query ->
            ( { model | query = Just query }
            , Cmd.none
            )

        QueryInputSubmit ->
            if model.query == Nothing || model.query == Just "" then
                ( model, Cmd.none )

            else
                ( { model | result = RemoteData.Loading }
                , createUrl
                    path
                    model.channel
                    model.query
                    model.show
                    0
                    model.size
                    model.sort
                    |> Browser.Navigation.pushUrl navKey
                )

        QueryResponse result ->
            ( { model | result = result }
            , Cmd.none
            )

        ShowDetails selected ->
            ( model
            , createUrl
                path
                model.channel
                model.query
                (if model.show == Just selected then
                    Nothing

                 else
                    Just selected
                )
                model.from
                model.size
                model.sort
                |> (\x -> x ++ "#disabled")
                |> Browser.Navigation.pushUrl navKey
            )


createUrl :
    String
    -> String
    -> Maybe String
    -> Maybe String
    -> Int
    -> Int
    -> Sort
    -> String
createUrl path channel query show from size sort =
    [ Url.Builder.int "from" from
    , Url.Builder.int "size" size
    , Url.Builder.string "sort" <| toSortId sort
    , Url.Builder.string "channel" channel
    ]
        |> List.append
            (query
                |> Maybe.map
                    (\x ->
                        [ Url.Builder.string "query" x ]
                    )
                |> Maybe.withDefault []
            )
        |> List.append
            (show
                |> Maybe.map
                    (\x ->
                        [ Url.Builder.string "show" x
                        ]
                    )
                |> Maybe.withDefault []
            )
        |> Url.Builder.absolute [ path ]



-- VIEW


type Channel
    = Unstable
    | Release_19_09
    | Release_20_03


type alias ChannelDetails =
    { id : String
    , title : String
    , jobset : String
    , branch : String
    }


channelDetails : Channel -> ChannelDetails
channelDetails channel =
    case channel of
        Unstable ->
            ChannelDetails "unstable" "unstable" "nixos/trunk-combined" "nixos-unstable"

        Release_19_09 ->
            ChannelDetails "19.09" "19.09" "nixos/release-19.09" "nixos-19.09"

        Release_20_03 ->
            ChannelDetails "20.03" "20.03" "nixos/release-20.03" "nixos-20.03"


channelFromId : String -> Maybe Channel
channelFromId channel_id =
    case channel_id of
        "unstable" ->
            Just Unstable

        "19.09" ->
            Just Release_19_09

        "20.03" ->
            Just Release_20_03

        _ ->
            Nothing


channelDetailsFromId : String -> Maybe ChannelDetails
channelDetailsFromId channel_id =
    channelFromId channel_id
        |> Maybe.map channelDetails


channels : List String
channels =
    [ "19.09"
    , "20.03"
    , "unstable"
    ]


sortBy : List Sort
sortBy =
    [ Relevance
    , AlphabeticallyAsc
    , AlphabeticallyDesc
    ]


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
            "Relevance"


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
    String
    -> String
    -> Model a
    -> (String -> Maybe String -> SearchResult a -> Html b)
    -> (Msg a -> b)
    -> Html b
view path title model viewSuccess outMsg =
    div
        [ class "search-page"
        ]
        [ h1 [ class "page-header" ] [ text title ]
        , div
            [ class "search-input"
            ]
            [ form [ onSubmit (outMsg QueryInputSubmit) ]
                [ p
                    []
                    [ strong []
                        [ text "Channel: " ]
                    , div
                        [ class "btn-group"
                        , attribute "data-toggle" "buttons-radio"
                        ]
                        (List.filterMap
                            (\channel_id ->
                                channelDetailsFromId channel_id
                                    |> Maybe.map
                                        (\channel ->
                                            button
                                                [ type_ "button"
                                                , classList
                                                    [ ( "btn", True )
                                                    , ( "active", channel.id == model.channel )
                                                    ]
                                                , onClick <| outMsg (ChannelChange channel.id)
                                                ]
                                                [ text channel.title ]
                                        )
                            )
                            channels
                        )
                    ]
                , p
                    [ class "input-append"
                    ]
                    [ input
                        [ type_ "text"
                        , id "search-query-input"
                        , autofocus True
                        , placeholder <| "Search for " ++ path
                        , onInput (\x -> outMsg (QueryInput x))
                        , value <| Maybe.withDefault "" model.query
                        ]
                        []
                    , div [ class "loader" ] []
                    , div [ class "btn-group" ]
                        [ button [ class "btn" ] [ text "Search" ]
                        ]
                    ]
                ]
            ]
        , case model.result of
            RemoteData.NotAsked ->
                div [] [ text "" ]

            RemoteData.Loading ->
                div [ class "loader" ] [ text "Loading..." ]

            RemoteData.Success result ->
                if result.hits.total.value == 0 then
                    div []
                        [ h4 [] [ text <| "No " ++ path ++ " found!" ]
                        ]

                else
                    div []
                        [ p []
                            [ em []
                                [ text
                                    ("Showing results "
                                        ++ String.fromInt model.from
                                        ++ "-"
                                        ++ String.fromInt
                                            (if model.from + model.size > result.hits.total.value then
                                                result.hits.total.value

                                             else
                                                model.from + model.size
                                            )
                                        ++ " of "
                                        ++ (if result.hits.total.value == 10000 then
                                                "more than 10000 results, please provide more precise search terms."

                                            else
                                                String.fromInt result.hits.total.value
                                                    ++ "."
                                           )
                                    )
                                ]
                            ]
                        , form [ class "form-horizontal pull-right" ]
                            [ div
                                [ class "control-group"
                                ]
                                [ label [ class "control-label" ] [ text "Sort by:" ]
                                , div
                                    [ class "controls" ]
                                    [ select
                                        [ onInput (\x -> outMsg (SortChange x))
                                        ]
                                        (List.map
                                            (\sort ->
                                                option
                                                    [ selected (model.sort == sort)
                                                    , value (toSortId sort)
                                                    ]
                                                    [ text <| toSortTitle sort ]
                                            )
                                            sortBy
                                        )
                                    ]
                                ]
                            ]
                        , viewPager outMsg model result path
                        , viewSuccess model.channel model.show result
                        , viewPager outMsg model result path
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
                div [ class "alert alert-error" ]
                    [ h4 [] [ text errorTitle ]
                    , text errorMessage
                    ]
        ]


viewPager :
    (Msg a -> b)
    -> Model a
    -> SearchResult a
    -> String
    -> Html b
viewPager _ model result path =
    ul [ class "pager" ]
        [ li
            [ classList
                [ ( "disabled", model.from == 0 )
                ]
            ]
            [ a
                [ if model.from == 0 then
                    href "#disabled"

                  else
                    href <|
                        createUrl
                            path
                            model.channel
                            model.query
                            model.show
                            0
                            model.size
                            model.sort
                ]
                [ text "First" ]
            ]
        , li
            [ classList
                [ ( "disabled", model.from == 0 )
                ]
            ]
            [ a
                [ href <|
                    if model.from - model.size < 0 then
                        "#disabled"

                    else
                        createUrl
                            path
                            model.channel
                            model.query
                            model.show
                            (model.from - model.size)
                            model.size
                            model.sort
                ]
                [ text "Previous" ]
            ]
        , li
            [ classList
                [ ( "disabled", model.from + model.size >= result.hits.total.value )
                ]
            ]
            [ a
                [ href <|
                    if model.from + model.size >= result.hits.total.value then
                        "#disabled"

                    else
                        createUrl
                            path
                            model.channel
                            model.query
                            model.show
                            (model.from + model.size)
                            model.size
                            model.sort
                ]
                [ text "Next" ]
            ]
        , li
            [ classList
                [ ( "disabled", model.from + model.size >= result.hits.total.value )
                ]
            ]
            [ a
                [ href <|
                    if model.from + model.size >= result.hits.total.value then
                        "#disabled"

                    else
                        let
                            remainder =
                                if remainderBy model.size result.hits.total.value == 0 then
                                    1

                                else
                                    0
                        in
                        createUrl
                            path
                            model.channel
                            model.query
                            model.show
                            (((result.hits.total.value // model.size) - remainder) * model.size)
                            model.size
                            model.sort
                ]
                [ text "Last" ]
            ]
        ]



-- API


type alias Options =
    { mappingSchemaVersion : Int
    , url : String
    , username : String
    , password : String
    }


filter_by_type :
    String
    -> ( String, Json.Encode.Value )
filter_by_type type_ =
    ( "term"
    , Json.Encode.object
        [ ( "type"
          , Json.Encode.object
                [ ( "value", Json.Encode.string type_ )
                , ( "_name", Json.Encode.string <| "filter_" ++ type_ ++ "s" )
                ]
          )
        ]
    )


filter_by_query :
    List String
    -> String
    -> ( String, Json.Encode.Value )
filter_by_query fields queryRaw =
    let
        query =
            queryRaw
                |> String.trim
    in
    ( "bool"
    , Json.Encode.object
        [ ( "should"
          , Json.Encode.list Json.Encode.object
                (query
                    |> String.words
                    |> List.indexedMap
                        (\i query_word ->
                            [ ( "bool"
                              , Json.Encode.object
                                    [ ( "should"
                                      , Json.Encode.list Json.Encode.object
                                            (List.concatMap
                                                (\field ->
                                                    [ [ ( "match"
                                                        , Json.Encode.object
                                                            [ ( field
                                                              , Json.Encode.object
                                                                    [ ( "query", Json.Encode.string query_word )
                                                                    , ( "fuzziness", Json.Encode.string "1" )
                                                                    , ( "_name", Json.Encode.string <| "filter_queries_" ++ String.fromInt i ++ "_should_match" )
                                                                    ]
                                                              )
                                                            ]
                                                        )
                                                      ]
                                                    , [ ( "match_bool_prefix"
                                                        , Json.Encode.object
                                                            [ ( field
                                                              , Json.Encode.object
                                                                    [ ( "query", Json.Encode.string query_word )
                                                                    , ( "_name"
                                                                      , Json.Encode.string <| "filter_queries_" ++ String.fromInt (i + 1) ++ "_should_prefix"
                                                                      )
                                                                    ]
                                                              )
                                                            ]
                                                        )
                                                      ]
                                                    ]
                                                )
                                                fields
                                            )
                                      )
                                    ]
                              )
                            ]
                        )
                )
          )
        ]
    )


makeRequestBody :
    String
    -> Int
    -> Int
    -> Sort
    -> String
    -> String
    -> List String
    -> List (List ( String, Json.Encode.Value ))
    -> Http.Body
makeRequestBody query from sizeRaw sort type_ sort_field query_fields should_queries =
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
            [ ( "from"
              , Json.Encode.int from
              )
            , ( "size"
              , Json.Encode.int size
              )
            , toSortQuery sort sort_field
            , ( "query"
              , Json.Encode.object
                    [ ( "bool"
                      , Json.Encode.object
                            [ ( "filter"
                              , Json.Encode.list Json.Encode.object
                                    [ [ filter_by_type type_ ]
                                    , [ filter_by_query query_fields query ]
                                    ]
                              )
                            , ( "should"
                              , Json.Encode.list Json.Encode.object should_queries
                              )
                            ]
                      )
                    ]
              )
            ]
        )


makeRequest :
    Http.Body
    -> String
    -> Json.Decode.Decoder a
    -> Options
    -> (RemoteData.WebData (SearchResult a) -> Msg a)
    -> Maybe String
    -> Cmd (Msg a)
makeRequest body index decodeResultItemSource options responseMsg tracker =
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
                (decodeResult decodeResultItemSource)
        , timeout = Nothing
        , tracker = tracker
        }



-- JSON


decodeResult :
    Json.Decode.Decoder a
    -> Json.Decode.Decoder (SearchResult a)
decodeResult decodeResultItemSource =
    Json.Decode.map SearchResult
        (Json.Decode.field "hits" (decodeResultHits decodeResultItemSource))


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
