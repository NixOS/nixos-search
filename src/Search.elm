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

import Array
import Base64
import Browser.Dom
import Browser.Navigation
import Debouncer.Messages
import Dict
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
        , autocomplete
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
        ( custom
        , onClick
        , onInput
        , onSubmit
        )
import Http
import Json.Decode
import Json.Encode
import Keyboard
import Keyboard.Events
import RemoteData
import Task
import Url.Builder


type alias Model a =
    { channel : String
    , query : Maybe String
    , queryDebounce : Debouncer.Messages.Debouncer (Msg a)
    , querySuggest : RemoteData.WebData (SearchResult a)
    , querySelectedSuggestion : Maybe String
    , result : RemoteData.WebData (SearchResult a)
    , show : Maybe String
    , from : Int
    , size : Int
    , sort : Sort
    }


type alias SearchResult a =
    { hits : ResultHits a
    , suggest : Maybe (SearchSuggest a)
    }


type alias SearchSuggest a =
    { query : Maybe (List (SearchSuggestQuery a))
    }


type alias SearchSuggestQuery a =
    { text : String
    , offset : Int
    , length : Int
    , options : List (ResultItem a)
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
      , queryDebounce =
            Debouncer.Messages.manual
                |> Debouncer.Messages.settleWhenQuietFor (Just <| Debouncer.Messages.fromSeconds 0.4)
                |> Debouncer.Messages.toDebouncer
      , query = query
      , querySuggest =
            query
                |> Maybe.map
                    (\selected ->
                        if String.endsWith "." selected then
                            model
                                |> Maybe.map .querySuggest
                                |> Maybe.withDefault RemoteData.NotAsked

                        else
                            RemoteData.NotAsked
                    )
                |> Maybe.withDefault RemoteData.NotAsked
      , querySelectedSuggestion = Nothing
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
    | QueryInputDebounce (Debouncer.Messages.Msg (Msg a))
    | QueryInput String
    | QueryInputSuggestionsSubmit
    | QueryInputSuggestionsResponse (RemoteData.WebData (SearchResult a))
    | QueryInputSubmit
    | QueryResponse (RemoteData.WebData (SearchResult a))
    | ShowDetails String
    | SuggestionsMoveDown
    | SuggestionsMoveUp
    | SuggestionsSelect
    | SuggestionsClickSelect String
    | SuggestionsClose


update :
    String
    -> Browser.Navigation.Key
    -> String
    -> Options
    -> Json.Decode.Decoder a
    -> Msg a
    -> Model a
    -> ( Model a, Cmd (Msg a) )
update path navKey result_type options decodeResultItemSource msg model =
    let
        requestQuerySuggestionsTracker =
            "query-" ++ result_type ++ "-suggestions"
    in
    case msg of
        NoOp ->
            ( model
            , Cmd.none
            )

        SortChange sortId ->
            let
                sort = fromSortId sortId |> Maybe.withDefault Relevance
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

        QueryInputDebounce subMsg ->
            Debouncer.Messages.update
                (update path navKey result_type options decodeResultItemSource)
                { mapMsg = QueryInputDebounce
                , getDebouncer = .queryDebounce
                , setDebouncer = \debouncer m -> { m | queryDebounce = debouncer }
                }
                subMsg
                model

        QueryInput query ->
            update path
                navKey
                result_type
                options
                decodeResultItemSource
                (QueryInputDebounce (Debouncer.Messages.provideInput QueryInputSuggestionsSubmit))
                { model
                    | query = Just query
                    , querySuggest = RemoteData.Loading
                    , querySelectedSuggestion = Nothing
                }
                |> Tuple.mapSecond
                    (\cmd ->
                        if RemoteData.isLoading model.querySuggest then
                            Cmd.batch
                                [ cmd
                                , Http.cancel requestQuerySuggestionsTracker
                                ]

                        else
                            cmd
                    )

        QueryInputSuggestionsSubmit ->
            let
                body =
                    Http.jsonBody
                        (Json.Encode.object
                            [ ( "from", Json.Encode.int 0 )
                            , ( "size", Json.Encode.int 0 )
                            , ( "suggest"
                              , Json.Encode.object
                                    [ ( "query"
                                      , Json.Encode.object
                                            [ ( "text", Json.Encode.string (Maybe.withDefault "" model.query) )
                                            , ( "completion"
                                              , Json.Encode.object
                                                    [ ( "field", Json.Encode.string (result_type ++ "_suggestions") )
                                                    , ( "skip_duplicates", Json.Encode.bool True )
                                                    , ( "size", Json.Encode.int 1000 )
                                                    ]
                                              )
                                            ]
                                      )
                                    ]
                              )
                            ]
                        )
            in
            ( { model
                | querySuggest =
                    model.query
                        |> Maybe.map
                            (\selected ->
                                if String.endsWith "." selected then
                                    model.querySuggest

                                else
                                    RemoteData.NotAsked
                            )
                        |> Maybe.withDefault RemoteData.NotAsked
                , querySelectedSuggestion = Nothing
              }
            , makeRequest
                body
                ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ model.channel)
                decodeResultItemSource
                options
                QueryInputSuggestionsResponse
                (Just requestQuerySuggestionsTracker)
            )

        QueryInputSuggestionsResponse querySuggest ->
            ( { model
                | querySuggest = querySuggest
                , querySelectedSuggestion = Nothing
              }
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
                |> Browser.Navigation.pushUrl navKey
            )

        SuggestionsMoveDown ->
            ( { model
                | querySelectedSuggestion =
                    getMovedSuggestion
                        model.query
                        model.querySuggest
                        model.querySelectedSuggestion
                        (\x -> x + 1)
              }
            , scrollToSelected "dropdown-menu"
            )

        SuggestionsMoveUp ->
            ( { model
                | querySelectedSuggestion =
                    getMovedSuggestion
                        model.query
                        model.querySuggest
                        model.querySelectedSuggestion
                        (\x -> x - 1)
              }
            , scrollToSelected "dropdown-menu"
            )

        SuggestionsSelect ->
            case model.querySelectedSuggestion of
                Just selected ->
                    update path
                        navKey
                        result_type
                        options
                        decodeResultItemSource
                        (SuggestionsClickSelect selected)
                        model

                Nothing ->
                    ( model
                    , Task.attempt (\_ -> QueryInputSubmit) (Task.succeed ())
                    )

        SuggestionsClickSelect selected ->
            ( { model
                | querySuggest =
                    if String.endsWith "." selected then
                        model.querySuggest

                    else
                        RemoteData.NotAsked
                , querySelectedSuggestion = Nothing
                , query = Just selected
              }
            , Cmd.batch
                [ Task.attempt (\_ -> QueryInputSuggestionsSubmit) (Task.succeed ())
                , Task.attempt (\_ -> QueryInputSubmit) (Task.succeed ())
                ]
            )

        SuggestionsClose ->
            ( { model
                | querySuggest = RemoteData.NotAsked
                , querySelectedSuggestion = Nothing
              }
            , Cmd.none
            )


