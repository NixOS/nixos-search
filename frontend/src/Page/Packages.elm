module Page.Packages exposing
    ( Aggregations
    , LicenseExpression
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
    , encodeRequestBody
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
        , fieldset
        , h4
        , input
        , label
        , legend
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
        ( checked
        , class
        , classList
        , href
        , id
        , name
        , target
        , title
        , type_
        )
import Html.Events exposing (onClick)
import Http exposing (Body)
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import List.Extra
import Ports
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
    , licenseExpression : Maybe LicenseExpression
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
    , modularServices : List String
    }


type alias ResultPackageLicense =
    { fullName : Maybe String
    , shortName : Maybe String
    , spdxId : Maybe String
    , url : Maybe String
    }


{-| Structured license expression tree mirroring the compound-license
operators introduced in NixOS/nixpkgs#468378. AND licenses must all be
satisfied; OR licenses offer a choice; WITH applies an exception; PLUS is
"or any later version".
-}
type LicenseExpression
    = LicenseLeaf
        { fullName : Maybe String
        , shortName : Maybe String
        , spdxId : Maybe String
        , url : Maybe String
        }
    | LicenseAnd (List LicenseExpression)
    | LicenseOr (List LicenseExpression)
    | LicenseWith LicenseExpression LicenseExpression
    | LicensePlus LicenseExpression


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
    Search.Options
    -> Bool
    -> Route.SearchArgs
    -> String
    -> List NixOSChannel
    -> Bool
    -> Maybe Model
    -> ( Model, Cmd Msg )
