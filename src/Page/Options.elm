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
        , a
        , dd
        , div
        , dl
        , dt
        , pre
        , span
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
        , href
        , property
        )
import Html.Events
    exposing
        ( onClick
        )
import Html.Parser
import Html.Parser.Util
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
    -> Maybe Int
    -> Maybe Int
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
        "options"
        "Search NixOS options"
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
                [ td [ colspan 1 ] [ viewResultItemDetails item ]
                ]

            else
                []
    in
    tr [ onClick (SearchMsg (ElasticSearch.ShowDetails item.id)) ]
        [ td [] [ text item.source.option_name ]
        ]
        :: packageDetails


viewResultItemDetails :
    ElasticSearch.ResultItem ResultItemSource
    -> Html Msg
viewResultItemDetails item =
    let
        default =
            "Not given"

        asText value =
            span [] <|
                case Html.Parser.run value of
                    Ok nodes ->
                        Html.Parser.Util.toVirtualDom nodes

                    Err _ ->
                        []

        asCode value =
            pre [] [ text value ]

        asLink value =
            a [ href value ] [ text value ]

        -- TODO: this should take channel into account as well
        githubUrlPrefix =
            "https://github.com/NixOS/nixpkgs-channels/blob/nixos-unstable/"

        asGithubLink value =
            a
                [ href <| githubUrlPrefix ++ (value |> String.replace ":" "#L") ]
                [ text <| value ]

        withDefault wrapWith value =
            case value of
                "" ->
                    text default

                "None" ->
                    text default

                _ ->
                    wrapWith value
    in
    dl [ class "dl-horizontal" ]
        [ dt [] [ text "Description" ]
        , dd [] [ withDefault asText item.source.description ]
        , dt [] [ text "Default value" ]
        , dd [] [ withDefault asCode item.source.default ]
        , dt [] [ text "Type" ]
        , dd [] [ withDefault asCode item.source.type_ ]
        , dt [] [ text "Example value" ]
        , dd [] [ withDefault asCode item.source.example ]
        , dt [] [ text "Declared in" ]
        , dd [] [ withDefault asGithubLink item.source.source ]
        ]



-- API


makeRequest :
    ElasticSearch.Options
    -> String
    -> Int
    -> Int
    -> Cmd Msg
makeRequest options query from size =
    ElasticSearch.makeRequest
        "option_name"
        "nixos-unstable-options"
        decodeResultItemSource
        options
        query
        from
        size
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
