module Page.Options exposing
    ( Model
    , Msg
    , decodeResultItemSource
    , init
    , makeRequest
    , update
    , view
    )

import Browser.Navigation
import ElasticSearch
import Html
    exposing
        ( Html
        , div
        , table
        , tbody
        , td
        , text
        , th
        , thead
        , tr
        )
import Html.Attributes
    exposing
        ( class
        , colspan
        )
import Html.Events
    exposing
        ( onClick
        )
import Json.Decode



-- MODEL


type alias Model =
    ElasticSearch.Model ResultItemSource


type alias ResultItemSource =
    { option_name : String
    , description : String
    , type_ : String
    , default : String
    , example : String
    , source : String
    }


init :
    Maybe String
    -> Maybe String
    -> ( Model, Cmd Msg )
init =
    ElasticSearch.init



-- UPDATE


type Msg
    = SearchMsg (ElasticSearch.Msg ResultItemSource)


update : Browser.Navigation.Key -> Msg -> Model -> ( Model, Cmd Msg )
update navKey msg model =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    ElasticSearch.update "options" navKey subMsg model
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view : Model -> Html Msg
view model =
    ElasticSearch.view
        { title = "Search NixOS options" }
        model
        viewSuccess
        SearchMsg


viewSuccess :
    Maybe String
    -> ElasticSearch.Result ResultItemSource
    -> Html Msg
viewSuccess showDetailsFor result =
    div [ class "search-result" ]
        [ table [ class "table table-hover" ]
            [ thead []
                [ tr []
                    [ th [] [ text "Option name" ]
                    ]
                ]
            , tbody
                []
                (List.concatMap
                    (viewResultItem showDetailsFor)
                    result.hits.hits
                )
            ]
        ]


viewResultItem :
    Maybe String
    -> ElasticSearch.ResultItem ResultItemSource
    -> List (Html Msg)
viewResultItem showDetailsFor item =
    let
        packageDetails =
            if Just item.id == showDetailsFor then
                [ td [ colspan 1 ]
                    [ text "This are details!" ]
                ]

            else
                []
    in
    tr [ onClick (SearchMsg (ElasticSearch.ShowDetails item.id)) ]
        [ td [] [ text item.source.option_name ]
        ]
        :: packageDetails



-- API


makeRequest :
    ElasticSearch.Options
    -> String
    -> Cmd Msg
makeRequest options query =
    ElasticSearch.makeRequest
        "option_name"
        -- TODO: add support for different channels
        "nixos-unstable-options"
        decodeResultItemSource
        options
        query
        |> Cmd.map SearchMsg



-- JSON


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.map6 ResultItemSource
        (Json.Decode.field "option_name" Json.Decode.string)
        (Json.Decode.field "description" Json.Decode.string)
        (Json.Decode.field "type" Json.Decode.string)
        (Json.Decode.field "default" Json.Decode.string)
        (Json.Decode.field "example" Json.Decode.string)
        (Json.Decode.field "source" Json.Decode.string)
