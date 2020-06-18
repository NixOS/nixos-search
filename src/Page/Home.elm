module Page.Home exposing (Model, Msg, init, update, view)

import Html exposing (Html, div, text)



-- MODEL


type alias Model =
    ()


init : ( Model, Cmd Msg )
init =
    ( (), Cmd.none )



-- UPDATE


type Msg
    = NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div [] [ text "Home" ]
