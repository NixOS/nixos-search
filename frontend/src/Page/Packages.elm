module Page.Packages exposing
    ( Aggregations
    , Model
    , Msg(..)
    , ResultAggregations
    , ResultItemSource
    , ResultPackageHydra
    , ResultPackageHydraPath
    , ResultPackageLicense
    , ResultPackageMaintainer
    , ResultPackageTeam
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
        )
import Html.Events exposing (onClick)
import Http exposing (Body)
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import List.Extra
import Regex
import Route exposing (SearchType)
import Search
    exposing
        ( Details
        , NixOSChannel
        , viewBucket
        )
import Utils



-- MODEL


type alias Model =
    Search.Model ResultItemSource ResultAggregations


type alias ResultItemSource =
    { attr_name : String
    , pname : String
    , pversion : String
    , outputs : List String
    , default_output : Maybe String
    , programs : List String
    , mainProgram : Maybe String
    , description : Maybe String
    , longDescription : Maybe String
    , licenses : List ResultPackageLicense
    , maintainers : List ResultPackageMaintainer
    , teams : List ResultPackageTeam
    , platforms : List String
    , position : Maybe String
    , homepage : List String
    , system : String
    , hydra : Maybe (List ResultPackageHydra)
    , flakeName : Maybe String
    , flakeDescription : Maybe String
    , flakeUrl : Maybe ( String, String )
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


type alias ResultPackageTeam =
    { members : Maybe (List ResultPackageMaintainer)
    , scope : Maybe String
    , shortName : String
    , githubTeams : Maybe (List String)
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
    , package_teams_set : Search.Aggregation
    , package_license_set : Search.Aggregation
    }


type alias Aggregations =
    { doc_count : Int
    , package_platforms : Search.Aggregation
    , package_attr_set : Search.Aggregation
    , package_maintainers_set : Search.Aggregation
    , package_teams_set : Search.Aggregation
    , package_license_set : Search.Aggregation
    }


type alias Buckets =
    { packageSets : List String
    , licenses : List String
    , maintainers : List String
    , teams : List String
    , platforms : List String
    }


emptyBuckets : Buckets
emptyBuckets =
    { packageSets = []
    , licenses = []
    , maintainers = []
    , teams = []
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


platforms : List String
platforms =
    [ "x86_64-linux"
    , "aarch64-linux"
    , "i686-linux"
    , "x86_64-darwin"
    , "aarch64-darwin"
    ]



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
                        Route.Packages
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
    Search.view { categoryName = "packages" }
        [ text "Search more than "
        , strong [] [ text "120 000 packages" ]
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
            "Teams"
            (result.aggregations.package_teams_set.buckets |> sortBuckets)
            (createBucketsMsg .teams (\s v -> { s | teams = v }))
            selectedBucket.teams
        |> viewBucket
            "Platforms"
            (result.aggregations.package_platforms.buckets |> sortBuckets |> filterPlatformsBucket)
            (createBucketsMsg .platforms (\s v -> { s | platforms = v }))
            selectedBucket.platforms


filterPlatformsBucket : List { a | key : String } -> List { a | key : String }
filterPlatformsBucket =
    List.filter (\a -> List.member a.key platforms)


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
viewResultItem nixosChannels channel showInstallDetails show item =
    let
        optionals b l =
            if b then
                l

            else
                []

        cleanRegex =
            Regex.fromString "^[0-9a-f]+\\.tar\\.gz\\/"
                |> Maybe.withDefault Regex.never

        cleanPosition =
            Regex.replace cleanRegex (\_ -> "")

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
                (li []
                    [ text "Name: "
                    , code [ class "package-name" ] [ text item.source.pname ]
                    ]
                    :: (optionals (not (String.isEmpty item.source.pversion))
                            [ li []
                                [ text "Version: "
                                , strong [] [ text item.source.pversion ]
                                ]
                            ]
                            ++ optionals (List.length item.source.outputs > 1)
                                [ li []
                                    (text "Outputs: "
                                        :: (item.source.default_output
                                                |> Maybe.map (\d -> [ strong [] [ code [] [ text d ] ], text " " ])
                                                |> Maybe.withDefault []
                                           )
                                        ++ (item.source.outputs
                                                |> List.filter (\o -> Just o /= item.source.default_output)
                                                |> List.sort
                                                |> List.map (\o -> code [] [ text o ])
                                                |> List.intersperse (text " ")
                                           )
                                    )
                                ]
                            ++ (item.source.homepage
                                    |> List.head
                                    |> Maybe.map
                                        (\x ->
                                            [ li [ trapClick ]
                                                [ createShortDetailsItem "🌐 Homepage" x ]
                                            ]
                                        )
                                    |> Maybe.withDefault []
                               )
                            ++ renderSource item nixosChannels channel trapClick createShortDetailsItem createGithubUrl
                            ++ (let
                                    licenses =
                                        item.source.licenses
                                            |> List.filterMap
                                                (\license ->
                                                    case license.url of
                                                        Nothing ->
                                                            Maybe.map text license.fullName

                                                        Just url ->
                                                            Just
                                                                (createShortDetailsItem
                                                                    (Maybe.withDefault "Unknown" license.fullName)
                                                                    url
                                                                )
                                                )
                                in
                                optionals (not (List.isEmpty licenses))
                                    [ li []
                                        (text
                                            (if List.length licenses == 1 then
                                                "License: "

                                             else
                                                "Licenses: "
                                            )
                                            :: List.intersperse (text " ▪ ") licenses
                                        )
                                    ]
                               )
                       )
                )

        showMaintainer maintainer =
            let
                nameLink : Html msg
                nameLink =
                    case maintainer.github of
                        Just github ->
                            a
                                [ href ("https://github.com/" ++ github) ]
                                [ text (Maybe.withDefault github maintainer.name) ]

                        Nothing ->
                            text (Maybe.withDefault "Unknown" maintainer.name)

                emailLink : List (Html msg)
                emailLink =
                    case maintainer.email of
                        Just email ->
                            [ text " <"
                            , a [ href ("mailto:" ++ email) ] [ text email ]
                            , text ">"
                            ]

                        Nothing ->
                            []
            in
            li [] (nameLink :: emailLink)

        linkAllMaintainers maintainers =
            let
                ghHandles =
                    List.filterMap (\m -> Maybe.map (String.append "@") m.github) maintainers
            in
            optionals (not (List.isEmpty ghHandles))
                [ li []
                    [ text "Maintainer Github handles: "
                    , code []
                        [ text (String.join " " ghHandles) ]
                    ]
                ]

        showTeam team =
            let
                showTeamEntry githubTeam =
                    [ text " "
                    , a
                        [ href (String.append "https://github.com/orgs/NixOS/teams/" githubTeam) ]
                        [ text ("@NixOS/" ++ githubTeam) ]
                    ]

                scope : List (Html msg)
                scope =
                    case Maybe.withDefault "" team.scope of
                        "" ->
                            []

                        nonEmptyScope ->
                            [ ul []
                                [ li []
                                    [ em [] [ text nonEmptyScope ] ]
                                ]
                            ]
            in
            li [] <|
                case Maybe.withDefault [] team.githubTeams of
                    [] ->
                        text team.shortName :: scope

                    githubTeams ->
                        text (team.shortName ++ ":")
                            :: List.concatMap showTeamEntry githubTeams
                            ++ scope

        mailtoAllMaintainers maintainers =
            let
                maintainerMails =
                    List.filterMap (\m -> m.email) maintainers
            in
            optionals (List.length maintainerMails > 1)
                [ li []
                    [ a
                        [ href ("mailto:" ++ String.join "," maintainerMails) ]
                        [ text "✉️ Mail to all maintainers" ]
                    ]
                ]

        showPlatform platform =
            case List.Extra.find (\x -> x.id == channel) nixosChannels of
                Just channelDetails ->
                    let
                        url =
                            "https://hydra.nixos.org/job/" ++ channelDetails.jobset ++ "/nixpkgs." ++ item.source.attr_name ++ "." ++ platform
                    in
                    li [] [ a [ href url ] [ text platform ] ]

                Nothing ->
                    li [] [ text platform ]

        maintainersTeamsAndPlatforms =
            div []
                [ div []
                    [ h4 [] [ text "Maintainers" ]
                    , if List.isEmpty item.source.maintainers then
                        p [] [ text "This package has no maintainers. If you find it useful, please consider becoming a maintainer!" ]

                      else
                        ul []
                            (List.map showMaintainer item.source.maintainers
                                ++ mailtoAllMaintainers item.source.maintainers
                                ++ linkAllMaintainers item.source.maintainers
                            )
                    ]
                , div []
                    (optionals (not (List.isEmpty item.source.teams))
                        [ h4 [] [ text "Teams" ]
                        , ul [] (List.map showTeam item.source.teams)
                        ]
                    )
                , div []
                    [ h4 [] [ text "Platforms" ]
                    , if List.isEmpty item.source.platforms then
                        p [] [ text "This package does not list its available platforms." ]

                      else
                        ul [] (List.map showPlatform (List.sort item.source.platforms))
                    ]
                ]

        programs =
            div []
                [ h4 [] [ text "Programs provided" ]
                , if List.isEmpty item.source.programs then
                    case item.source.mainProgram of
                        Nothing ->
                            p [] [ text "This package provides no programs." ]

                        Just mainProgram ->
                            p []
                                [ p [] [ text "Only the main program of this package is known: " ]
                                , code [] [ strong [] [ text mainProgram ] ]
                                ]

                  else
                    p []
                        (List.intersperse (text " ")
                            (List.map
                                (\p ->
                                    code []
                                        [ case item.source.mainProgram of
                                            Nothing ->
                                                text p

                                            Just mainProgram ->
                                                if p == mainProgram then
                                                    strong [] [ text p ]

                                                else
                                                    text p
                                        ]
                                )
                                (List.sort item.source.programs)
                            )
                        )
                ]

        longerPackageDetails =
            optionals (Just item.source.attr_name == show)
                [ div [ trapClick ]
                    [ div []
                        (item.source.longDescription
                            |> Maybe.andThen Utils.showHtml
                            |> Maybe.withDefault []
                        )
                    , case item.source.flakeUrl of
                        Just ( flakeUrl, _ ) ->
                            div []
                                [ h4 []
                                    [ text "How to install "
                                    , em [] [ text item.source.attr_name ]
                                    , text "?"
                                    ]
                                , ul [ class "nav nav-tabs" ] <|
                                    [ li
                                        [ classList
                                            [ ( "active", True )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowInstallDetails Search.FromFlake
                                            ]
                                            [ text "Install from flake" ]
                                        ]
                                    ]
                                , div
                                    [ class "tab-content" ]
                                    [ div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", True )
                                            ]
                                        ]
                                        [ pre [ class "code-block shell-command" ]
                                            [ text "nix profile add "
                                            , strong [] [ text flakeUrl ]
                                            , text "#"
                                            , em [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    ]
                                ]

                        Nothing ->
                            div []
                                [ h4 []
                                    [ text "How to install "
                                    , em [] [ text item.source.attr_name ]
                                    , text "?"
                                    ]
                                , ul [ class "nav nav-tabs" ] <|
                                    [ li
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixEnv )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , class "deprecated"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowInstallDetails Search.ViaNixEnv
                                            ]
                                            [ text "nix-env" ]
                                        ]
                                    , li
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixProfile )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowInstallDetails Search.ViaNixProfile
                                            ]
                                            [ text "nix profile" ]
                                        ]
                                    , li
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixOS )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowInstallDetails Search.ViaNixOS
                                            ]
                                            [ text "NixOS Configuration" ]
                                        ]
                                    , li
                                        [ classList
                                            [ ( "active", List.member showInstallDetails [ Search.Unset, Search.ViaNixShell, Search.FromFlake ] )
                                            , ( "pull-right", True )
                                            ]
                                        ]
                                        [ a
                                            [ href "#"
                                            , Search.onClickStop <|
                                                SearchMsg <|
                                                    Search.ShowInstallDetails Search.ViaNixShell
                                            ]
                                            [ text "nix-shell" ]
                                        ]
                                    ]
                                , div
                                    [ class "tab-content" ]
                                    [ div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", showInstallDetails == Search.ViaNixEnv )
                                            ]
                                        ]
                                        [ p []
                                            [ strong [] [ text "Warning:" ]
                                            , text " Using "
                                            , code [] [ text "nix-env" ]
                                            , text """
                                            permanently modifies a local profile of installed packages.
                                            This must be updated and maintained by the user in the same
                                            way as with a traditional package manager, foregoing many
                                            of the benefits that make Nix uniquely powerful. Using
                                            """
                                            , code [] [ text "nix-shell" ]
                                            , text """
                                            or a NixOS configuration is recommended instead.
                                            """
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixEnv )
                                            ]
                                        , class "tab-pane"
                                        ]
                                        [ p []
                                            [ strong [] [ text "On NixOS:" ] ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixEnv )
                                            ]
                                        , class "tab-pane"
                                        , id "package-details-nixpkgs"
                                        ]
                                        [ pre [ class "code-block shell-command" ]
                                            [ text "nix-env -iA nixos."
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    , div [] [ p [] [] ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixEnv )
                                            ]
                                        , class "tab-pane"
                                        ]
                                        [ p []
                                            [ strong [] [ text "On Non NixOS:" ] ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixEnv )
                                            ]
                                        , class "tab-pane"
                                        , id "package-details-nixpkgs"
                                        ]
                                        [ pre [ class "code-block shell-command" ]
                                            [ text "# without flakes:\nnix-env -iA nixpkgs."
                                            , strong [] [ text item.source.attr_name ]
                                            , text "\n# with flakes:\nnix profile add nixpkgs#"
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", showInstallDetails == Search.ViaNixOS )
                                            ]
                                        ]
                                        [ p []
                                            [ text "Add the following Nix code to your NixOS Configuration, usually located in "
                                            , strong [] [ text "/etc/nixos/configuration.nix" ]
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixOS )
                                            ]
                                        , class "tab-pane"
                                        , id "package-details-nixpkgs"
                                        ]
                                        [ pre [ class "code-block" ]
                                            [ text <| "  environment.systemPackages = [\n    pkgs."
                                            , strong [] [ text item.source.attr_name ]
                                            , text <| "\n  ];"
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", List.member showInstallDetails [ Search.Unset, Search.ViaNixShell, Search.FromFlake ] )
                                            ]
                                        ]
                                        [ p []
                                            [ text """
                                            A nix-shell will temporarily modify
                                            your $PATH environment variable.
                                            This can be used to try a piece of
                                            software before deciding to
                                            permanently install it.
                                          """
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "tab-pane", True )
                                            , ( "active", List.member showInstallDetails [ Search.Unset, Search.ViaNixShell, Search.FromFlake ] )
                                            ]
                                        ]
                                        [ pre [ class "code-block shell-command" ]
                                            [ text "nix-shell -p "
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    , div
                                        [ classList
                                            [ ( "active", showInstallDetails == Search.ViaNixProfile )
                                            ]
                                        , class "tab-pane"
                                        , id "package-details-nixpkgs"
                                        ]
                                        [ pre [ class "code-block shell-command" ]
                                            [ text "nix profile add nixpkgs#"
                                            , strong [] [ text item.source.attr_name ]
                                            ]
                                        ]
                                    ]
                                ]
                    , programs
                    , maintainersTeamsAndPlatforms
                    ]
                ]

        toggle =
            SearchMsg (Search.ShowDetails item.source.attr_name)

        trapClick =
            Html.Attributes.map SearchMsg Search.trapClick

        isOpen =
            Just item.source.attr_name == show

        flakeOrNixpkgs =
            case ( item.source.flakeName, item.source.flakeUrl ) of
                -- its a flake
                ( Just _, Just ( flakeIdent, flakeUrl ) ) ->
                    [ a [ href flakeUrl ] [ text flakeIdent ]
                    , text "#"
                    , a
                        [ onClick toggle
                        , href ""
                        ]
                        [ text item.source.attr_name ]
                    ]

                _ ->
                    [ a
                        [ onClick toggle
                        , href ""
                        ]
                        [ text item.source.attr_name ]
                    ]
    in
    li
        [ class "package"
        , classList [ ( "opened", isOpen ) ]
        , Search.elementId item.source.attr_name
        ]
        ([ span [] flakeOrNixpkgs
         , div [] [ text <| Maybe.withDefault "" item.source.description ]
         , shortPackageDetails
         , Search.showMoreButton toggle isOpen
         ]
            ++ longerPackageDetails
        )


