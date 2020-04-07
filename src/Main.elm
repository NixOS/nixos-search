module Main exposing (main)

import Base64
import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav exposing (Key)
import Html
    exposing
        ( Html
        , button
        , div
        , h1
        , header
        , input
        , li
        , pre
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , type_
        , value
        )
import Html.Events
    exposing
        ( onClick
        , onInput
        )
import Http
import Json.Decode as D
import Json.Decode.Pipeline as DP
import Json.Encode as E
import RemoteData as R
import Url exposing (Url)
import Url.Parser as UrlParser
    exposing
        ( (<?>)
        , Parser
        )
import Url.Parser.Query as UrlParserQuery



-- ---------------------------
-- MODEL
-- ---------------------------


type alias Flags =
    { elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    }


type alias Model =
    { key : Key
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    , page : Page
    }


type alias SearchModel =
    { query : String
    , result : R.WebData SearchResult
    }


type Page
    = SearchPage SearchModel



--| PackagePage SearchModel
--| MaintainerPage SearchModel


type alias SearchResult =
    { hits : SearchResultHits
    }


type alias SearchResultHits =
    { total : SearchResultHitsTotal
    , max_score : Maybe Float
    , hits : List SearchResultItem
    }


type alias SearchResultHitsTotal =
    { value : Int
    , relation : String -- TODO: this should probably be Enum
    }


type alias SearchResultItem =
    { index : String
    , id : String
    , score : Float
    , source : SearchResultItemSource
    }


type SearchResultItemSource
    = Package SearchResultPackage
    | Option SearchResultOption


type alias SearchResultPackage =
    { attr_name : String
    , name : String
    , version : String
    , description : Maybe String
    , longDescription : Maybe String
    , licenses : List SearchResultPackageLicense
    , maintainers : List SearchResultPackageMaintainer
    , position : Maybe String
    , homepage : Maybe String
    }


type alias SearchResultOption =
    { option_name : String
    , description : String
    , type_ : String
    , default : String
    , example : String
    , source : String
    }


type alias SearchResultPackageLicense =
    { fullName : String
    , url : Maybe String
    }


type alias SearchResultPackageMaintainer =
    { name : String
    , email : String
    , github : String
    }


emptySearch : Page
emptySearch =
    SearchPage { query = "", result = R.NotAsked }


init : Flags -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    ( { key = key
      , elasticsearchUrl = flags.elasticsearchUrl
      , elasticsearchUsername = flags.elasticsearchUsername
      , elasticsearchPassword = flags.elasticsearchPassword
      , page = UrlParser.parse urlParser url |> Maybe.withDefault emptySearch
      }
    , Cmd.none
    )



-- ---------------------------
-- URL Parsing and Routing
-- ---------------------------


handleUrlRequest : Key -> UrlRequest -> Cmd msg
handleUrlRequest key urlRequest =
    case urlRequest of
        Internal url ->
            Nav.pushUrl key (Url.toString url)

        External url ->
            Nav.load url


urlParser : Parser (Page -> msg) msg
urlParser =
    UrlParser.oneOf
        [ UrlParser.map
            (\q ->
                SearchPage
                    { query = q |> Maybe.withDefault ""
                    , result = R.NotAsked
                    }
            )
            (UrlParser.s "search" <?> UrlParserQuery.string "query")
        ]



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg
    = OnUrlRequest UrlRequest
    | OnUrlChange Url
    | SearchPageInput String
    | SearchQuerySubmit
    | SearchQueryResponse (R.WebData SearchResult)


decodeResult : D.Decoder SearchResult
decodeResult =
    D.map SearchResult
        (D.field "hits" decodeResultHits)


decodeResultHits : D.Decoder SearchResultHits
decodeResultHits =
    D.map3 SearchResultHits
        (D.field "total" decodeResultHitsTotal)
        (D.field "max_score" (D.nullable D.float))
        (D.field "hits" (D.list decodeResultItem))


decodeResultHitsTotal : D.Decoder SearchResultHitsTotal
decodeResultHitsTotal =
    D.map2 SearchResultHitsTotal
        (D.field "value" D.int)
        (D.field "relation" D.string)


decodeResultItem : D.Decoder SearchResultItem
decodeResultItem =
    D.map4 SearchResultItem
        (D.field "_index" D.string)
        (D.field "_id" D.string)
        (D.field "_score" D.float)
        (D.field "_source" decodeResultItemSource)


decodeResultItemSource : D.Decoder SearchResultItemSource
decodeResultItemSource =
    D.oneOf
        [ D.map Package decodeResultPackage

        --, D.map Option decodeResultOption
        ]


decodeResultPackage : D.Decoder SearchResultPackage
decodeResultPackage =
    D.succeed SearchResultPackage
        |> DP.required "attr_name" D.string
        |> DP.required "name" D.string
        |> DP.required "version" D.string
        |> DP.required "description" (D.nullable D.string)
        |> DP.required "longDescription" (D.nullable D.string)
        |> DP.required "license" (D.list decodeResultPackageLicense)
        |> DP.required "maintainers" (D.list decodeResultPackageMaintainer)
        |> DP.required "position" (D.nullable D.string)
        |> DP.required "homepage" (D.nullable D.string)


