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
    case msg of
        NoOp ->
            ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view _ =
    div [] [ text "Home" ]