renderSource :
    Search.ResultItem ResultItemSource
    -> List NixOSChannel
    -> String
    -> Html.Attribute Msg
    ->
        (String
         -> String
         -> Html Msg
        )
    ->
        (String
         -> String
         -> String
        )
    -> List (Html Msg)
renderSource item nixosChannels channel trapClick createShortDetailsItem createGithubUrl =
    let
        makeLink : String -> String -> List (Html Msg)
        makeLink text url =
            [ li [ trapClick ] [ createShortDetailsItem text url ] ]
    in
    case item.source.position of
        Just pos ->
            case List.Extra.find (\x -> x.id == channel) nixosChannels of
                Just channelDetails ->
                    makeLink "📦 Source" (createGithubUrl channelDetails.branch pos)

                Nothing ->
                    []

        Nothing ->
            case ( item.source.flakeName, item.source.flakeUrl ) of
                ( Just flakeName, Just ( _, flakeUrl ) ) ->
                    makeLink ("Flake: " ++ flakeName) flakeUrl

                _ ->
                    []



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
makeRequest options nixosChannels _ channel query from size maybeBuckets sort =
    Search.makeRequest
        (makeRequestBody query from size maybeBuckets sort)
        nixosChannels
        channel
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
            , ( "package_teams_set", currentBuckets.teams )
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
        , "package_teams_set"
        , "package_platforms"
        ]
        filterByBuckets
        "package_attr_name"
        [ ( "package_attr_name", 9.0 )
        , ( "package_programs", 9.0 )
        , ( "package_pname", 6.0 )
        , ( "package_description", 1.3 )
        , ( "package_longDescription", 1.0 )
        , ( "flake_name", 0.5 )
        ]