decodeResultPackageLicense : D.Decoder SearchResultPackageLicense
decodeResultPackageLicense =
    D.map2 SearchResultPackageLicense
        (D.field "fullName" D.string)
        (D.field "url" (D.nullable D.string))


decodeResultPackageMaintainer : D.Decoder SearchResultPackageMaintainer
decodeResultPackageMaintainer =
    D.map3 SearchResultPackageMaintainer
        (D.field "name" D.string)
        (D.field "email" D.string)
        (D.field "github" D.string)


decodeResultOption : D.Decoder SearchResultOption
decodeResultOption =
    D.map6 SearchResultOption
        (D.field "option_name" D.string)
        (D.field "description" D.string)
        (D.field "type" D.string)
        (D.field "default" D.string)
        (D.field "example" D.string)
        (D.field "source" D.string)


initPage : Model -> Cmd Msg
initPage model =
    case model.page of
        SearchPage searchModel ->
            if searchModel.query == "" then
                Cmd.none

            else
                Http.riskyRequest
                    { method = "POST"
                    , headers =
                        [ Http.header "Authorization" ("Basic " ++ Base64.encode (model.elasticsearchUsername ++ ":" ++ model.elasticsearchPassword))
                        ]
                    , url = model.elasticsearchUrl ++ "/nixos-unstable-packages/_search"
                    , body =
                        Http.jsonBody <|
                            E.object
                                [ ( "query"
                                  , E.object
                                        [ ( "match"
                                          , E.object
                                                [ ( "name"
                                                  , E.object
                                                        [ ( "query", E.string searchModel.query )
                                                        , ( "fuzziness", E.int 1 )
                                                        ]
                                                  )
                                                ]
                                          )
                                        ]
                                  )
                                ]
                    , expect = Http.expectJson (R.fromResult >> SearchQueryResponse) decodeResult
                    , timeout = Nothing
                    , tracker = Nothing
                    }


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        OnUrlRequest urlRequest ->
            ( model, handleUrlRequest model.key urlRequest )

        OnUrlChange url ->
            let
                newModel =
                    { model | page = UrlParser.parse urlParser url |> Maybe.withDefault model.page }

                newPage =
                    case newModel.page of
                        SearchPage searchModel ->
                            SearchPage
                                { searchModel
                                    | result =
                                        if searchModel.query == "" then
                                            R.NotAsked

                                        else
                                            R.Loading
                                }

                newNewModel =
                    { newModel | page = newPage }
            in
            ( newNewModel
            , initPage newNewModel
            )

        SearchPageInput query ->
            ( { model
                | page =
                    case model.page of
                        SearchPage searchModel ->
                            SearchPage { searchModel | query = query }
              }
            , Cmd.none
            )

        SearchQuerySubmit ->
            case model.page of
                SearchPage searchModel ->
                    ( model
                    , Nav.pushUrl model.key <| "/search?query=" ++ searchModel.query
                    )

        SearchQueryResponse result ->
            case model.page of
                SearchPage searchModel ->
                    let
                        newPage =
                            SearchPage { searchModel | result = result }
                    in
                    ( { model | page = newPage }
                    , Cmd.none
                    )



-- ---------------------------
-- VIEW
-- ---------------------------


view : Model -> Html Msg
view model =
    div [ class "container" ]
        [ header []
            [ h1 [] [ text "NixOS Search" ]
            ]
        , case model.page of
            SearchPage searchModel ->
                searchPage searchModel
        ]


searchPage : SearchModel -> Html Msg
searchPage model =
    div []
        [ div []
            [ input
                [ type_ "text"
                , onInput SearchPageInput
                , value model.query
                ]
                []
            , button [ onClick SearchQuerySubmit ] [ text "Search" ]
            ]
        , case model.result of
            R.NotAsked ->
                div [] [ text "NotAsked" ]

            R.Loading ->
                div [] [ text "Loading" ]

            R.Success result ->
                ul [] (searchPageResult result.hits)

            R.Failure error ->
                div [] [ text "Error!", pre [] [ text (Debug.toString error) ] ]
        ]


searchPageResult : SearchResultHits -> List (Html Msg)
searchPageResult result =
    List.map searchPageResultItem result.hits


searchPageResultItem : SearchResultItem -> Html Msg
searchPageResultItem item =
    -- case item.source of
    --     Package package ->
    --         li [] [ text package.attr_name ]
    --     Option option ->
    --         li [] [ text option.option_name ]
    li [] [ text <| Debug.toString item ]



-- ---------------------------
-- MAIN
-- ---------------------------


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , view =
            \m ->
                { title = "NixOS Search"
                , body = [ view m ]
                }
        , subscriptions = \_ -> Sub.none
        , onUrlRequest = OnUrlRequest
        , onUrlChange = OnUrlChange
        }
