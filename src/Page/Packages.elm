module Page.Packages exposing
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
        , li
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
import Http
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Search



-- MODEL


type alias Model =
    Search.Model ResultItemSource


type alias ResultItemSource =
    { attr_name : String
    , pname : String
    , pversion : String
    , description : Maybe String
    , longDescription : Maybe String
    , licenses : List ResultPackageLicense
    , maintainers : List ResultPackageMaintainer
    , platforms : List String
    , position : Maybe String
    , homepage : Maybe String
    , system : String
    , hydra : Maybe (List ResultPackageHydra)
    }


type alias ResultPackageLicense =
    { fullName : Maybe String
    , url : Maybe String
    }


type alias ResultPackageMaintainer =
    { name : String
    , email : String
    , github : Maybe String
    }


type alias ResultPackageHydra =
    { build_id : Int
    , build_status : Int
    , platform : String
    , project : String
    , jobset : String
    , job : String
    , path : List ResultPackageHydraPath
    , drv_path : String
    }


type alias ResultPackageHydraPath =
    { output : String
    , path : String
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
                    Search.update "packages" navKey subMsg model
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view : Model -> Html Msg
view model =
    Search.view
        "packages"
        "Search NixOS packages"
        model
        viewSuccess
        SearchMsg


viewSuccess :
    String
    -> Maybe String
    -> Search.Result ResultItemSource
    -> Html Msg
viewSuccess channel show result =
    div [ class "search-result" ]
        [ table [ class "table table-hover" ]
            [ thead []
                [ tr []
                    [ th [] [ text "Attribute name" ]
                    , th [] [ text "Name" ]
                    , th [] [ text "Version" ]
                    , th [] [ text "Description" ]
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
            if Just item.source.attr_name == show then
                [ td [ colspan 4 ] [ viewResultItemDetails channel item ]
                ]

            else
                []
    in
    tr [ onClick (SearchMsg (Search.ShowDetails item.source.attr_name)) ]
        [ td [] [ text item.source.attr_name ]
        , td [] [ text item.source.pname ]
        , td [] [ text item.source.pversion ]
        , td [] [ text <| Maybe.withDefault "" item.source.description ]
        ]
        :: packageDetails


viewResultItemDetails :
    String
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItemDetails channel item =
    let
        default =
            "Not specified"

        asText =
            text

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
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L" |> cleanPosition) ]
                        [ text <| cleanPosition value ]

                Nothing ->
                    text <| cleanPosition value

        withDefault wrapWith maybe =
            case maybe of
                Nothing ->
                    text default

                Just "" ->
                    text default

                Just value ->
                    wrapWith value

        mainPlatforms platform =
            List.member platform
                [ "x86_64-linux"
                , "aarch64-linux"
                , "x86_64-darwin"
                , "i686-linux"
                ]

        getHydraDetailsForPlatform hydra platform =
            hydra
                |> Maybe.andThen
                    (\hydras ->
                        hydras
                            |> List.filter (\x -> x.platform == platform)
                            |> List.head
                    )

        showPlatforms hydra platforms =
            platforms
                |> List.filter mainPlatforms
                |> List.map (showPlatform hydra)

        showPlatform hydra platform =
            li []
                [ case
                    ( getHydraDetailsForPlatform hydra platform
                    , Search.channelDetailsFromId channel
                    )
                  of
                    ( Just hydraDetails, _ ) ->
                        a
                            [ href <| "https://hydra.nixos.org/build/" ++ String.fromInt hydraDetails.build_id
                            ]
                            [ text platform
                            ]

                    ( Nothing, Just channelDetails ) ->
                        a
                            [ href <| "https://hydra.nixos.org/job/" ++ channelDetails.jobset ++ "/nixpkgs." ++ item.source.attr_name ++ "." ++ platform
                            ]
                            [ text platform
                            ]

                    ( _, _ ) ->
                        text platform
                ]

        showLicence license =
            li []
                [ case ( license.fullName, license.url ) of
                    ( Nothing, Nothing ) ->
                        text default

                    ( Just fullName, Nothing ) ->
                        text fullName

                    ( Nothing, Just url ) ->
                        a [ href url ] [ text default ]

                    ( Just fullName, Just url ) ->
                        a [ href url ] [ text fullName ]
                ]

        showMaintainer maintainer =
            li []
                [ a
                    [ href <|
                        case maintainer.github of
                            Just github ->
                                "https://github.com/" ++ github

                            Nothing ->
                                "#"
                    ]
                    [ text <| maintainer.name ++ " <" ++ maintainer.email ++ ">" ]
                ]
    in
    dl [ class "dl-horizontal" ]
        [ dt [] [ text "Install command" ]
        , dd [] [ code [] [ text <| "nix-env -iA nixos." ++ item.source.attr_name ] ]
        , dt [] [ text <| "Nix expression" ]
        , dd [] [ withDefault asGithubLink item.source.position ]
        , dt [] [ text "Platforms" ]
        , dd [] [ ul [ class "inline" ] <| showPlatforms item.source.hydra item.source.platforms ]
        , dt [] [ text "Homepage" ]
        , dd [] [ withDefault asLink item.source.homepage ]
        , dt [] [ text "Licenses" ]
        , dd [] [ ul [ class "inline" ] <| List.map showLicence item.source.licenses ]
        , dt [] [ text "Maintainers" ]
        , dd [] [ ul [ class "inline" ] <| List.map showMaintainer item.source.maintainers ]
        , dt [] [ text "Long description" ]
        , dd [] [ withDefault asText item.source.longDescription ]
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
    --         }
    --       },
    --       "must": {
    --         "bool": {
    --           "should": [
    --             {
    --               "multi_match": {
    --                 "query": "python",
    --                 "boost": 1,
    --                 "fields": [
    --                   "package_attr_name.raw",
    --                   "package_attr_name"
    --                 ],
    --                 "type": "most_fields"
    --               }
    --             },
    --             {
    --               "term": {
    --                 "type": {
    --                   "value": "package",
    --                   "boost": 0
    --                 }
    --               }
    --             },
    --             {
    --               "term": {
    --                 "package_pname": {
    --                   "value": "python",
    --                   "boost": 2
    --                 }
    --               }
    --             },
    --             {
    --               "term": {
    --                 "package_pversion": {
    --                   "value": "python",
    --                   "boost": 0.2
    --                 }
    --               }
    --             },
    --             {
    --               "term": {
    --                 "package_description": {
    --                   "value": "python",
    --                   "boost": 0.3
    --                 }
    --               }
    --             },
    --             {
    --               "term": {
    --                 "package_longDescription": {
    --                   "value": "python",
    --                   "boost": 0.1
    --                 }
    --               }
    --             }
    --           ]
    --         }
    --       }
    --     }
    --   }
    -- }
    let
        listIn name type_ value =
            [ ( name, Json.Encode.list type_ value ) ]

        objectIn name value =
            [ ( name, Json.Encode.object value ) ]

        encodeTerm ( name, boost ) =
            [ ( "value", Json.Encode.string query )
            , ( "boost", Json.Encode.float boost )
            ]
                |> objectIn name
                |> objectIn "term"
    in
    [ ( "package_pname", 2.0 )
    , ( "package_pversion", 0.2 )
    , ( "package_description", 0.3 )
    , ( "package_longDescription", 0.1 )
    ]
        |> List.map encodeTerm
        |> List.append
            [ [ "package_attr_name.raw"
              , "package_attr_name"
              ]
                |> listIn "fields" Json.Encode.string
                |> List.append
                    [ ( "query", Json.Encode.string query )
                    , ( "boost", Json.Encode.float 1.0 )
                    ]
                |> objectIn "multi_match"
            ]
        |> listIn "should" Json.Encode.object
        |> objectIn "bool"
        |> objectIn "must"
        |> ([ ( "type", Json.Encode.string "package" ) ]
                |> objectIn "match"
                |> objectIn "filter"
                |> List.append
           )
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
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        options
        query
        from
        size
        |> Cmd.map SearchMsg



-- JSON


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.succeed ResultItemSource
        |> Json.Decode.Pipeline.required "package_attr_name" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_pname" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_pversion" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_description" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_longDescription" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_license" (Json.Decode.list decodeResultPackageLicense)
        |> Json.Decode.Pipeline.required "package_maintainers" (Json.Decode.list decodeResultPackageMaintainer)
        |> Json.Decode.Pipeline.required "package_platforms" (Json.Decode.list Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_position" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_homepage" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_system" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_hydra" (Json.Decode.nullable (Json.Decode.list decodeResultPackageHydra))


decodeResultPackageLicense : Json.Decode.Decoder ResultPackageLicense
decodeResultPackageLicense =
    Json.Decode.map2 ResultPackageLicense
        (Json.Decode.field "fullName" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "url" (Json.Decode.nullable Json.Decode.string))


decodeResultPackageMaintainer : Json.Decode.Decoder ResultPackageMaintainer
decodeResultPackageMaintainer =
    Json.Decode.map3 ResultPackageMaintainer
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "email" Json.Decode.string)
        (Json.Decode.field "github" (Json.Decode.nullable Json.Decode.string))


decodeResultPackageHydra : Json.Decode.Decoder ResultPackageHydra
decodeResultPackageHydra =
    Json.Decode.succeed ResultPackageHydra
        |> Json.Decode.Pipeline.required "build_id" Json.Decode.int
        |> Json.Decode.Pipeline.required "build_status" Json.Decode.int
        |> Json.Decode.Pipeline.required "platform" Json.Decode.string
        |> Json.Decode.Pipeline.required "project" Json.Decode.string
        |> Json.Decode.Pipeline.required "jobset" Json.Decode.string
        |> Json.Decode.Pipeline.required "job" Json.Decode.string
        |> Json.Decode.Pipeline.required "path" (Json.Decode.list decodeResultPackageHydraPath)
        |> Json.Decode.Pipeline.required "drv_path" Json.Decode.string


decodeResultPackageHydraPath : Json.Decode.Decoder ResultPackageHydraPath
decodeResultPackageHydraPath =
    Json.Decode.map2 ResultPackageHydraPath
        (Json.Decode.field "output" Json.Decode.string)
        (Json.Decode.field "path" Json.Decode.string)