-- JSON


encodeBuckets : Buckets -> Json.Encode.Value
encodeBuckets options =
    Json.Encode.object
        [ ( "package_attr_set", Json.Encode.list Json.Encode.string options.packageSets )
        , ( "package_license_set", Json.Encode.list Json.Encode.string options.licenses )
        , ( "package_maintainers_set", Json.Encode.list Json.Encode.string options.maintainers )
        , ( "package_teams_set", Json.Encode.list Json.Encode.string options.teams )
        , ( "package_platforms", Json.Encode.list Json.Encode.string options.platforms )
        ]


decodeBuckets : Json.Decode.Decoder Buckets
decodeBuckets =
    Json.Decode.map5 Buckets
        (Json.Decode.field "package_attr_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_license_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_maintainers_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_teams_set" (Json.Decode.list Json.Decode.string))
        (Json.Decode.field "package_platforms" (Json.Decode.list Json.Decode.string))


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.succeed ResultItemSource
        |> Json.Decode.Pipeline.required "package_attr_name" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_pname" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_pversion" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_outputs" (Json.Decode.list Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_default_output" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_programs" (Json.Decode.list Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_mainProgram" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_description" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_longDescription" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_license" (Json.Decode.list decodeResultPackageLicense)
        |> Json.Decode.Pipeline.required "package_maintainers" (Json.Decode.list decodeResultPackageMaintainer)
        |> Json.Decode.Pipeline.required "package_teams" (Json.Decode.list decodeResultPackageTeam)
        |> Json.Decode.Pipeline.required "package_platforms" (Json.Decode.map filterPlatforms (Json.Decode.list Json.Decode.string))
        |> Json.Decode.Pipeline.required "package_position" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "package_homepage" decodeHomepage
        |> Json.Decode.Pipeline.required "package_system" Json.Decode.string
        |> Json.Decode.Pipeline.required "package_hydra" (Json.Decode.nullable (Json.Decode.list decodeResultPackageHydra))
        |> Json.Decode.Pipeline.optional "flake_name" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_description" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_resolved" (Json.Decode.map Just decodeResolvedFlake) Nothing


