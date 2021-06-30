module Page.Packages exposing
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
    , viewSuccess, viewBucket
    )

import Browser.Navigation
import Html
    exposing
        ( Html
        , a
        , div
        , em
        , h4
        , li
        , p
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
        , id
        , target
        , type_
        )
import Html.Events exposing (onClick)
import Http exposing (Body)
import Json.Decode exposing (Decoder)
import Json.Decode.Pipeline
import Json.Encode
import Regex
import Route exposing (SearchType)
import Search
import Utils
import Search exposing (decodeResolvedFlake)



-- MODEL


type alias Model =
    Search.Model ResultItemSource ResultAggregations


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
    , homepage : List String
    , system : String
    , hydra : Maybe (List ResultPackageHydra)
    , flakeName : Maybe String
    , flakeDescription : Maybe String
    , flakeUrl : Maybe String
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


type alias ResultAggregations =
    { all : Aggregations
    , package_platforms : Search.Aggregation
    , package_attr_set : Search.Aggregation
    , package_maintainers_set : Search.Aggregation
    , package_license_set : Search.Aggregation
    }


type alias Aggregations =
    { doc_count : Int
    , package_platforms : Search.Aggregation
    , package_attr_set : Search.Aggregation
    , package_maintainers_set : Search.Aggregation
    , package_license_set : Search.Aggregation
    }


type alias Buckets =
    { packageSets : List String
    , licenses : List String
    , maintainers : List String
    , platforms : List String
    }


emptyBuckets : Buckets
emptyBuckets =
    { packageSets = []
    , licenses = []
    , maintainers = []
    , platforms = []
    }


initBuckets :
    Maybe String
    -> Buckets
initBuckets bucketsAsString =
    bucketsAsString
        |> Maybe.map (Json.Decode.decodeString decodeBuckets)
        |> Maybe.andThen Result.toMaybe
        |> Maybe.withDefault emptyBuckets


