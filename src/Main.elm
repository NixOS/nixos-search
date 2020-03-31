port module Main exposing (main)

import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav exposing (Key)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput)
import Http exposing (Error(..))
import Json.Decode as Decode
import Url exposing (Url)
import Url.Parser as UrlParser exposing ((</>), (<?>), Parser)
import Url.Parser.Query as UrlParserQuery



-- ---------------------------
-- PORTS
-- ---------------------------


port toJs : String -> Cmd msg



-- ---------------------------
-- MODEL
-- ---------------------------


type alias Model =
    { key : Key
    , page : Page
    }


type alias SearchModel =
    { query : String
    , results : List String
    }


type Page
    = Search SearchModel


emptySearch =
    Search { query = "", results = [] }


init : Int -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    ( { key = key
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
                Search
                    { query = q |> Maybe.withDefault ""
                    , results = []
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


initPage : Page -> Cmd Msg
initPage page =
    case page of
        Search model ->
            Cmd.none


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        OnUrlRequest urlRequest ->
            ( model, handleUrlRequest model.key urlRequest )

        OnUrlChange url ->
            let
                newModel =
                    { model | page = UrlParser.parse urlParser url |> Maybe.withDefault model.page }
            in
            ( { newModel
                | page =
                    case newModel.page of
                        Search searchModel ->
                            Search
                                { searchModel
                                    | results =
                                        if searchModel.query == "" then
                                            []

                                        else
                                            [ "result1" ]
                                }
              }
            , initPage model.page
            )

        SearchPageInput query ->
            ( { model
                | page =
                    case model.page of
                        Search searchModel ->
                            Search { searchModel | query = query }
              }
            , Cmd.none
            )

        SearchQuerySubmit ->
            case model.page of
                Search searchModel ->
                    ( model
                    , Nav.pushUrl model.key <| "/search?query=" ++ searchModel.query
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
            Search searchModel ->
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
        , ul [] (List.map searchPageResult model.results)
        ]


searchPageResult : String -> Html Msg
searchPageResult item =
    li [] [ text item ]



-- ---------------------------
-- MAIN
-- ---------------------------


main : Program Int Model Msg
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
