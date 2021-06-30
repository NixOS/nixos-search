module Page.Options exposing
    ( Model
    , Msg(..)
    , ResultAggregations
    , ResultItemSource
    , decodeResultAggregations
    , decodeResultItemSource
    , init
    , makeRequest
    , makeRequestBody
    , update
    , view
    , viewBuckets
    , viewSuccess
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
        , classList
        , href
        , target
        )
import Html.Events
    exposing
        ( onClick
        )
import Html.Parser
import Html.Parser.Util
import Http exposing (Body)
import Json.Decode
import Json.Decode.Pipeline
import List exposing (sort)
import Route exposing (SearchType)
import Search exposing (decodeResolvedFlake)
import Url.Parser exposing (query)
import Html exposing (source)
import Html exposing (span)



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

    -- flake
    , flake : Maybe ( String, String )
    , flakeDescription : Maybe String
    , flakeUrl : Maybe String
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
        []


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
            case Html.Parser.run value of
                Ok nodes ->
                    Html.Parser.Util.toVirtualDom nodes

                Err _ ->
                    []

        default =
            "Not given"

        asPre value =
            pre [] [ text value ]

        asPreCode value =
            div [] [ pre [] [ code [ class "code-block" ] [ text value ] ] ]

       


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
                div [ Html.Attributes.map SearchMsg Search.trapClick ]
                    [ div [] [ text "Name" ]
                    , div [] [ wrapped asPreCode item.source.name ]
                    , div [] [ text "Description" ]
                    , div [] <|
                        (item.source.description
                            |> Maybe.map showHtml
                            |> Maybe.withDefault []
                        )
                    , div [] [ text "Default value" ]
                    , div [] [ withEmpty (wrapped asPreCode) item.source.default ]
                    , div [] [ text "Type" ]
                    , div [] [ withEmpty asPre item.source.type_ ]
                    , div [] [ text "Example" ]
                    , div [] [ withEmpty (wrapped asPreCode) item.source.example ]
                    , div [] [ text "Declared in" ]
                    , div [] <| findSource channel item.source
                    ]
                    |> Just

            else
                Nothing

        toggle =
            SearchMsg (Search.ShowDetails item.source.name)

        isOpen =
            Just item.source.name == show
    in
    li
        [ class "option"
        , classList [ ( "opened", isOpen ) ]
        , Search.elementId item.source.name
        ]
    <|
        List.filterMap identity
            [ Just <|
                Html.a
                    [ class "search-result-button"
                    , onClick toggle
                    , href ""
                    ]
                    [ text item.source.name ]
            , showDetails
            ]


findSource : String -> ResultItemSource -> List (Html a)
findSource channel source =
    let
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
        
        
        
        sourceFile = Maybe.map asGithubLink source.source
        
        flakeOrNixpkgs : Maybe (List (Html a))
        flakeOrNixpkgs = case (source.flake, source.flakeUrl) of
            -- its a flake
            (Just (name, module_), Just flakeUrl_)->  
                Just <| 
                List.append
                (Maybe.withDefault [] <| Maybe.map (\sourceFile_ -> [sourceFile_, span [] [text" in "]]) sourceFile)
                
                [ span [] [text "Flake: "]
                  , a [href flakeUrl_] [text <| name ++ "(Module: " ++ module_ ++ ")" ]
                ]

            ( Nothing, _ ) -> Maybe.map (\l -> [l]) sourceFile

            _ -> Nothing


    in
        Maybe.withDefault  [span [] [text "Not Found"]] flakeOrNixpkgs

-- API


makeRequest :
    Search.Options
    -> SearchType
    -> String
    -> String
    -> Int
    -> Int
    -> Maybe String
    -> Search.Sort
    -> Cmd Msg
makeRequest options _ channel query from size _ sort =
    Search.makeRequest
        (makeRequestBody query from size sort)
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        decodeResultAggregations
        options
        Search.QueryResponse
        (Just "query-options")
        |> Cmd.map SearchMsg


makeRequestBody : String -> Int -> Int -> Search.Sort -> Body
makeRequestBody query from size sort =
    Search.makeRequestBody
        (String.trim query)
        from
        size
        sort
        "option"
        "option_name"
        []
        []
        []
        "option_name"
        [ ( "option_name", 6.0 )
        , ( "option_name_query", 3.0 )
        , ( "option_description", 1.0 )
        ]



-- JSON


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.succeed ResultItemSource
        |> Json.Decode.Pipeline.required "option_name" Json.Decode.string
        |> Json.Decode.Pipeline.optional "option_description" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "option_type" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "option_default" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "option_example" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "option_source" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "option_flake"
            (Json.Decode.map Just <| Json.Decode.map2 Tuple.pair (Json.Decode.index 0 Json.Decode.string) (Json.Decode.index 1 Json.Decode.string))
            Nothing
        |> Json.Decode.Pipeline.optional "flake_description" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_resolved" (Json.Decode.map Just decodeResolvedFlake) Nothing


decodeResultAggregations : Json.Decode.Decoder ResultAggregations
decodeResultAggregations =
    Json.Decode.map ResultAggregations
        (Json.Decode.field "all" decodeResultAggregationsAll)


decodeResultAggregationsAll : Json.Decode.Decoder AggregationsAll
decodeResultAggregationsAll =
    Json.Decode.map AggregationsAll
        (Json.Decode.field "doc_count" Json.Decode.int)
