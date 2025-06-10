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
        , span
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
import Http exposing (Body)
import Json.Decode
import Json.Decode.Pipeline
import Route exposing (SearchType)
import Search
    exposing
        ( Details
        , NixOSChannel
        , decodeResolvedFlake
        )
import Utils
import SyntaxHighlight exposing (useTheme, oneDark, elm, toBlockHtml)



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
    , flake : Maybe (List String)
    , flakeName : Maybe String
    , flakeDescription : Maybe String
    , flakeUrl : Maybe String
    }


type alias ResultAggregations =
    { all : AggregationsAll
    }


type alias AggregationsAll =
    { doc_count : Int
    }


init :
    Route.SearchArgs
    -> String
    -> List NixOSChannel
    -> Maybe Model
    -> ( Model, Cmd Msg )
init searchArgs defaultNixOSChannel nixosChannels model =
    let
        ( newModel, newCmd ) =
            Search.init searchArgs defaultNixOSChannel nixosChannels model
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
    -> List NixOSChannel
    -> ( Model, Cmd Msg )
update navKey msg model nixosChannels =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    Search.update
                        Route.Options
                        navKey
                        subMsg
                        model
                        nixosChannels
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view :
    List NixOSChannel
    -> Model
    -> Html Msg
view nixosChannels model =
    Search.view { toRoute = Route.Options, categoryName = "options" }
        [ text "Search more than "
        , strong [] [ text "20 000 options" ]
        ]
        nixosChannels
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
    List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> List (Search.ResultItem ResultItemSource)
    -> Html Msg
viewSuccess nixosChannels channel showInstallDetails show hits =
    ul []
        (List.map
            (viewResultItem nixosChannels channel showInstallDetails show)
            hits
        )


viewResultItem :
    List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItem nixosChannels channel _ show item =
    let
        asPre value =
            pre [] [ text value ]

        asPreCode value =
            div [] [ pre [] [ code [ class "code-block" ] [ text value ] ] ]
        
        asHighlightPreCode value =
            div [] 
                [ useTheme oneDark
                , elm value
                    |> Result.map (toBlockHtml (Just 1))
                    |> Result.withDefault
                    (pre [] [ code [ class "code-block" ] [ text value ]])
                ]

        showDetails =
            if Just item.source.name == show then
                Just <|
                    div [ Html.Attributes.map SearchMsg Search.trapClick ] <|
                        [ div [] [ text "Name" ]
                        , div [] [ asPreCode item.source.name ]
                        ]
                            ++ (item.source.description
                                    |> Maybe.andThen Utils.showHtml
                                    |> Maybe.map
                                        (\description ->
                                            [ div [] [ text "Description" ]
                                            , div [] description
                                            ]
                                        )
                                    |> Maybe.withDefault []
                               )
                            ++ (item.source.type_
                                    |> Maybe.map
                                        (\type_ ->
                                            [ div [] [ text "Type" ]
                                            , div [] [ asPre type_ ]
                                            ]
                                        )
                                    |> Maybe.withDefault []
                               )
                            ++ (item.source.default
                                    |> Maybe.map
                                        (\default ->
                                            [ div [] [ text "Default" ]
                                            , div [] <| Maybe.withDefault [ asPreCode default ] (Utils.showHtml default)
                                            ]
                                        )
                                    |> Maybe.withDefault []
                               )
                            ++ (item.source.example
                                    |> Maybe.map
                                        (\example ->
                                            [ div [] [ text "Example" ]
                                            , div [] <| Maybe.withDefault [ asHighlightPreCode example ] (Utils.showHtml example)
                                            ]
                                        )
                                    |> Maybe.withDefault []
                               )
                            ++ [ div [] [ text "Declared in" ]
                               , div [] <| findSource nixosChannels channel item.source
                               ]

            else
                Nothing

        toggle =
            SearchMsg (Search.ShowDetails item.source.name)

        isOpen =
            Just item.source.name == show

        flakeOrNixpkgs =
            let
                mkLink flake url =
                    a [ href url ] [ text flake ]
            in
            case ( item.source.flake, item.source.flakeUrl ) of
                -- its a flake
                ( Just (flake :: []), Just url ) ->
                    Just
                        [ li [] [ mkLink flake url ]
                        ]

                ( Just (flake :: moduleName :: []), Just url ) ->
                    Just [ li [] [ mkLink flake url, text "#", text moduleName ] ]

                _ ->
                    Nothing
    in
    li
        [ class "option"
        , classList [ ( "opened", isOpen ) ]
        , Search.elementId item.source.name
        ]
    <|
        List.filterMap identity
            [ Just <|
                ul [ class "search-result-button" ]
                    (List.append
                        (flakeOrNixpkgs |> Maybe.withDefault [])
                        [ li []
                            [ a
                                [ onClick toggle
                                , href ""
                                ]
                                [ text item.source.name ]
                            ]
                        ]
                    )
            , showDetails
            ]


findSource :
    List NixOSChannel
    -> String
    -> ResultItemSource
    -> List (Html a)
findSource nixosChannels channel source =
    let
        githubUrlPrefix branch =
            "https://github.com/NixOS/nixpkgs/blob/" ++ branch ++ "/"

        cleanPosition value =
            if String.startsWith "source/" value then
                String.dropLeft 7 value

            else
                value

        asGithubLink value =
            case List.head (List.filter (\x -> x.id == channel) nixosChannels) of
                Just channelDetails ->
                    a
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L")
                        , target "_blank"
                        ]
                        [ text value ]

                Nothing ->
                    text <| cleanPosition value

        sourceFile =
            Maybe.map asGithubLink source.source

        flakeOrNixpkgs : Maybe (List (Html a))
        flakeOrNixpkgs =
            case ( source.flake, source.flakeUrl ) of
                -- its a flake
                ( Just (name :: attrs), Just flakeUrl_ ) ->
                    let
                        module_ =
                            Maybe.withDefault "(default)" <| Maybe.map (\m -> "(Module: " ++ m ++ ")") <| List.head attrs
                    in
                    Just <|
                        List.append
                            (Maybe.withDefault [] <| Maybe.map (\sourceFile_ -> [ sourceFile_, span [] [ text " in " ] ]) sourceFile)
                            [ span [] [ text "Flake: " ]
                            , a [ href flakeUrl_ ] [ text <| name ++ module_ ]
                            ]

                ( Nothing, _ ) ->
                    Maybe.map (\l -> [ l ]) sourceFile

                _ ->
                    Nothing
    in
    Maybe.withDefault [ span [] [ text "Not Found" ] ] flakeOrNixpkgs



-- API


makeRequest :
    Search.Options
    -> List NixOSChannel
    -> SearchType
    -> String
    -> String
    -> Int
    -> Int
    -> Maybe String
    -> Search.Sort
    -> Cmd Msg
makeRequest options nixosChannels _ channel query from size _ sort =
    Search.makeRequest
        (makeRequestBody query from size sort)
        nixosChannels
        channel
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
        , ( "option_description", 1.0 )
        , ( "flake_name", 0.5 )
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
            (Json.Decode.map Just <| Json.Decode.list Json.Decode.string)
            Nothing
        |> Json.Decode.Pipeline.optional "flake_name" (Json.Decode.map Just Json.Decode.string) Nothing
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
