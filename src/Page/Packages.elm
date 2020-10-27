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
        , pre
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
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Regex
import Route
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
    { name : Maybe String
    , email : Maybe String
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
                        Route.Packages
                        navKey
                        subMsg
                        model
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view : Model -> Html Msg
view model =
    Search.view { toRoute = Route.Packages, categoryName = "packages" }
        "Search NixOS packages"
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
    []
        -- DEBUG: |> List.append
        -- DEBUG:     [ tr []
        -- DEBUG:         [ td [ colspan 4 ]
        -- DEBUG:             [ div []
        -- DEBUG:                 [ text <|
        -- DEBUG:                     "score: "
        -- DEBUG:                         ++ (item.score
        -- DEBUG:                                 |> Maybe.map String.fromFloat
        -- DEBUG:                                 |> Maybe.withDefault "No score"
        -- DEBUG:                            )
        -- DEBUG:                 ]
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
            (tr [ onClick (SearchMsg (Search.ShowDetails item.source.attr_name)) ]
                [ td [] [ text <| item.source.attr_name ]
                , td [] [ text item.source.pname ]
                , td [] [ text item.source.pversion ]
                , td [] [ text <| Maybe.withDefault "" item.source.description ]
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
            "Not specified"

        asText =
            text

        asLink value =
            a [ href value ] [ text value ]

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
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L" |> cleanPosition) ]
                        [ text <| cleanPosition value ]

                Nothing ->
                    text <| cleanPosition value

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
            case
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

        showLicence license =
            case ( license.fullName, license.url ) of
                ( Nothing, Nothing ) ->
                    text default

                ( Just fullName, Nothing ) ->
                    text fullName

                ( Nothing, Just url ) ->
                    a [ href url ] [ text default ]

                ( Just fullName, Just url ) ->
                    a [ href url ] [ text fullName ]

        showMaintainer maintainer =
            a
                [ href <|
                    case maintainer.github of
                        Just github ->
                            "https://github.com/" ++ github

                        Nothing ->
                            "#"
                ]
                [ text <| Maybe.withDefault "" maintainer.name ++ " <" ++ Maybe.withDefault "" maintainer.email ++ ">" ]

        asPre value =
            pre [] [ text value ]

        asCode value =
            code [] [ text value ]

        asList list =
            case list of
                [] ->
                    asPre default

                _ ->
                    ul [ class "inline" ] <| List.map (\i -> li [] [ i ]) list

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
        [ dt [] [ text "Attribute Name" ]
        , dd [] [ withEmpty asText (Just item.source.attr_name) ]
        , dt [] [ text "Name" ]
        , dd [] [ withEmpty asText (Just item.source.pname) ]
        , dt [] [ text "Install command" ]
        , dd [] [ withEmpty asCode (Just ("nix-env -iA nixos." ++ item.source.attr_name)) ]
        , dt [] [ text "Nix expression" ]
        , dd [] [ withEmpty asGithubLink item.source.position ]
        , dt [] [ text "Platforms" ]
        , dd [] [ asList (showPlatforms item.source.hydra item.source.platforms) ]
        , dt [] [ text "Homepage" ]
        , dd [] [ withEmpty asLink item.source.homepage ]
        , dt [] [ text "Licenses" ]
        , dd [] [ asList (List.map showLicence item.source.licenses) ]
        , dt [] [ text "Maintainers" ]
        , dd [] [ asList (List.map showMaintainer item.source.maintainers) ]
        , dt [] [ text "Description" ]
        , dd [] [ withEmpty asText item.source.description ]
        , dt [] [ text "Long description" ]
        , dd [] [ withEmpty asText item.source.longDescription ]
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
            "package"
            "package_attr_name"
            [ ( "package_attr_name", 9.0 )
            , ( "package_pname", 6.0 )
            , ( "package_attr_name_query", 4.0 )
            , ( "package_description", 1.3 )
            , ( "package_longDescription", 1.0 )
            ]
        )
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        options
        Search.QueryResponse
        (Just "query-packages")
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
        (Json.Decode.field "name" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "email" (Json.Decode.nullable Json.Decode.string))
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
