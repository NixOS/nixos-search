module Search exposing
    ( Model
    , Msg(..)
    , Options
    , Result
    , ResultItem
    , channelDetailsFromId
    , decodeResult
    , init
    , makeRequest
    , update
    , view
    )

import Base64
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
        , li
        , option
        , p
        , select
        , span
        , strong
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , classList
        , href
        , type_
        , value
        )
import Html.Events
    exposing
        ( custom
        , onClick
        , onInput
        , onSubmit
        , preventDefaultOn
        )
import Http
import Json.Decode
import Json.Encode
import RemoteData
import Url.Builder


type alias Model a =
    { channel : String
    , query : Maybe String
    , result : RemoteData.WebData (Result a)
    , showDetailsFor : Maybe String
    , from : Int
    , size : Int
    }


type alias Result a =
    { hits : ResultHits a
    }


type alias ResultHits a =
    { total : ResultHitsTotal
    , max_score : Maybe Float
    , hits : List (ResultItem a)
    }


type alias ResultHitsTotal =
    { value : Int
    , relation : String -- TODO: this should probably be Enum
    }


type alias ResultItem a =
    { index : String
    , id : String
    , score : Float
    , source : a
    }


init :
    Maybe String
    -> Maybe String
    -> Maybe String
    -> Maybe Int
    -> Maybe Int
    -> ( Model a, Cmd msg )
init channel query showDetailsFor from size =
    ( { channel = Maybe.withDefault "unstable" channel
      , query = query
      , result = RemoteData.NotAsked
      , showDetailsFor = showDetailsFor
      , from = Maybe.withDefault 0 from
      , size = Maybe.withDefault 15 size
      }
    , Cmd.none
    )



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg a
    = NoOp
    | ChannelChange String
    | QueryInput String
    | QuerySubmit
    | QueryResponse (RemoteData.WebData (Result a))
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

        ChannelChange channel ->
            ( { model | channel = channel }
            , Cmd.none
            )

        QueryInput query ->
            ( { model | query = Just query }
            , Cmd.none
            )

        QuerySubmit ->
            ( model
            , createUrl
                path
                model.channel
                model.query
                model.showDetailsFor
                0
                model.size
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
                (if model.showDetailsFor == Just selected then
                    Nothing

                 else
                    Just selected
                )
                model.from
                model.size
                |> Browser.Navigation.pushUrl navKey
            )


createUrl :
    String
    -> String
    -> Maybe String
    -> Maybe String
    -> Int
    -> Int
    -> String
createUrl path channel query showDetailsFor from size =
    [ Url.Builder.int "from" from
    , Url.Builder.int "size" size
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
            (showDetailsFor
                |> Maybe.map
                    (\x ->
                        [ Url.Builder.string "showDetailsFor" x
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
    }


channelDetails : Channel -> ChannelDetails
channelDetails channel =
    case channel of
        Unstable ->
            ChannelDetails "unstable" "unstable" "nixos/trunk-combined"

        Release_19_09 ->
            ChannelDetails "19.09" "19.09" "nixos/release-19.09"

        Release_20_03 ->
            ChannelDetails "20.03" "20.03" "nixos/release-20.03"


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
    [ "unstable"
    , "20.03"
    , "19.09"
    ]


view :
    String
    -> String
    -> Model a
    -> (String -> Maybe String -> Result a -> Html b)
    -> (Msg a -> b)
    -> Html b
view path title model viewSuccess outMsg =
    div [ class "search-page" ]
        [ h1 [ class "page-header" ] [ text title ]
        , div [ class "search-input" ]
            [ form [ onSubmit (outMsg QuerySubmit) ]
                [ div [ class "input-append" ]
                    [ input
                        [ type_ "text"
                        , onInput (\x -> outMsg (QueryInput x))
                        , value <| Maybe.withDefault "" model.query
                        ]
                        []
                    , div [ class "btn-group" ]
                        [ button [ class "btn" ] [ text "Search" ]
                        ]
                    ]
                , span []
                    [ strong []
                        [ text " in " ]
                    , select
                        [ onInput (\x -> outMsg (ChannelChange x)) ]
                        (List.filterMap
                            (\channel_id ->
                                channelDetailsFromId channel_id
                                    |> Maybe.map
                                        (\channel ->
                                            option
                                                [ value channel.id
                                                ]
                                                [ text channel.title ]
                                        )
                            )
                            channels
                        )
                    , strong []
                        [ text " channel." ]
                    ]
                ]
            ]
        , case model.result of
            RemoteData.NotAsked ->
                div [] [ text "" ]

            RemoteData.Loading ->
                div [] [ text "Loading" ]

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
                                        ++ String.fromInt result.hits.total.value
                                        ++ "."
                                    )
                                ]
                            ]
                        , viewPager outMsg model result path
                        , viewSuccess model.channel model.showDetailsFor result
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
                                ( "Network Error!", "Please check your network connection." )

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
    -> Result a
    -> String
    -> Html b
viewPager outMsg model result path =
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
                            model.showDetailsFor
                            0
                            model.size
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
                            model.showDetailsFor
                            (model.from - model.size)
                            model.size
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
                            model.showDetailsFor
                            (model.from + model.size)
                            model.size
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
                        createUrl
                            path
                            model.channel
                            model.query
                            model.showDetailsFor
                            ((result.hits.total.value // model.size) * model.size)
                            model.size
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


makeRequest :
    Http.Body
    -> String
    -> Json.Decode.Decoder a
    -> Options
    -> String
    -> Int
    -> Int
    -> Cmd (Msg a)
makeRequest body index decodeResultItemSource options query from size =
    Http.riskyRequest
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = body
        , expect =
            Http.expectJson
                (RemoteData.fromResult >> QueryResponse)
                (decodeResult decodeResultItemSource)
        , timeout = Nothing
        , tracker = Nothing
        }



-- JSON


decodeResult :
    Json.Decode.Decoder a
    -> Json.Decode.Decoder (Result a)
decodeResult decodeResultItemSource =
    Json.Decode.map Result
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
    Json.Decode.map4 ResultItem
        (Json.Decode.field "_index" Json.Decode.string)
        (Json.Decode.field "_id" Json.Decode.string)
        (Json.Decode.field "_score" Json.Decode.float)
        (Json.Decode.field "_source" decodeResultItemSource)
