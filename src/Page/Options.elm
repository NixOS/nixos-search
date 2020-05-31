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
import Http
import Json.Decode
import Json.Encode
import Search



-- MODEL


type alias Model =
    Search.Model ResultItemSource


type alias ResultItemSource =
    { name : String
    , description : String
    , type_ : String
    , default : String
    , example : String
    , source : String
    }


init :
    Maybe String
    -> Maybe String
    -> Maybe String
    -> Maybe Int
    -> Maybe Int
    -> ( Model, Cmd Msg )
init =
    Search.init



-- UPDATE


type Msg
    = SearchMsg (Search.Msg ResultItemSource)


update : Browser.Navigation.Key -> Msg -> Model -> ( Model, Cmd Msg )
update navKey msg model =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    Search.update "options" navKey subMsg model
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view : Model -> Html Msg
view model =
    Search.view
        "options"
        "Search NixOS options"
        model
        viewSuccess
        SearchMsg


viewSuccess :
    Maybe String
    -> Search.Result ResultItemSource
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
    -> Search.ResultItem ResultItemSource
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
    tr [ onClick (SearchMsg (Search.ShowDetails item.id)) ]
        [ td [] [ text item.source.name ]
        ]
        :: packageDetails


viewResultItemDetails :
    Search.ResultItem ResultItemSource
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


makeRequestBody :
    String
    -> Int
    -> Int
    -> Http.Body
makeRequestBody query from size =
    -- Prefix Query
    --   example query for "python"
    -- {
    --   "from": 0,
    --   "size": 10,
    --   "query": {
    --     "bool": {
    --       "filter": {
    --         "match": {
    --           "type": "package"
    --         },
    --       },
    --       "should": [
    --       ]
    --     }
    --   }
    -- }
    let
        listIn name type_ value =
            [ ( name, Json.Encode.list type_ value ) ]

        objectIn name value =
            [ ( name, Json.Encode.object value ) ]

        encodeTerm ( name, boost ) =
            [ ( "term"
              , Json.Encode.object
                    [ ( name
                      , Json.Encode.object
                            [ ( "value", Json.Encode.string query )
                            , ( "boost", Json.Encode.float boost )
                            ]
                      )
                    ]
              )
            ]
    in
    [ ( "option_name", 2.0 )
    , ( "option_description", 0.3 )
    ]
        |> List.map encodeTerm
        |> listIn "should" Json.Encode.object
        |> List.append
            [ ( "filter"
              , Json.Encode.object
                    [ ( "match"
                      , Json.Encode.object
                            [ ( "type", Json.Encode.string "option" )
                            ]
                      )
                    ]
              )
            ]
        |> objectIn "bool"
        |> objectIn "query"
        |> List.append
            [ ( "from", Json.Encode.int from )
            , ( "size", Json.Encode.int size )
            ]
        |> Json.Encode.object
        |> Http.jsonBody


makeRequest :
    Search.Options
    -> String
    -> String
    -> Int
    -> Int
    -> Cmd Msg
makeRequest options channel query from size =
    Search.makeRequest
        (makeRequestBody query from size)
        ("latest-nixos-" ++ channel)
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
        (Json.Decode.field "option_description" Json.Decode.string)
        (Json.Decode.field "option_type" Json.Decode.string)
        (Json.Decode.field "option_default" Json.Decode.string)
        (Json.Decode.field "option_example" Json.Decode.string)
        (Json.Decode.field "option_source" Json.Decode.string)
