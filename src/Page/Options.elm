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
        , code
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
        , target
        )
import Html.Events
    exposing
        ( onClick
        )
import Html.Parser
import Html.Parser.Util
import Json.Decode
import Json.Encode
import Regex
import Route
import Search



-- MODEL


type alias Model =
    Search.Model ResultItemSource


type alias ResultItemSource =
    { name : String
    , description : Maybe String
    , type_ : Maybe String
    , default : Maybe String
    , example : Maybe String
    , source : Maybe String
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
    = SearchMsg (Search.Msg ResultItemSource)


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
view model =
    Search.view { toRoute = Route.Options, categoryName = "options" }
        "Search NixOS options"
        model
        viewSuccess
        SearchMsg


viewSuccess :
    String
    -> Maybe String
    -> Search.SearchResult ResultItemSource
    -> Html Msg
viewSuccess channel show result =
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
                    (viewResultItem channel show)
                    result.hits.hits
                )
            ]
        ]


viewResultItem :
    String
    -> Maybe String
    -> Search.ResultItem ResultItemSource
    -> List (Html Msg)
viewResultItem channel show item =
    let
        packageDetails =
            if Just item.source.name == show then
                [ td [ colspan 1 ] [ viewResultItemDetails channel item ]
                ]

            else
                []
    in
    []
        -- DEBUG: |> List.append
        -- DEBUG:     [ tr []
        -- DEBUG:         [ td [ colspan 1 ]
        -- DEBUG:             [ div [] [ text <| "score: " ++ String.fromFloat (Maybe.withDefault 0 item.score) ]
        -- DEBUG:             , div []
        -- DEBUG:                 [ text <|
        -- DEBUG:                     "matched queries: "
        -- DEBUG:                 , ul []
        -- DEBUG:                     (item.matched_queries
        -- DEBUG:                         |> Maybe.withDefault []
        -- DEBUG:                         |> List.sort
        -- DEBUG:                         |> List.map (\q -> li [] [ text q ])
        -- DEBUG:                     )
        -- DEBUG:                 ]
        -- DEBUG:             ]
        -- DEBUG:         ]
        -- DEBUG:     ]
        |> List.append
            (tr [ onClick (SearchMsg (Search.ShowDetails item.source.name)) ]
                [ td [] [ text item.source.name ]
                ]
                :: packageDetails
            )


viewResultItemDetails :
    String
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItemDetails channel item =
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

        asPre value =
            pre [] [ text value ]

        asCode value =
            code [] [ text value ]

        githubUrlPrefix branch =
            "https://github.com/NixOS/nixpkgs/blob/" ++ branch ++ "/"

        cleanPosition value =
            if String.startsWith "source/" value then
                String.dropLeft 7 value

            else
                value

        asGithubLink value =
            case Search.channelDetailsFromId channel of
                Just channelDetails ->
                    a
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L")
                        , target "_blank"
                        ]
                        [ text <| value ]

                Nothing ->
                    text <| cleanPosition value

        wrapped wrapWith value =
            case value of
                "" ->
                    wrapWith <| "\"" ++ value ++ "\""

                _ ->
                    wrapWith value

        withEmpty wrapWith maybe =
            case maybe of
                Nothing ->
                    asPre default

                Just "" ->
                    asPre default

                Just value ->
                    wrapWith value
    in
    dl [ class "dl-horizontal" ]
        [ dt [] [ text "Name" ]
        , dd [] [ withEmpty asText (Just item.source.name) ]
        , dt [] [ text "Description" ]
        , dd [] [ withEmpty asText item.source.description ]
        , dt [] [ text "Default value" ]
        , dd [] [ withEmpty asCode item.source.default ]
        , dt [] [ text "Type" ]
        , dd [] [ withEmpty asPre item.source.type_ ]
        , dt [] [ text "Example value" ]
        , dd [] [ withEmpty (wrapped asCode) item.source.example ]
        , dt [] [ text "Declared in" ]
        , dd [] [ withEmpty asGithubLink item.source.source ]
        ]



-- API


makeRequest :
    Search.Options
    -> String
    -> String
    -> Int
    -> Int
    -> Search.Sort
    -> Cmd Msg
makeRequest options channel query from size sort =
    Search.makeRequest
        (Search.makeRequestBody
            (String.trim query)
            from
            size
            sort
            "option"
            "option_name"
            [ ( "option_name", 6.0 )
            , ( "option_name_query", 3.0 )
            , ( "option_description", 1.0 )
            ]
        )
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        options
        Search.QueryResponse
        (Just "query-options")
        |> Cmd.map SearchMsg



-- JSON


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.map6 ResultItemSource
        (Json.Decode.field "option_name" Json.Decode.string)
        (Json.Decode.field "option_description" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "option_type" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "option_default" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "option_example" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "option_source" (Json.Decode.nullable Json.Decode.string))
