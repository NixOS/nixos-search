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
        , div
        , li
        , pre
        , strong
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( class
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
import Route
import Search



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
view model =
    Search.view { toRoute = Route.Options, categoryName = "options" }
        [ text "Search more than "
        , strong [] [ text "10 000 options" ]
        ]
        model
        viewSuccess
        viewBuckets
        SearchMsg


viewBuckets :
    Maybe String
    -> Search.SearchResult ResultItemSource ResultAggregations
    -> List (Html Msg)
viewBuckets _ _ =
    []


viewSuccess :
    String
    -> Bool
    -> Maybe String
    -> List (Search.ResultItem ResultItemSource)
    -> Html Msg
viewSuccess channel showNixOSDetails show hits =
    ul []
        (List.map
            (viewResultItem channel showNixOSDetails show)
            hits
        )


viewResultItem :
    String
    -> Bool
    -> Maybe String
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItem channel _ show item =
    let
        showHtml value =
            [ div [] <|
                case Html.Parser.run value of
                    Ok nodes ->
                        Html.Parser.Util.toVirtualDom nodes

                    Err _ ->
                        []
            ]

        default =
            "Not given"

        asPre value =
            pre [] [ text value ]

        asPreCode value =
            div [] [ pre [] [ code [ class "code-block" ] [ text value ] ] ]

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
                        [ text value ]

                Nothing ->
                    text <| cleanPosition value

        withEmpty wrapWith maybe =
            case maybe of
                Nothing ->
                    asPre default

                Just "" ->
                    asPre default

                Just value ->
                    wrapWith value

        wrapped wrapWith value =
            case value of
                "" ->
                    wrapWith <| "\"" ++ value ++ "\""

                _ ->
                    wrapWith value

        showDetails =
            if Just item.source.name == show then
                [ div [ Html.Attributes.map SearchMsg Search.trapClick ]
                    [ div [] [ text "Default value" ]
                    , div [] [ withEmpty (wrapped asPreCode) item.source.default ]
                    , div [] [ text "Type" ]
                    , div [] [ withEmpty asPre item.source.type_ ]
                    , div [] [ text "Example" ]
                    , div [] [ withEmpty (wrapped asPreCode) item.source.example ]
                    , div [] [ text "Declared in" ]
                    , div [] [ withEmpty asGithubLink item.source.source ]
                    ]
                ]

            else
                []

        open =
            SearchMsg (Search.ShowDetails item.source.name)
    in
    li
        [ class "option"
        , onClick open
        , Search.elementId item.source.name
        ]
        (showDetails
            |> List.append
                (item.source.description
                    |> Maybe.map showHtml
                    |> Maybe.withDefault []
                )
            |> List.append
                [ Html.button
                    [ class "search-result-button" ]
                    [ text item.source.name ]
                ]
        )



-- API


makeRequest :
    Search.Options
    -> String
    -> String
    -> Int
    -> Int
    -> Maybe String
    -> Search.Sort
    -> Cmd Msg
makeRequest options channel query from size _ sort =
    Search.makeRequest
        (Search.makeRequestBody
            (String.trim query)
            from
            size
            sort
            "option"
            "option_name"
            []
            []
            [ ( "option_name", 6.0 )
            , ( "option_name_query", 3.0 )
            , ( "option_description", 1.0 )
            ]
        )
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        decodeResultAggregations
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


decodeResultAggregations : Json.Decode.Decoder ResultAggregations
decodeResultAggregations =
    Json.Decode.map ResultAggregations
        (Json.Decode.field "all" decodeResultAggregationsAll)


decodeResultAggregationsAll : Json.Decode.Decoder AggregationsAll
decodeResultAggregationsAll =
    Json.Decode.map AggregationsAll
        (Json.Decode.field "doc_count" Json.Decode.int)