init options preferStatic searchArgs defaultNixOSChannel nixosChannels includeChannelInUrl model =
    let
        searchArgsForPackages =
            { searchArgs | type_ = Just Route.PackageSearch }

        ( newModel, newCmd ) =
            Search.init options preferStatic searchArgsForPackages defaultNixOSChannel nixosChannels model

        finalModel =
            if includeChannelInUrl then
                { newModel | urlChannel = Just newModel.channel }

            else
                newModel
    in
    ( finalModel
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
    | CopyToClipboard String


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

        CopyToClipboard text_ ->
            ( model, Ports.copyToClipboard text_ )



-- VIEW


view :
    List NixOSChannel
    -> Model
    -> Html Msg
view nixosChannels model =
    Search.view { categoryName = "packages" }
        [ text "Search more than "
        , strong [] [ text "140 000 packages" ]
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

        createBucketsMsg isRadio getBucket mergeBuckets value =
            (if isRadio then
                if getBucket initialBuckets == [ value ] then
                    []

                else
                    [ value ]

             else
                Utils.toggleList (getBucket initialBuckets) value
            )
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
            Search.RadioInput
            "Package sets"
            (result.aggregations.package_attr_set.buckets |> sortBuckets)
            (createBucketsMsg True .packageSets (\s v -> { s | packageSets = v }))
            selectedBucket.packageSets
        |> viewBucket
            Search.CheckboxInput
            "Licenses"
            (result.aggregations.package_license_set.buckets |> sortBuckets)
            (createBucketsMsg False .licenses (\s v -> { s | licenses = v }))
            selectedBucket.licenses
        |> viewBucket
            Search.CheckboxInput
            "Maintainers"
            (result.aggregations.package_maintainers_set.buckets |> sortBuckets)
            (createBucketsMsg False .maintainers (\s v -> { s | maintainers = v }))
            selectedBucket.maintainers
        |> viewBucket
            Search.CheckboxInput
            "Teams"
            (result.aggregations.package_teams_set.buckets |> sortBuckets)
            (createBucketsMsg False .teams (\s v -> { s | teams = v }))
            selectedBucket.teams
        |> viewBucket
            Search.CheckboxInput
            "Platforms"
            (result.aggregations.package_platforms.buckets |> sortBuckets)
            (createBucketsMsg False .platforms (\s v -> { s | platforms = v }))
            selectedBucket.platforms


viewSuccess :
    List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> List (Search.ResultItem ResultItemSource)
    -> Html Msg
viewSuccess nixosChannels channel showUsageDetails show hits =
    ul []
        (List.map
            (viewResultItem nixosChannels channel showUsageDetails show)
            hits
        )


{-| Render an install command or configuration snippet together with a
button that copies its plain-text form to the clipboard. The package name
inside the snippet is rendered in bold, so the exact text to copy is passed
separately from the displayed content.
-}
copyableCommand : String -> String -> List (Html Msg) -> Html Msg
copyableCommand preClass commandText content =
    Utils.copyable CopyToClipboard commandText (pre [ class preClass ] content)


viewResultItem :
    List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItem nixosChannels channel showUsageDetails show item =
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
                                    [ text "Outputs: "
                                    , inlineListCode
                                        ((item.source.default_output
                                            |> Maybe.map (\d -> strong [] [ text d ])
                                            |> Maybe.map List.singleton
                                            |> Maybe.withDefault []
                                         )
                                            ++ (item.source.outputs
                                                    |> List.filter (\o -> Just o /= item.source.default_output)
                                                    |> List.sort
                                                    |> List.map (\o -> text o)
                                               )
                                        )
                                    ]
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
                            ++ (case item.source.licenseExpression of
                                    Just expression ->
                                        [ li []
                                            (text "License: "
                                                :: renderLicenseExpression expression
                                            )
                                        ]

                                    Nothing ->
                                        let
                                            licenses =
                                                item.source.licenses
                                                    |> List.map renderLicenseLeaf
                                        in
                                        optionals (not (List.isEmpty licenses))
                                            [ li []
                                                [ text "License: "
                                                , inlineListCode licenses
                                                ]
                                            ]
                               )
                       )
                )

        showMaintainer maintainer =
            let
                githubHandle =
                    Maybe.map (String.append "@") maintainer.github

                name =
                    Maybe.withDefault (Maybe.withDefault "Unknown" maintainer.github) maintainer.name

                nameHtml =
                    case maintainer.github of
                        Just github ->
                            a [ href ("https://github.com/" ++ github) ] [ text name ]

                        Nothing ->
                            text name

                githubHtml =
                    case githubHandle of
                        Just handle ->
                            [ text " ("
                            , code [] [ text handle ]
                            , text ")"
                            ]

                        Nothing ->
                            []

                emailHtml =
                    case maintainer.email of
                        Just email ->
                            [ text " <"
                            , a [ href ("mailto:" ++ email) ] [ text email ]
                            , text ">"
                            ]

                        Nothing ->
                            []

                ( onClickAttr, _ ) =
                    case githubHandle of
                        Just handle ->
                            ( [ onClick (CopyToClipboard handle) ], [] )

                        Nothing ->
                            ( [], [] )
            in
            li (class "maintainer-list-item" :: onClickAttr) (nameHtml :: githubHtml ++ emailHtml)

        linkAllMaintainers maintainers =
            let
                ghHandles =
                    List.filterMap (\m -> Maybe.map (String.append "@") m.github) maintainers
            in
            optionals (not (List.isEmpty ghHandles))
                [ li [ class "maintainer-list-item", onClick (CopyToClipboard (String.join " " ghHandles)) ]
                    [ text "Copy all maintainers' GitHub handles" ]
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
                [ a
                    [ href ("mailto:" ++ String.join "," maintainerMails) ]
                    [ li [ class "maintainer-list-item" ]
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
            let
                sortedPrograms =
                    case item.source.mainProgram of
                        Just mp ->
                            mp :: (item.source.programs |> List.filter (\p -> p /= mp) |> List.sort)

                        Nothing ->
                            List.sort item.source.programs

                renderOne p =
                    if Just p == item.source.mainProgram then
                        strong [] [ text p ]

                    else
                        text p
            in
            div []
                [ h4 [] [ text "Programs provided" ]
                , if List.isEmpty sortedPrograms then
                    p [] [ text "This package provides no programs." ]

                  else if List.isEmpty item.source.programs then
                    let
                        mp =
                            Maybe.withDefault "" item.source.mainProgram
                    in
                    p []
                        [ p [] [ text "Only the main program of this package is known: " ]
                        , withCopyableCode "main-program" mp (renderOne mp)
                        ]

                  else
                    inlineListElementsCopyableCode
                        (\p ->
                            if Just p == item.source.mainProgram then
                                "main-program"

                            else
                                ""
                        )
                        identity
                        renderOne
                        sortedPrograms
                ]

        optionsLink =
            let
                searchLink heading label term url =
                    div []
                        [ h4 [] [ text heading ]
                        , p []
                            [ a [ href url ]
                                [ text label
                                , em [] [ text term ]
                                ]
                            ]
                        ]
            in
            case item.source.flakeUrl of
                Nothing ->
                    searchLink "NixOS options"
                        "Search NixOS options for "
                        item.source.attr_name
                        ("/options?channel=" ++ channel ++ "&query=" ++ item.source.attr_name)

                Just ( flakeRef, _ ) ->
                    let
                        repoName =
                            flakeRef
                                |> String.split "/"
                                |> List.filter (\segment -> not (String.isEmpty segment))
                                |> List.reverse
                                |> List.head
                                |> Maybe.withDefault item.source.attr_name

                        term =
                            if item.source.attr_name == "default" && String.contains "/" flakeRef then
                                repoName

                            else
                                item.source.attr_name
                    in
                    searchLink "Flake options"
                        "Search flake options for "
                        term
                        ("/flakes?type=options&query=" ++ term)

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
                                [ fieldset
                                    [ class "radio-group-tabs usage-radios" ]
                                    [ legend [ class "usage-title" ]
                                        [ text "Usage" ]
                                    , div [ class "radio-tabs-list" ]
                                        [ label
                                            [ class "usage-radio active" ]
                                            [ text "Install from flake"
                                            , input
                                                [ type_ "radio"
                                                , name ("usage-method-" ++ item.source.attr_name)
                                                , checked True
                                                ]
                                                []
                                            ]
                                        ]
                                    ]
                                , div
                                    [ class "tab-content" ]
                                    [ copyableCommand "code-block shell-command"
                                        ("nix profile add " ++ flakeUrl ++ "#" ++ item.source.attr_name)
                                        [ text "nix profile add "
                                        , strong [] [ text flakeUrl ]
                                        , text "#"
                                        , em [] [ text item.source.attr_name ]
                                        ]
                                    ]
                                ]

                        Nothing ->
                            let
                                currentMethod =
                                    if showUsageDetails == Search.Unset then
                                        Search.ViaNixShell

                                    else
                                        showUsageDetails

                                methods =
                                    [ ( Search.ViaNixShell, "nix-shell", False )
                                    , ( Search.ViaNixOS, "NixOS Configuration", False )
                                    , ( Search.ViaNixProfile, "nix profile", False )
                                    , ( Search.ViaNixEnv, "nix-env", True )
                                    ]
                            in
                            div []
                                [ fieldset
                                    [ class "radio-group-tabs usage-radios" ]
                                    [ legend [ class "usage-title" ]
                                        [ text "Usage" ]
                                    , div [ class "radio-tabs-list" ]
                                        (List.map
                                            (\( method, labelText, isDeprecated ) ->
                                                let
                                                    isActive =
                                                        currentMethod == method
                                                in
                                                label
                                                    [ classList
                                                        [ ( "usage-radio", True )
                                                        , ( "active", isActive )
                                                        , ( "deprecated", isDeprecated )
                                                        ]
                                                    ]
                                                    [ text labelText
                                                    , input
                                                        [ type_ "radio"
                                                        , name ("usage-method-" ++ item.source.attr_name)
                                                        , checked isActive
                                                        , onClick <| SearchMsg <| Search.ShowUsageDetails method
                                                        ]
                                                        []
                                                    ]
                                            )
                                            methods
                                        )
                                    ]
                                , div
                                    [ class "tab-content" ]
                                    (case currentMethod of
                                        Search.ViaNixEnv ->
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
                                            , p [] [ strong [] [ text "On NixOS:" ] ]
                                            , copyableCommand "code-block shell-command"
                                                ("nix-env -iA nixos." ++ item.source.attr_name)
                                                [ text "nix-env -iA nixos."
                                                , strong [] [ text item.source.attr_name ]
                                                ]
                                            , p [] []
                                            , p [] [ strong [] [ text "On Non NixOS:" ] ]
                                            , copyableCommand "code-block shell-command"
                                                ("# without flakes:\nnix-env -iA nixpkgs." ++ item.source.attr_name ++ "\n# with flakes:\nnix profile add nixpkgs#" ++ item.source.attr_name)
                                                [ text "# without flakes:\nnix-env -iA nixpkgs."
                                                , strong [] [ text item.source.attr_name ]
                                                , text "\n# with flakes:\nnix profile add nixpkgs#"
                                                , strong [] [ text item.source.attr_name ]
                                                ]
                                            ]

                                        Search.ViaNixOS ->
                                            [ p []
                                                [ text "Add the following Nix code to your NixOS Configuration, usually located in "
                                                , strong [] [ text "/etc/nixos/configuration.nix" ]
                                                ]
                                            , copyableCommand "code-block"
                                                ("  environment.systemPackages = [\n    pkgs." ++ item.source.attr_name ++ "\n  ];")
                                                [ text <| "  environment.systemPackages = [\n    pkgs."
                                                , strong [] [ text item.source.attr_name ]
                                                , text <| "\n  ];"
                                                ]
                                            ]

                                        Search.ViaNixProfile ->
                                            [ copyableCommand "code-block shell-command"
                                                ("nix profile add nixpkgs#" ++ item.source.attr_name)
                                                [ text "nix profile add nixpkgs#"
                                                , strong [] [ text item.source.attr_name ]
                                                ]
                                            ]

                                        _ ->
                                            [ p []
                                                [ text """
                                                A nix-shell will temporarily modify
                                                your $PATH environment variable.
                                                This can be used to try a piece of
                                                software before deciding to
                                                permanently install it.
                                              """
                                                ]
                                            , copyableCommand "code-block shell-command"
                                                ("nix-shell -p " ++ item.source.attr_name)
                                                [ text "nix-shell -p "
                                                , strong [] [ text item.source.attr_name ]
                                                ]
                                            ]
                                    )
                                ]
                    , programs
                    , maintainersTeamsAndPlatforms
                    , optionsLink
                    , if List.isEmpty item.source.modularServices then
                        text ""

                      else
                        div []
                            [ h4 []
                                [ text "Modular Services"
                                , text " "
                                , a
                                    [ href "https://nixos.org/manual/nixos/stable/#modular-services"
                                    , Html.Attributes.target "_blank"
                                    , Html.Attributes.title "What are modular services?"
                                    ]
                                    [ text "(?)" ]
                                ]
                            , ul []
                                (List.map
                                    (\mod_ ->
                                        let
                                            suffix =
                                                if mod_ == "default" then
                                                    ""

                                                else
                                                    "." ++ mod_
                                        in
                                        li []
                                            [ a
                                                [ href ("/options?channel=" ++ channel ++ "&query=" ++ item.source.attr_name ++ "&include_nixos_options=0") ]
                                                [ code [] [ text ("pkgs." ++ item.source.attr_name ++ ".services" ++ suffix) ] ]
                                            ]
                                    )
                                    item.source.modularServices
                                )
                            ]
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


inlineListElementsCopyableCode : (a -> String) -> (a -> String) -> (a -> Html Msg) -> List a -> Html Msg
inlineListElementsCopyableCode toExtraClass toText toHtml items =
    baseInlineList "inline-list-elements" (\i -> i) (List.map (\item -> withCopyableCode (toExtraClass item) (toText item) (toHtml item)) items)


inlineListCode : List (Html msg) -> Html msg
inlineListCode =
    baseInlineList "inline-list" withCode


withCode : Html msg -> Html msg
withCode i =
    code [] [ i ]


withCopyableCode : String -> String -> Html Msg -> Html Msg
withCopyableCode extraClass content html =
    code
        [ onClick (CopyToClipboard content)
        , class ("clickable-code " ++ extraClass)
        , title "Click to copy"
        ]
        [ html ]


baseInlineList : String -> (Html msg -> Html msg) -> List (Html msg) -> Html msg
baseInlineList className wrapper items =
    ul [ class className ]
        (items
            |> List.map (\i -> li [] [ wrapper i ])
            |> List.intersperse (text " ")
        )


getLicenseDisplayAndTooltip :
    { a | fullName : Maybe String, shortName : Maybe String, spdxId : Maybe String }
    -> { display : String, tooltip : Maybe String }
getLicenseDisplayAndTooltip license =
    let
        display =
            case license.spdxId of
                Just spdxId ->
                    spdxId

                Nothing ->
                    case license.shortName of
                        Just shortName ->
                            shortName

                        Nothing ->
                            Maybe.withDefault "Unknown" license.fullName

        tooltip =
            case license.fullName of
                Just fullName ->
                    Just fullName

                Nothing ->
                    case license.shortName of
                        Just shortName ->
                            Just shortName

                        Nothing ->
                            license.spdxId
    in
    { display = display, tooltip = tooltip }


renderLicenseLeaf :
    { a | fullName : Maybe String, shortName : Maybe String, spdxId : Maybe String, url : Maybe String }
    -> Html Msg
renderLicenseLeaf license =
    let
        info =
            getLicenseDisplayAndTooltip license

        titleAttr =
            case info.tooltip of
                Just t ->
                    [ title t ]

                Nothing ->
                    []
    in
    case license.url of
        Just u ->
            a
                ([ href u
                 , target "_blank"
                 ]
                    ++ titleAttr
                )
                [ text info.display ]

        Nothing ->
            span titleAttr [ text info.display ]


renderLicenseExpression :
    LicenseExpression
    -> List (Html Msg)
renderLicenseExpression expr =
    case expr of
        LicenseLeaf leaf ->
            [ renderLicenseLeaf leaf ]

        LicenseAnd children ->
            renderJoined "AND" children

        LicenseOr children ->
            renderJoined "OR" children

        LicenseWith license exception ->
            renderChild license
                ++ [ text " ", span [ class "license-operator" ] [ text "WITH" ], text " " ]
                ++ renderChild exception

        LicensePlus license ->
            renderChild license ++ [ text "+" ]


renderJoined :
    String
    -> List LicenseExpression
    -> List (Html Msg)
renderJoined op children =
    let
        separator =
            [ text " ", span [ class "license-operator" ] [ text op ], text " " ]
    in
    children
        |> List.map renderChild
        |> List.intersperse separator
        |> List.concat


{-| Render a sub-expression, parenthesising compound children so the
precedence is unambiguous.
-}
renderChild :
    LicenseExpression
    -> List (Html Msg)
renderChild expr =
    let
        inner =
            renderLicenseExpression expr
    in
    case expr of
        LicenseLeaf _ ->
            inner

        LicensePlus _ ->
            inner

        _ ->
            text "(" :: inner ++ [ text ")" ]


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


encodeRequestBody : String -> Int -> Int -> Maybe String -> Search.Sort -> Json.Encode.Value
encodeRequestBody query from size maybeBuckets sort =
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
    Search.encodeRequestBody
        (String.trim query)
        from
        size
        sort
        [ "package" ]
        "package_attr_name"
        [ "package_pversion" ]
        [ { field = "package_attr_set", size = 20, include = Nothing }
        , { field = "package_license_set", size = 20, include = Nothing }
        , { field = "package_maintainers_set", size = 20, include = Nothing }
        , { field = "package_teams_set", size = 20, include = Nothing }
        , { field = "package_platforms", size = 20, include = Just platforms }
        ]
        filterByBuckets
        [ "package_attr_name" ]
        [ ( "package_attr_name", 9.0 )
        , ( "package_programs", 9.0 )
        , ( "package_pname", 6.0 )
        , ( "package_description", 1.3 )
        , ( "package_longDescription", 1.0 )
        , ( "flake_name", 0.5 )
        ]
        [ "package_description^3", "package_longDescription^1" ]
        (Just "package_attr_name")


makeRequestBody : String -> Int -> Int -> Maybe String -> Search.Sort -> Body
makeRequestBody query from size maybeBuckets sort =
    Http.jsonBody (encodeRequestBody query from size maybeBuckets sort)



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
        |> Json.Decode.Pipeline.optional "package_license_expression"
            (Json.Decode.nullable decodeLicenseExpression)
            Nothing
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
        |> Json.Decode.Pipeline.optional "package_modular_services" (Json.Decode.list Json.Decode.string) []


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
    Json.Decode.map4 ResultPackageLicense
        (Json.Decode.oneOf [ Json.Decode.field "fullName" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
        (Json.Decode.oneOf [ Json.Decode.field "shortName" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
        (Json.Decode.oneOf [ Json.Decode.field "spdxId" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
        (Json.Decode.oneOf [ Json.Decode.field "url" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])


decodeLicenseExpression : Json.Decode.Decoder LicenseExpression
decodeLicenseExpression =
    let
        recurse =
            Json.Decode.lazy (\_ -> decodeLicenseExpression)
    in
    Json.Decode.field "kind" Json.Decode.string
        |> Json.Decode.andThen
            (\kind ->
                case kind of
                    "leaf" ->
                        Json.Decode.map4
                            (\f s idx u -> LicenseLeaf { fullName = f, shortName = s, spdxId = idx, url = u })
                            (Json.Decode.oneOf [ Json.Decode.field "fullName" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
                            (Json.Decode.oneOf [ Json.Decode.field "shortName" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
                            (Json.Decode.oneOf [ Json.Decode.field "spdxId" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])
                            (Json.Decode.oneOf [ Json.Decode.field "url" (Json.Decode.nullable Json.Decode.string), Json.Decode.succeed Nothing ])

                    "and" ->
                        Json.Decode.map LicenseAnd
                            (Json.Decode.field "licenses" (Json.Decode.list recurse))

                    "or" ->
                        Json.Decode.map LicenseOr
                            (Json.Decode.field "licenses" (Json.Decode.list recurse))

                    "with" ->
                        Json.Decode.map2 LicenseWith
                            (Json.Decode.field "license" recurse)
                            (Json.Decode.field "exception" recurse)

                    "plus" ->
                        Json.Decode.map LicensePlus
                            (Json.Decode.field "license" recurse)

                    other ->
                        Json.Decode.fail ("Unknown license expression kind: " ++ other)
            )


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
