module ElasticSearch exposing
    ( Model
    , Msg(..)
    , Options
    , Result
    , ResultItem
    , decodeResult
    , init
    , makeRequest
    , showLoadingOnQuery
    , update
    , view
    )

import Base64
import Browser.Navigation
import Html
    exposing
        ( Html
        , button
        , div
        , form
        , h1
        , input
        , text
        )
import Html.Attributes
    exposing
        ( class
        , type_
        , value
        )
import Html.Events
    exposing
        ( onInput
        , onSubmit
        )
import Http
import Json.Decode
import Json.Encode
import RemoteData
import Url.Builder


type alias Model a =
    { query : Maybe String
    , result : RemoteData.WebData (Result a)
    , showDetailsFor : Maybe String
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
    -> ( Model a, Cmd msg )
init query showDetailsFor =
    ( { query = query
      , result = RemoteData.NotAsked
      , showDetailsFor = showDetailsFor
      }
    , Cmd.none
    )



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg a
    = QueryInput String
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
        QueryInput query ->
            ( { model | query = Just query }
            , Cmd.none
            )

        QuerySubmit ->
            ( model
            , createUrl path model.query model.showDetailsFor
                |> Browser.Navigation.pushUrl navKey
            )

        QueryResponse result ->
            ( { model | result = result }
            , Cmd.none
            )

        ShowDetails selected ->
            ( model
            , createUrl path
                model.query
                (if model.showDetailsFor == Just selected then
                    Nothing

                 else
                    Just selected
                )
                |> Browser.Navigation.pushUrl navKey
            )


showLoadingOnQuery : Model a -> Model a
showLoadingOnQuery model =
    -- TODO: use this
    { model
        | result =
            case model.query of
                Just query ->
                    RemoteData.Loading

                Nothing ->
                    RemoteData.NotAsked
    }


createUrl : String -> Maybe String -> Maybe String -> String
createUrl path query showDetailsFor =
    []
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


view :
    { title : String }
    -> Model a
    -> (Maybe String -> Result a -> Html b)
    -> (Msg a -> b)
    -> Html b
view options model viewSuccess outMsg =
    div [ class "search-page" ]
        [ h1 [ class "page-header" ] [ text options.title ]
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

                        --TODO: and option to select the right channel+version+evaluation
                        --, button [ class "btn" ] [ text "Loading ..." ]
                        --, div [ class "popover bottom" ]
                        --    [ div [ class "arrow" ] []
                        --    , div [ class "popover-title" ] [ text "Select options" ]
                        --    , div [ class "popover-content" ]
                        --        [ p [] [ text "Sed posuere consectetur est at lobortis. Aenean eu leo quam. Pellentesque ornare sem lacinia quam venenatis vestibulum." ] ]
                        --    ]
                        ]
                    ]
                ]
            ]
        , case model.result of
            RemoteData.NotAsked ->
                div [] [ text "NotAsked" ]

            RemoteData.Loading ->
                div [] [ text "Loading" ]

            RemoteData.Success result ->
                viewSuccess model.showDetailsFor result

            RemoteData.Failure error ->
                div []
                    [ text "Error!"

                    --, pre [] [ text (Debug.toString error) ]
                    ]
        ]



-- API


type alias Options =
    { url : String
    , username : String
    , password : String
    }


makeRequestBody : String -> String -> Http.Body
makeRequestBody field query =
    let
        stringIn name value =
            [ ( name, Json.Encode.string value ) ]

        objectIn name object =
            [ ( name, Json.Encode.object object ) ]
    in
    -- Prefix Query
    -- {
    --     "query": {
    --         "prefix": {
    --             "user": {
    --                 "value": ""
    --             }
    --         }
    --     }
    -- }
    --query
    --    |> stringIn "value"
    --    |> objectIn field
    --    |> objectIn "prefix"
    --    |> objectIn "query"
    --    |> Json.Encode.object
    --    |> Http.jsonBody
    --
    -- Wildcard Query
    -- {
    --     "query": {
    --         "wildcard": {
    --             "<field>": {
    --                 "value": "*<value>*",
    --             }
    --         }
    --     }
    -- }
    ("*" ++ query ++ "*")
        |> stringIn "value"
        |> objectIn field
        |> objectIn "wildcard"
        |> objectIn "query"
        |> Json.Encode.object
        |> Http.jsonBody


makeRequest :
    String
    -> String
    -> Json.Decode.Decoder a
    -> Options
    -> String
    -> Cmd (Msg a)
makeRequest field index decodeResultItemSource options query =
    Http.riskyRequest
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = makeRequestBody field query
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
