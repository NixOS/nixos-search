port module Main exposing (main)

import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav exposing (Key)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick)
import Http exposing (Error(..))
import Json.Decode as Decode
import Url exposing (Url)
import Url.Parser as UrlParser exposing ((</>), Parser)



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


init : Int -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    ( { key = key, page = UrlParser.parse urlParser url |> Maybe.withDefault (Counter 0) }, Cmd.none )


type Page
    = Counter Int
    | Server String



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
        [ UrlParser.map Counter <| UrlParser.s "counter" </> UrlParser.int
        , UrlParser.map Server <| UrlParser.s "server" </> UrlParser.string
        , UrlParser.map (Server "") <| UrlParser.s "server"
        ]



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg
    = OnUrlRequest UrlRequest
    | OnUrlChange Url
    | Inc
    | TestServer
    | OnServerResponse (Result Http.Error String)


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        OnUrlRequest urlRequest ->
            ( model, handleUrlRequest model.key urlRequest )

        OnUrlChange url ->
            ( { model | page = UrlParser.parse urlParser url |> Maybe.withDefault model.page }, Cmd.none )

        Inc ->
            case model.page of
                Counter x ->
                    let
                        xx =
                            x + 1
                    in
                    ( { model | page = Counter xx }
                    , Nav.pushUrl model.key <| "/counter/" ++ String.fromInt xx
                    )

                _ ->
                    ( model, Cmd.none )

        TestServer ->
            let
                expect =
                    Http.expectJson OnServerResponse (Decode.field "result" Decode.string)
            in
            ( model
            , Http.get { url = "/test", expect = expect }
            )

        OnServerResponse res ->
            case res of
                Ok serverMessage ->
                    ( { model | page = Server serverMessage }, Cmd.none )

                Err err ->
                    ( { model | page = Server <| "Error: " ++ httpErrorToString err }, Cmd.none )


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        BadUrl _ ->
            "BadUrl"

        Timeout ->
            "Timeout"

        NetworkError ->
            "NetworkError"

        BadStatus _ ->
            "BadStatus"

        BadBody s ->
            "BadBody: " ++ s



-- ---------------------------
-- VIEW
-- ---------------------------


view : Model -> Html Msg
view model =
    div [ class "container" ]
        [ header []
            [ img [ src "/images/logo.png" ] []
            , h1 [] [ text "Elm 0.19 Webpack Starter, with hot-reloading" ]
            ]
        , case model.page of
            Counter counter ->
                counterPage counter

            Server serverMessage ->
                serverPage serverMessage
        , p []
            [ text "And now don't forget to add a star to the Github repo "
            , a [ href "https://github.com/simonh1000/elm-webpack-starter" ] [ text "elm-webpack-starter" ]
            ]
        ]


counterPage counter =
    div [ class "pure-u-1-3" ]
        [ a [ href "/server/" ] [ text "Switch to server" ]
        , p [] [ text "Click on the button below to increment the state." ]
        , button
            [ class "pure-button pure-button-primary"
            , onClick Inc
            ]
            [ text "+ 1" ]
        , text <| String.fromInt counter
        , p [] [ text "Then make a change to the source code and see how the state is retained after you recompile." ]
        ]


serverPage serverMessage =
    div [ class "pure-u-1-3" ]
        [ a [ href "/counter/1" ] [ text "Switch to counter" ]
        , p [] [ text "Test the dev server" ]
        , button
            [ class "pure-button pure-button-primary"
            , onClick TestServer
            ]
            [ text "ping dev server" ]
        , text serverMessage
        ]



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
                { title = "Elm 0.19 starter"
                , body = [ view m ]
                }
        , subscriptions = \_ -> Sub.none
        , onUrlRequest = OnUrlRequest
        , onUrlChange = OnUrlChange
        }