init : Route.SearchArgs -> Maybe Model -> ( Model, Cmd Msg )
init searchArgs model =
    let
        ( newModel, newCmd ) =
            Search.init searchArgs model

        -- _ =
        --     Debug.log "New package model" newModel
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
        [ text "Search more than "
        , strong [] [ text "80 000 packages" ]
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
viewBuckets bucketsAsString result =
    let
        initialBuckets =
            initBuckets bucketsAsString

        selectedBucket =
            initialBuckets

        createBucketsMsg getBucket mergeBuckets value =
            value
                |> Utils.toggleList (getBucket initialBuckets)
                |> mergeBuckets initialBuckets
                |> encodeBuckets
                |> Json.Encode.encode 0
                |> Search.BucketsChange
                |> SearchMsg

        sortBuckets items =
            items
                |> List.sortBy .doc_count
                |> List.reverse
    in
    []
        |> viewBucket
            "Package sets"
            (result.aggregations.package_attr_set.buckets |> sortBuckets)
            (createBucketsMsg .packageSets (\s v -> { s | packageSets = v }))
            selectedBucket.packageSets
        |> viewBucket
            "Licenses"
            (result.aggregations.package_license_set.buckets |> sortBuckets)
            (createBucketsMsg .licenses (\s v -> { s | licenses = v }))
            selectedBucket.licenses
        |> viewBucket
            "Maintainers"
            (result.aggregations.package_maintainers_set.buckets |> sortBuckets)
            (createBucketsMsg .maintainers (\s v -> { s | maintainers = v }))
            selectedBucket.maintainers
        |> viewBucket
            "Platforms"
            (result.aggregations.package_platforms.buckets |> sortBuckets)
            (createBucketsMsg .platforms (\s v -> { s | platforms = v }))
            selectedBucket.platforms


viewBucket :
    String
    -> List Search.AggregationsBucketItem
    -> (String -> Msg)
    -> List String
    -> List (Html Msg)
    -> List (Html Msg)
viewBucket title buckets searchMsgFor selectedBucket sets =
    List.append
        sets
        (if List.isEmpty buckets then
            []

         else
            [ li []
                [ ul []
                    (List.append
                        [ li [ class "header" ] [ text title ] ]
                        (List.map
                            (\bucket ->
                                li []
                                    [ a
                                        [ href "#"
                                        , onClick <| searchMsgFor bucket.key
                                        , classList
                                            [ ( "selected"
                                              , List.member bucket.key selectedBucket
                                              )
                                            ]
                                        ]
                                        [ span [] [ text bucket.key ]
                                        , span [] [ span [ class "badge" ] [ text <| String.fromInt bucket.doc_count ] ]
                                        ]
                                    ]
                            )
                            buckets
                        )
                    )
                ]
            ]
        )


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
viewResultItem channel showNixOSDetails show item =
    let
        cleanPosition =
            Regex.fromString "^[0-9a-f]+\\.tar\\.gz\\/"
                |> Maybe.withDefault Regex.never
                >> (\reg -> Regex.replace reg (\_ -> ""))

        createGithubUrl branch value =
            let
                uri =
                    value
                        |> String.replace ":" "#L"
                        |> cleanPosition
            in
            "https://github.com/NixOS/nixpkgs/blob/" ++ branch ++ "/" ++ uri

        createShortDetailsItem title url =
            a
                [ href url
                , target "_blank"
                ]
                [ text title ]

        shortPackageDetails =
            ul []
                (renderSource item channel trapClick createShortDetailsItem createGithubUrl
                    |> List.append
                        (item.source.homepage
                            |> List.head
                            |> Maybe.map
                                (\x ->
                                    [ li [ trapClick ]
                                        [ createShortDetailsItem "Homepage" x ]
                                    ]
                                )
                            |> Maybe.withDefault []
                        )
                    |> List.append
                        (item.source.licenses
                            |> List.filterMap
                                (\license ->
                                    case ( license.fullName, license.url ) of
                                        ( Nothing, Nothing ) ->
                                            Nothing

                                        ( Just fullName, Nothing ) ->
                                            Just (text fullName)

                                        ( Nothing, Just url ) ->
                                            Just (createShortDetailsItem "Unknown" url)

                                        ( Just fullName, Just url ) ->
                                            Just (createShortDetailsItem fullName url)
                                )
                            |> List.intersperse (text ", ")
                            |> (\x -> [ li [] (List.append [ text "Licenses: " ] x) ])
                        )
                    |> List.append
                        (if item.source.pversion == "" then
                            []

                         else
                            [ text "Version: "
                            , li [] [ text item.source.pversion ]
                            ]
                        )
                    |> List.append
                        [ text "Name: "
                        , li [] [ text item.source.pname ]
                        ]
                )

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
                    [ text <| Maybe.withDefault "" maintainer.name ++ (Maybe.withDefault "" <| Maybe.map (\email -> " <" ++ email ++ ">") maintainer.email) ]
                ]

        showPlatform platform =
            case Search.channelDetailsFromId channel of
                Just channelDetails ->
                    let
                        url =
                            "https://hydra.nixos.org/job/" ++ channelDetails.jobset ++ "/nixpkgs." ++ item.source.attr_name ++ "." ++ platform
                    in
                    li []
                        [ a
                            [ href url
                            ]
                            [ text platform ]
                        ]

                Nothing ->
                    li [] [ text platform ]

        maintainersAndPlatforms =
            [ div []
                [ div []
                    (List.append [ h4 [] [ text "Maintainers" ] ]
                        (if List.isEmpty item.source.maintainers then
                            [ p [] [ text "This package has no maintainers." ] ]

                         else
                            [ ul [] (List.map showMaintainer item.source.maintainers) ]
                        )
                    )
                , div []
                    (List.append [ h4 [] [ text "Platforms" ] ]
                        (if List.isEmpty item.source.platforms then
                            [ p [] [ text "This package is not available on any platform." ] ]

                         else
                            [ ul [] (List.map showPlatform item.source.platforms) ]
                        )
                    )
                ]
            ]

        longerPackageDetails =
            if Just item.source.attr_name == show then
                [ div [ trapClick ]
                    (maintainersAndPlatforms
                        |> List.append
                            (item.source.longDescription
                                |> Maybe.map (\desc -> [ p [] [ text desc ] ])
                                |> Maybe.withDefault []
                            )
                        |> List.append
                            [ div []
                                [ h4 []
                                    [ text "How to install "
                                    , em [] [ text item.source.attr_name ]
                                    , text "?"
                                    ]
                                , ul [ class "nav nav-tabs" ]
                                    [ li
                                        [ classList
                                            [ ( "active", showNixOSDetails )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowNixOSDetails True
                                            ]
                                            [ text "On NixOS" ]
                                        ]
                                    , li
                                        [ classList
                                            [ ( "active", not showNixOSDetails )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowNixOSDetails False
                                            ]
                                            [ text "On non-NixOS" ]
                                        ]
                                    ]
                                , div
                                    [ class "tab-content" ]
                                    [ div
                                        [ classList
                                            [ ( "active", not showNixOSDetails )
                                            ]
                                        , class "tab-pane"
                                        , id "package-details-nixpkgs"
                                        ]
                                        [ pre [ class "code-block" ]
                                            [ text "nix-env -iA nixpkgs."
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", showNixOSDetails )
                                            ]
                                        ]
                                        [ pre [ class "code-block" ]
                                            [ text <| "nix-env -iA nixos."
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                    )
                ]

            else
                []

        toggle =
            SearchMsg (Search.ShowDetails item.source.attr_name)

        trapClick =
            Html.Attributes.map SearchMsg Search.trapClick

        isOpen =
            Just item.source.attr_name == show
    in
    li
        [ class "package"
        , classList [ ( "opened", isOpen ) ]
        , Search.elementId item.source.attr_name
        ]
        ([]
            |> List.append longerPackageDetails
            |> List.append
                [ Html.a
                    [ class "search-result-button"
                    , onClick toggle
                    , href ""
                    ]
                    [ text item.source.attr_name ]
                , div [] [ text <| Maybe.withDefault "" item.source.description ]
                , shortPackageDetails
                , Search.showMoreButton toggle isOpen
                ]
        )


renderSource : Search.ResultItem ResultItemSource -> String -> Html.Attribute Msg -> (String -> String -> Html Msg) -> (String -> String -> String) -> List (Html Msg)
renderSource item channel trapClick createShortDetailsItem createGithubUrl =
    let
        postion =
            item.source.position
                |> Maybe.map
                    (\position ->
                        case Search.channelDetailsFromId channel of
                            Nothing ->
                                []

                            Just channelDetails ->
                                [ li [ trapClick ]
                                    [ createShortDetailsItem
                                        "Source"
                                        (createGithubUrl channelDetails.branch position)
                                    ]
                                ]
                    )

        flakeDef =
            Maybe.map2
                (\name resolved ->
                    [ li [ trapClick ]
                        [ createShortDetailsItem
                            ("Flake: " ++ name)
                            resolved
                        ]
                    ]
                )
                item.source.flakeName
                item.source.flakeUrl
    in
    Maybe.withDefault (Maybe.withDefault [] flakeDef) postion



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
makeRequest options _ channel query from size maybeBuckets sort =
    Search.makeRequest
        (makeRequestBody query from size maybeBuckets sort)
        ("latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ channel)
        decodeResultItemSource
        decodeResultAggregations
        options
        Search.QueryResponse
        (Just "query-packages")
        |> Cmd.map SearchMsg


makeRequestBody : String -> Int -> Int -> Maybe String -> Search.Sort -> Body
makeRequestBody query from size maybeBuckets sort =
    let
        currentBuckets =
            initBuckets maybeBuckets

        aggregations =
            [ ( "package_attr_set", currentBuckets.packageSets )
            , ( "package_license_set", currentBuckets.licenses )
            , ( "package_maintainers_set", currentBuckets.maintainers )
            , ( "package_platforms", currentBuckets.platforms )
            ]

        filterByBucket field value =
            [ ( "term"
              , Json.Encode.object
                    [ ( field
                      , Json.Encode.object
                            [ ( "value", Json.Encode.string value )
                            , ( "_name", Json.Encode.string <| "filter_bucket_" ++ field )
                            ]
                      )
                    ]
              )
            ]

        filterByBuckets =
            [ ( "bool"
              , Json.Encode.object
                    [ ( "must"
                      , Json.Encode.list Json.Encode.object
                            (List.map
                                (\( aggregation, buckets ) ->
                                    [ ( "bool"
                                      , Json.Encode.object
                                            [ ( "should"
                                              , Json.Encode.list Json.Encode.object <|
                                                    List.map
                                                        (filterByBucket aggregation)
                                                        buckets
                                              )
                                            ]
                                      )
                                    ]
                                )
                                aggregations
                            )
                      )
                    ]
              )
            ]
    in
    Search.makeRequestBody
        (String.trim query)
        from
        size
        sort
        "package"
        "package_attr_name"
        [ "package_pversion" ]
        [ "package_attr_set"
        , "package_license_set"
        , "package_maintainers_set"
        , "package_platforms"
        ]
        filterByBuckets
        "package_attr_name"
        [ ( "package_attr_name", 9.0 )
        , ( "package_pname", 6.0 )
        , ( "package_attr_name_query", 4.0 )
        , ( "package_description", 1.3 )
        , ( "package_longDescription", 1.0 )
        ]



-- JSON


encodeBuckets : Buckets -> Json.Encode.Value
encodeBuckets options =
    Json.Encode.object
        [ ( "package_attr_set", Json.Encode.list Json.Encode.string options.packageSets )
        , ( "package_license_set", Json.Encode.list Json.Encode.string options.licenses )
        , ( "package_maintainers_set", Json.Encode.list Json.Encode.string options.maintainers )
        , ( "package_platforms", Json.Encode.list Json.Encode.string options.platforms )
        ]


decodeBuckets : Json.Decode.Decoder Buckets
decodeBuckets =
    Json.Decode.map4 Buckets
        (Json.Decode.field "package_attr_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_license_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_maintainers_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_platforms" (Json.Decode.list Json.Decode.string))


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
        |> Json.Decode.Pipeline.required "package_homepage" decodeHomepage
        |> Json.Decode.Pipeline.required "package_system" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_hydra" (Json.Decode.nullable (Json.Decode.list decodeResultPackageHydra))
        |> Json.Decode.Pipeline.optional "flake_name" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_description" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_resolved" (Json.Decode.map Just decodeResolvedFlake) Nothing


decodeHomepage : Json.Decode.Decoder (List String)
decodeHomepage =
    Json.Decode.oneOf
        -- null becomes [] (empty list)
        [ Json.Decode.null []

        -- "foo" becomes ["foo"]
        , Json.Decode.map List.singleton Json.Decode.string

        -- arrays are decoded to list as expected
        , Json.Decode.list Json.Decode.string
        ]


decodeResultPackageLicense : Json.Decode.Decoder ResultPackageLicense
decodeResultPackageLicense =
    Json.Decode.map2 ResultPackageLicense
        (Json.Decode.field "fullName" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "url" (Json.Decode.nullable Json.Decode.string))


decodeResultPackageMaintainer : Json.Decode.Decoder ResultPackageMaintainer
decodeResultPackageMaintainer =
    Json.Decode.map3 ResultPackageMaintainer
        (Json.Decode.oneOf
            [ Json.Decode.field "name" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.field "email" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.field "github" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.succeed Nothing
            ]
        )
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


decodeResultAggregations : Json.Decode.Decoder ResultAggregations
decodeResultAggregations =
    Json.Decode.map5 ResultAggregations
        (Json.Decode.field "all" decodeAggregations)
        (Json.Decode.field "package_platforms" Search.decodeAggregation)
        (Json.Decode.field "package_attr_set" Search.decodeAggregation)
        (Json.Decode.field "package_maintainers_set" Search.decodeAggregation)
        (Json.Decode.field "package_license_set" Search.decodeAggregation)


decodeAggregations : Json.Decode.Decoder Aggregations
decodeAggregations =
    Json.Decode.map5 Aggregations
        (Json.Decode.field "doc_count" Json.Decode.int)
        (Json.Decode.field "package_platforms" Search.decodeAggregation)
        (Json.Decode.field "package_attr_set" Search.decodeAggregation)
        (Json.Decode.field "package_maintainers_set" Search.decodeAggregation)
        (Json.Decode.field "package_license_set" Search.decodeAggregation)