scrollToSelected :
    String
    -> Cmd (Msg a)
scrollToSelected id =
    let
        scroll y =
            Browser.Dom.setViewportOf id 0 y
                |> Task.onError (\_ -> Task.succeed ())
    in
    Task.sequence
        [ Browser.Dom.getElement (id ++ "-selected")
            |> Task.map (\x -> ( x.element.y, x.element.height ))
        , Browser.Dom.getElement id
            |> Task.map (\x -> ( x.element.y, x.element.height ))
        , Browser.Dom.getViewportOf id
            |> Task.map (\x -> ( x.viewport.y, x.viewport.height ))
        ]
        |> Task.andThen
            (\x ->
                case x of
                    ( elementY, elementHeight ) :: ( viewportY, viewportHeight ) :: ( viewportScrollTop, _ ) :: [] ->
                        let
                            scrollTop =
                                scroll (viewportScrollTop + (elementY - viewportY))

                            scrollBottom =
                                scroll (viewportScrollTop + (elementY - viewportY) + (elementHeight - viewportHeight))
                        in
                        if elementHeight > viewportHeight then
                            scrollTop

                        else if elementY < viewportY then
                            scrollTop

                        else if elementY + elementHeight > viewportY + viewportHeight then
                            scrollBottom

                        else
                            Task.succeed ()

                    _ ->
                        Task.succeed ()
            )
        |> Task.attempt (\_ -> NoOp)


getMovedSuggestion :
    Maybe String
    -> RemoteData.WebData (SearchResult a)
    -> Maybe String
    -> (Int -> Int)
    -> Maybe String