type alias ResolvedFlake =
    { type_ : String
    , owner : Maybe String
    , repo : Maybe String
    , url : Maybe String
    }


decodeResolvedFlake : Json.Decode.Decoder ( String, String )
decodeResolvedFlake =
    let
        resolved : Json.Decode.Decoder ResolvedFlake
        resolved =
            Json.Decode.succeed ResolvedFlake
                |> Json.Decode.Pipeline.required "type" Json.Decode.string
                |> Json.Decode.Pipeline.optional "owner" (Json.Decode.map Just Json.Decode.string) Nothing
                |> Json.Decode.Pipeline.optional "repo" (Json.Decode.map Just Json.Decode.string) Nothing
                |> Json.Decode.Pipeline.optional "url" (Json.Decode.map Just Json.Decode.string) Nothing
    in
    Json.Decode.map
        (\resolved_ ->
            let
                invalid : String
                invalid =
                    "INVALID FLAKE ORIGIN"
            in
            if resolved_.type_ == "git" then
                let
                    url : String
                    url =
                        Maybe.withDefault invalid resolved_.url
                in
                ( url, url )

            else
                case ( resolved_.owner, resolved_.repo ) of
                    ( Just owner, Just repo ) ->
                        let
                            repoPath : String
                            repoPath =
                                owner ++ "/" ++ repo
                        in
                        case resolved_.type_ of
                            "github" ->
                                ( "github:" ++ repoPath, "https://github.com/" ++ repoPath )

                            "gitlab" ->
                                ( "gitlab:" ++ repoPath, "https://gitlab.com/" ++ repoPath )

                            "sourcehut" ->
                                ( "sourcehut:" ++ repoPath, "https://sr.ht/" ++ repoPath )

                            _ ->
                                ( invalid, invalid )

                    _ ->
                        ( invalid, invalid )
        )
        resolved


