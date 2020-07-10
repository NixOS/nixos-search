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
        , li
        , p
        , pre
        , span
        , table
        , tbody
        , td
        , text
        , th
        , thead
        , tr
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , colspan
        , href
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
import Regex
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


init :
    Maybe String
    -> Maybe String
    -> Maybe String
    -> Maybe Int
    -> Maybe Int
    -> Maybe String
    -> Maybe Model
    -> ( Model, Cmd Msg )
init channel query show from size sort model =
    let
        ( newModel, newCmd ) =
            Search.init channel query show from size sort model
    in
    ( newModel
    , Cmd.map SearchMsg newCmd
    )



-- UPDATE


type Msg
    = SearchMsg (Search.Msg ResultItemSource)


update : Browser.Navigation.Key -> Search.Options -> Msg -> Model -> ( Model, Cmd Msg )
update navKey options msg model =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    Search.update
                        "options"
                        navKey
                        "option"
                        options
                        decodeResultItemSource
                        subMsg
                        model
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
        -- DEBUG:             [ p [] [ text <| "score: " ++ String.fromFloat item.score ]
        -- DEBUG:             , p []
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

        asCode value =
            pre [] [ text value ]

        asLink value =
            a [ href value ] [ text value ]

        githubUrlPrefix branch =
            "https://github.com/NixOS/nixpkgs-channels/blob/" ++ branch ++ "/"

        cleanPosition value =
            if String.startsWith "source/" value then
                String.dropLeft 7 value

            else
                value

        asGithubLink value =
            case Search.channelDetailsFromId channel of
                Just channelDetails ->
                    a
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L") ]
                        [ text <| value ]

                Nothing ->
                    text <| cleanPosition value

        wrapped wrapWith value =
            case value of
                "" ->
                    wrapWith <| "\"" ++ value ++ "\""

                _ ->
                    wrapWith value
    in
    dl [ class "dl-horizontal" ]
        [ dt [] [ text "Description" ]
        , dd []
            [ item.source.description
                |> Maybe.withDefault default
                |> asText
            ]
        , dt [] [ text "Default value" ]
        , dd []
            [ item.source.default
                |> Maybe.withDefault default
                |> wrapped asCode
            ]
        , dt [] [ text "Type" ]
        , dd []
            [ item.source.type_
                |> Maybe.withDefault default
                |> asCode
            ]
        , dt [] [ text "Example value" ]
        , dd []
            [ item.source.example
                |> Maybe.withDefault default
                |> wrapped asCode
            ]
        , dt [] [ text "Declared in" ]
        , dd []
            [ item.source.source
                |> Maybe.withDefault default
                |> asGithubLink
            ]
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
makeRequest options channel queryRaw from size sort =
    let
        query =
            queryRaw
                |> String.trim

        delimiters =
            Maybe.withDefault Regex.never (Regex.fromString "[. ]")

        should_match boost_base =
            List.indexedMap
                (\i ( field, boost ) ->
                    [ ( "match"
                      , Json.Encode.object
                            [ ( field
                              , Json.Encode.object
                                    [ ( "query", Json.Encode.string query )
                                    , ( "boost", Json.Encode.float boost )
                                    , ( "analyzer", Json.Encode.string "whitespace" )
                                    , ( "fuzziness", Json.Encode.string "1" )
                                    , ( "_name"
                                      , Json.Encode.string <|
                                            "should_match_"
                                                ++ String.fromInt (i + 1)
                                      )
                                    ]
                              )
                            ]
                      )
                    ]
                )
                [ ( "option_name", 1 )
                , ( "option_name_query", 1 )
                , ( "option_description", 1 )
                ]

        should_match_bool_prefix boost_base =
            List.indexedMap
                (\i ( field, boost ) ->
                    [ ( "match_bool_prefix"
                      , Json.Encode.object
                            [ ( field
                              , Json.Encode.object
                                    [ ( "query", Json.Encode.string query )
                                    , ( "boost", Json.Encode.float boost )
                                    , ( "analyzer", Json.Encode.string "whitespace" )
                                    , ( "fuzziness", Json.Encode.string "1" )
                                    , ( "_name"
                                      , Json.Encode.string <|
                                            "should_match_bool_prefix_"
                                                ++ String.fromInt (i + 1)
                                      )
                                    ]
                              )
                            ]
                      )
                    ]
                )
                [ ( "option_name", 1 )
                , ( "option_name_query", 1 )
                ]

        should_terms boost_base =
            List.indexedMap
                (\i ( field, boost ) ->
                    [ ( "terms"
                      , Json.Encode.object
                            [ ( field
                              , Json.Encode.list Json.Encode.string (Regex.split delimiters query)
                              )
                            , ( "boost", Json.Encode.float <| boost_base * boost )
                            , ( "_name"
                              , Json.Encode.string <|
                                    "should_terms_"
                                        ++ String.fromInt (i + 1)
                              )
                            ]
                      )
                    ]
                )
                [ ( "option_name", 1 )
                , ( "option_name_query", 1 )
                ]

        should_term boost_base =
            List.indexedMap
                (\i ( field, boost ) ->
                    [ ( "term"
                      , Json.Encode.object
                            [ ( field
                              , Json.Encode.object
                                    [ ( "value", Json.Encode.string query )
                                    , ( "boost", Json.Encode.float <| boost_base * boost )
                                    , ( "_name"
                                      , Json.Encode.string <|
                                            "should_term_"
                                                ++ String.fromInt (i + 1)
                                      )
                                    ]
                              )
                            ]
                      )
                    ]
                )
                [ ( "option_name", 1 )
                , ( "option_name_query", 1 )
                ]

        should_queries =
            []
                |> List.append (should_term 10000)
                |> List.append (should_terms 1000)
                |> List.append (should_match_bool_prefix 100)
                |> List.append (should_match 10)
    in
    Search.makeRequest
        (Search.makeRequestBody query from size sort "option" "option_name" "option_name_query" should_queries)
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