getMovedSuggestion query querySuggest querySelectedSuggestion moveIndex =
    let
        suggestions =
            getSuggestions query querySuggest
                |> List.filterMap .text

        getIndex key =
            suggestions
                |> List.indexedMap (\i a -> ( a, i ))
                |> Dict.fromList
                |> Dict.get key
                |> Maybe.map moveIndex
                |> Maybe.map
                    (\x ->
                        if x < 0 then
                            x + List.length suggestions

                        else
                            x
                    )

        getKey index =
            suggestions
                |> Array.fromList
                |> Array.get index
    in
    querySelectedSuggestion
        |> Maybe.andThen getIndex
        |> Maybe.withDefault 0
        |> getKey


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
                  [ [ ( field, Json.Encode.string "asc")
                    ]
                  ]
          AlphabeticallyDesc ->
              Json.Encode.list Json.Encode.object
                  [ [ ( field, Json.Encode.string "desc")
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
        AlphabeticallyAsc -> "Alphabetically Ascending"
        AlphabeticallyDesc -> "Alphabetically Descending"
        Relevance -> "Relevance"


toSortId : Sort -> String
toSortId sort =
    case sort of 
        AlphabeticallyAsc -> "alpha_asc"
        AlphabeticallyDesc -> "alpha_desc"
        Relevance -> "relevance"


fromSortId : String -> Maybe Sort
fromSortId id = 
    case id of
      "alpha_asc" -> Just AlphabeticallyAsc
      "alpha_desc" -> Just AlphabeticallyDesc
      "relevance" -> Just Relevance
      _ -> Nothing


getSuggestions :
    Maybe String
    -> RemoteData.WebData (SearchResult a)
    -> List (ResultItem a)
getSuggestions query querySuggest =
    let
        maybeList f x =
            x
                |> Maybe.map f
                |> Maybe.withDefault []
    in
    case querySuggest of
        RemoteData.Success result ->
            let
                suggestions =
                    result.suggest
                        |> maybeList (\x -> x.query |> maybeList (List.map .options))
                        |> List.concat
                        |> List.filter
                            (\x ->
                                if String.endsWith "." (Maybe.withDefault "" query) then
                                    x.text /= query

                                else
                                    True
                            )

                firstItemText items =
                    items
                        |> List.head
                        |> Maybe.andThen .text
            in
            if List.length suggestions == 1 && firstItemText suggestions == query then
                []

            else
                suggestions

        _ ->
            []


view :
    String
    -> String
    -> Model a
    -> (String -> Maybe String -> SearchResult a -> Html b)
    -> (Msg a -> b)
    -> Html b
view path title model viewSuccess outMsg =
    let
        suggestions =
            getSuggestions model.query model.querySuggest

        viewSuggestion x =
            li
                []
                [ a
                    ([ href "#" ]
                        |> List.append
                            (x.text
                                |> Maybe.map (\text -> [ onClick <| outMsg (SuggestionsClickSelect text) ])
                                |> Maybe.withDefault []
                            )
                        |> List.append
                            (if x.text == model.querySelectedSuggestion then
                                [ id "dropdown-menu-selected" ]

                             else
                                []
                            )
                    )
                    [ text <| Maybe.withDefault "" x.text ]
                ]
    in
    div
        [ classList
            [ ( "search-page", True )
            , ( "with-suggestions", RemoteData.isSuccess model.querySuggest && List.length suggestions > 0 )
            , ( "with-suggestions-loading"
              , (model.query /= Nothing)
                    && (model.query /= Just "")
                    && not (RemoteData.isSuccess model.querySuggest || RemoteData.isNotAsked model.querySuggest)
              )
            ]
        ]
        [ h1 [ class "page-header" ] [ text title ]
        , div
            [ class "search-backdrop"
            , onClick <| outMsg SuggestionsClose
            ]
            []
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
                        ([ type_ "text"
                         , id "search-query-input"
                         , autocomplete False
                         , autofocus True
                         , placeholder <| "Search for " ++ path
                         , onInput (\x -> outMsg (QueryInput x))
                         , value <| Maybe.withDefault "" model.query
                         ]
                            |> List.append
                                (if RemoteData.isSuccess model.querySuggest && List.length suggestions > 0 then
                                    [ Keyboard.Events.custom Keyboard.Events.Keydown
                                        { preventDefault = True
                                        , stopPropagation = True
                                        }
                                        ([ ( Keyboard.ArrowDown, SuggestionsMoveDown )
                                         , ( Keyboard.ArrowUp, SuggestionsMoveUp )
                                         , ( Keyboard.Tab, SuggestionsMoveDown )
                                         , ( Keyboard.Enter, SuggestionsSelect )
                                         , ( Keyboard.Escape, SuggestionsClose )
                                         ]
                                            |> List.map (\( k, m ) -> ( k, outMsg m ))
                                        )
                                    ]

                                 else if RemoteData.isNotAsked model.querySuggest then
                                    [ Keyboard.Events.custom Keyboard.Events.Keydown
                                        { preventDefault = True
                                        , stopPropagation = True
                                        }
                                        ([ ( Keyboard.ArrowDown, QueryInputSuggestionsSubmit )
                                         , ( Keyboard.ArrowUp, QueryInputSuggestionsSubmit )
                                         ]
                                            |> List.map (\( k, m ) -> ( k, outMsg m ))
                                        )
                                    ]

                                 else
                                    []
                                )
                        )
                        []
                    , div [ class "loader" ] []
                    , div [ class "btn-group" ]
                        [ button [ class "btn" ] [ text "Search" ]
                        ]
                    ]
                , ul
                    [ id "dropdown-menu", class "dropdown-menu" ]
                    (if RemoteData.isSuccess model.querySuggest && List.length suggestions > 0 then
                        List.map viewSuggestion suggestions

                     else
                        []
                    )
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
                                [ label [ class "control-label"] [ text "Sort by:" ]
                                , div 
                                    [ class "controls"]
                                    [ select
                                          [ onInput (\x -> outMsg (SortChange x))
                                          ]
                                          (List.map
                                              (\sort ->
                                                  option 
                                                      [ selected (model.sort == sort)
                                                      , value (toSortId sort)
                                                      ]
                                                      [ text <| toSortTitle sort]
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


filter_by_query : String -> String -> List (List ( String, Json.Encode.Value ))
filter_by_query field queryRaw =
    let
        query =
            queryRaw
                |> String.trim
    in
    query
        |> String.replace "." " "
        |> String.words
        |> List.indexedMap
            (\i query_word ->
                let
                    isLast =
                        List.length (String.words query) == i + 1
                in
                [ if isLast then
                    ( "bool"
                    , Json.Encode.object
                        [ ( "should"
                          , Json.Encode.list Json.Encode.object
                                [ [ ( "match"
                                    , Json.Encode.object
                                        [ ( field
                                          , Json.Encode.object
                                                [ ( "query", Json.Encode.string query_word )
                                                , ( "fuzziness", Json.Encode.string "1" )
                                                , ( "_name", Json.Encode.string <| "filter_queries_" ++ String.fromInt (i + 1) ++ "_should_match" )
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
                        ]
                    )

                  else
                    ( "match_bool_prefix"
                    , Json.Encode.object
                        [ ( field
                          , Json.Encode.object
                                [ ( "query", Json.Encode.string query_word )
                                , ( "_name"
                                  , Json.Encode.string <| "filter_queries_" ++ String.fromInt (i + 1) ++ "_prefix"
                                  )
                                ]
                          )
                        ]
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
    -> String
    -> List (List ( String, Json.Encode.Value ))
    -> Http.Body
makeRequestBody query from sizeRaw sort type_ sort_field query_field should_queries =
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
                                    (List.append
                                        [ [ filter_by_type type_ ] ]
                                        (filter_by_query query_field query)
                                    )
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
    Json.Decode.map2 SearchResult
        (Json.Decode.field "hits" (decodeResultHits decodeResultItemSource))
        (Json.Decode.maybe (Json.Decode.field "suggest" (decodeSuggest decodeResultItemSource)))


decodeSuggest : Json.Decode.Decoder a -> Json.Decode.Decoder (SearchSuggest a)
decodeSuggest decodeResultItemSource =
    Json.Decode.map SearchSuggest
        (Json.Decode.maybe (Json.Decode.field "query" (Json.Decode.list (decodeSuggestQuery decodeResultItemSource))))


decodeSuggestQuery : Json.Decode.Decoder a -> Json.Decode.Decoder (SearchSuggestQuery a)
decodeSuggestQuery decodeResultItemSource =
    Json.Decode.map4 SearchSuggestQuery
        (Json.Decode.field "text" Json.Decode.string)
        (Json.Decode.field "offset" Json.Decode.int)
        (Json.Decode.field "length" Json.Decode.int)
        (Json.Decode.field "options" (Json.Decode.list (decodeResultItem decodeResultItemSource)))


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
