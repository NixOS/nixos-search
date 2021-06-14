module Page.Flakes exposing (Model, Msg, init, update, view)

import Html exposing (Html, div, text)
import Route
import Search
import Browser.Navigation



-- MODEL


type alias Model =
    Search.Model ResultItemSource ResultAggregations

type alias ResultItemSource =
    { name : String
    , description : Maybe String
    , type_ : Maybe String
    , default : Maybe String
    , example : Maybe String
    , source : Maybe String
    }


type alias ResultAggregations =
    { all : AggregationsAll
    }


type alias AggregationsAll =
    { doc_count : Int
    }

init : Route.SearchArgs -> Maybe Model -> ( Model, Cmd Msg )
init searchArgs model =
    let
        ( newModel, newCmd ) =
            Search.init searchArgs model
    in
    ( newModel
    , Cmd.map SearchMsg newCmd
    )


-- UPDATE


type Msg
    = SearchMsg (Search.Msg ResultItemSource ResultAggregations)

update :
    Browser.Navigation.Key
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update navKey msg model =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    Search.update
                        Route.Options
                        navKey
                        subMsg
                        model
            in
            ( newModel, Cmd.map SearchMsg newCmd )





-- VIEW


view : Model -> Html Msg
view _ =
    div [] [ text "Home" ]