filterPlatforms : List String -> List String
filterPlatforms =
    let
        flip : (a -> b -> c) -> b -> a -> c
        flip function argB argA =
            function argA argB
    in
    List.filter (flip List.member platforms)


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


decodeResultPackageTeam : Json.Decode.Decoder ResultPackageTeam
decodeResultPackageTeam =
    Json.Decode.map4 ResultPackageTeam
        (Json.Decode.field "members" (Json.Decode.nullable (Json.Decode.list decodeResultPackageMaintainer)))
        (Json.Decode.field "scope" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "shortName" Json.Decode.string)
        (Json.Decode.field "githubTeams" (Json.Decode.nullable (Json.Decode.list Json.Decode.string)))


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
    Json.Decode.map6 ResultAggregations
        (Json.Decode.field "all" decodeAggregations)
        (Json.Decode.field "package_platforms" Search.decodeAggregation)
        (Json.Decode.field "package_attr_set" Search.decodeAggregation)
        (Json.Decode.field "package_maintainers_set" Search.decodeAggregation)
        (Json.Decode.field "package_teams_set" Search.decodeAggregation)
        (Json.Decode.field "package_license_set" Search.decodeAggregation)


decodeAggregations : Json.Decode.Decoder Aggregations
decodeAggregations =
    Json.Decode.map6 Aggregations
        (Json.Decode.field "doc_count" Json.Decode.int)
        (Json.Decode.field "package_platforms" Search.decodeAggregation)
        (Json.Decode.field "package_attr_set" Search.decodeAggregation)
        (Json.Decode.field "package_maintainers_set" Search.decodeAggregation)
        (Json.Decode.field "package_teams_set" Search.decodeAggregation)
        (Json.Decode.field "package_license_set" Search.decodeAggregation)
