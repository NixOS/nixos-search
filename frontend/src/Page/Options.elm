port module Page.Options exposing
    ( AggregationsAll
    , Model
    , Msg(..)
    , ResultAggregations
    , ResultItemSource
    , copyToClipboard
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
import Dict exposing (Dict)
import Html
    exposing
        ( Html
        , a
        , button
        , code
        , div
        , input
        , label
        , li
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
        , target
        , title
        , type_
        )
import Html.Events
    exposing
        ( onCheck
        , onClick
        )
import Http exposing (Body)
import Json.Decode
import Json.Decode.Pipeline
import List.Extra
import RemoteData
import Route exposing (OptionSource, SearchType)
import Search
    exposing
        ( Details
        , NixOSChannel
        , decodeResolvedFlake
        )
import SyntaxHighlight exposing (elm, oneDark, toBlockHtml, useTheme)
import Task
import Url
import Utils



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

    -- ES document type ("option", "service", "home-manager-option")
    , docType : String

    -- flake
    , flake : Maybe (List String)
    , flakeName : Maybe String
    , flakeDescription : Maybe String
    , flakeUrl : Maybe String
    , flakeRevision : Maybe String

    -- modular service metadata (populated only for `service` docs)
    , servicePackage : Maybe String
    , serviceModule : Maybe String
    , servicePackages : List String
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
    -> Bool
    -> Maybe Model
    -> ( Model, Cmd Msg )
init searchArgs defaultNixOSChannel nixosChannels includeChannelInUrl model =
    let
        ( newModel, newCmd ) =
            Search.init searchArgs defaultNixOSChannel nixosChannels model

        finalModel =
            if includeChannelInUrl then
                { newModel | urlChannel = Just newModel.channel }

            else
                newModel
    in
    ( finalModel
    , Cmd.map SearchMsg newCmd
    )



-- PORTS


{-| Ask the JS side to copy the given text to the clipboard.
-}
port copyToClipboard : String -> Cmd msg



-- UPDATE


type Msg
    = SearchMsg (Search.Msg ResultItemSource ResultAggregations)
    | CopyOptionName String


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

        CopyOptionName name ->
            ( model, copyToClipboard name )



-- VIEW


view :
    List NixOSChannel
    -> Model
    -> Html Msg
view nixosChannels model =
    Search.view { categoryName = "options" }
        [ text "Search more than "
        , strong [] [ text "20 000 options" ]
        ]
        nixosChannels
        model
        (viewSuccess model.activeOptionSource)
        viewBuckets
        SearchMsg
        [ viewSourceTabs model.activeOptionSource model.sourceCounts ]


{-| Tab strip: one tab per option source. Each tab pulls its count from
the shared `sourceCounts` dict (the active tab's count is mirrored
there on `QueryResponse`, inactive ones come from `size: 0` queries
fired alongside the main one). Pulling counts uniformly from one place
means the badges survive a tab switch unchanged — the previous tab's
count stays visible until a fresh count for the new tab arrives.
-}
viewSourceTabs : OptionSource -> Dict String Int -> Html Msg
viewSourceTabs activeSource sourceCounts =
    li [ class "search-source-tabs" ]
        [ ul [] <|
            li [ class "header" ] [ text "Source" ]
                :: List.map
                    (\source ->
                        viewSourceTab
                            activeSource
                            (Dict.get (Route.optionSourceId source) sourceCounts)
                            source
                    )
                    Route.allOptionSources
        ]


viewSourceTab : OptionSource -> Maybe Int -> OptionSource -> Html Msg
viewSourceTab activeSource count source =
    let
        isActive =
            source == activeSource

        id =
            Route.optionSourceId source

        badge =
            case count of
                Just n ->
                    [ span [ class "badge" ] [ text (formatCount n) ] ]

                Nothing ->
                    []
    in
    li
        [ class ("search-source-" ++ id) ]
        [ a
            -- The sidebar's existing `&.selected` styling targets `a`,
            -- not `li`, so the active-tab highlight class lives on the
            -- anchor.
            [ classList [ ( "selected", isActive ) ]
            , href "#"
            , Html.Events.onClick (SearchMsg (Search.SetActiveOptionSource source))
            ]
            (span [] [ text (Route.optionSourceLabel source) ] :: badge)
        ]


{-| Compact rendering of a hit count for the tab badge: 1.2k, 23k, etc.
ES returns counts up to 10 000 as exact and beyond that as a >=10000
sentinel; render the latter as "10k+" so we don't lie about precision.
-}
formatCount : Int -> String
formatCount n =
    if n >= 10000 then
        "10k+"

    else if n >= 1000 then
        String.fromInt (n // 1000) ++ "." ++ String.fromInt (modBy 10 (n // 100)) ++ "k"

    else
        String.fromInt n


viewBuckets :
    Maybe String
    -> Search.SearchResult ResultItemSource ResultAggregations
    -> List (Html Msg)
viewBuckets _ _ =
    []


viewSuccess :
    OptionSource
    -> List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> List (Search.ResultItem ResultItemSource)
    -> Html Msg
viewSuccess activeSource nixosChannels channel _ show hits =
    ul []
        (List.map
            (viewResultItem nixosChannels channel show activeSource)
            hits
        )


viewResultItem :
    List NixOSChannel
    -> String
    -> Maybe String
    -> OptionSource
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItem nixosChannels channel show activeSource item =
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
                        (pre [] [ code [ class "code-block" ] [ text value ] ])
                ]

        isService =
            item.source.docType == "service"

        isHomeManager =
            item.source.docType == "home-manager-option"

        nameSegments =
            optionNameSegments item.source

        displayName =
            nameSegments |> List.map Tuple.first |> String.join "."

        itemId =
            item.source.docType ++ ":" ++ item.source.name

        pkgLink pkg =
            a
                [ href ("/packages?channel=" ++ channel ++ "&query=" ++ pkg ++ "#show=" ++ Url.percentEncode pkg) ]
                [ code [] [ text pkg ] ]

        showDetails =
            if Just itemId == show then
                Just <|
                    div [ Html.Attributes.map SearchMsg Search.trapClick ] <|
                        [ div [] [ text "Name" ]
                        , div [] [ viewOptionNamePath channel activeSource item.source.name nameSegments ]
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
                                        (\t ->
                                            [ div [] [ text "Type" ]
                                            , div [] [ asPre t ]
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
                            ++ (if isService then
                                    [ div [] [ text "About" ]
                                    , div []
                                        [ a
                                            [ href "https://nixos.org/manual/nixos/stable/#modular-services"
                                            , Html.Attributes.target "_blank"
                                            ]
                                            [ text "What are modular services?" ]
                                        ]
                                    ]

                                else
                                    []
                               )
                            ++ (if isService then
                                    case item.source.servicePackages of
                                        [] ->
                                            item.source.servicePackage
                                                |> Maybe.map
                                                    (\pkg ->
                                                        [ div [] [ text "Provided by package" ]
                                                        , div [] [ pkgLink pkg ]
                                                        ]
                                                    )
                                                |> Maybe.withDefault []

                                        [ single ] ->
                                            [ div [] [ text "Provided by package" ]
                                            , div [] [ pkgLink single ]
                                            ]

                                        many ->
                                            [ div [] [ text "Provided by packages" ]
                                            , div []
                                                (List.intersperse (text ", ") (List.map pkgLink many))
                                            ]

                                else
                                    []
                               )
                            ++ viewUsageSnippet item.source
                            ++ [ div [] [ text "Declared in" ]
                               , div [] <| findSource nixosChannels channel item.source
                               ]

            else
                Nothing

        toggle =
            SearchMsg (Search.ShowDetails itemId)

        isOpen =
            Just itemId == show
    in
    li
        [ class "option"
        , classList [ ( "opened", isOpen ) ]
        , Search.elementId itemId
        ]
    <|
        List.filterMap identity
            [ Just <|
                ul [ class "search-result-button" ]
                    [ li []
                        [ a
                            [ onClick toggle
                            , href ""
                            ]
                            [ text displayName ]
                        ]
                    ]
            , showDetails
            ]


{-| Render a "Usage" section showing how to use this option in the appropriate
context, including `_class` to clarify which module system it belongs to.
-}
viewUsageSnippet : ResultItemSource -> List (Html msg)
viewUsageSnippet source =
    let
        -- Re-indent a (possibly multi-line) value so every line after the
        -- first aligns with `indent`.
        indentValue indent val =
            case String.split "\n" val of
                [] ->
                    val

                first :: rest ->
                    first ++ String.concat (List.map (\l -> "\n" ++ indent ++ l) rest)

        -- Only use defaults that look like plain Nix expressions (from
        -- `literalExpression`). Rendered HTML/markdown defaults are not
        -- useful in a code snippet.
        isNixLiteral val =
            not (String.contains "<" val)

        leafValue indent =
            source.default
                |> Maybe.andThen
                    (\val ->
                        if isNixLiteral val then
                            Just (indentValue indent val)

                        else
                            Nothing
                    )
                |> Maybe.withDefault "..."

        -- Expand "php-fpm.settings" into nested:
        --   php-fpm = {
        --     settings = <default>;
        --   };
        nestOption parts indent =
            case parts of
                [] ->
                    ""

                [ leaf ] ->
                    indent ++ leaf ++ " = " ++ leafValue indent ++ ";\n"

                head_ :: rest ->
                    indent
                        ++ head_
                        ++ " = {\n"
                        ++ nestOption rest (indent ++ "  ")
                        ++ indent
                        ++ "};\n"

        optionParts =
            String.split "." source.name

        nestedOption indent =
            nestOption optionParts indent
    in
    case source.docType of
        "service" ->
            case ( source.servicePackage, source.serviceModule ) of
                ( Just pkg, Just mod_ ) ->
                    [ div [] [ text "Usage" ]
                    , div []
                        [ pre []
                            [ code [ class "code-block" ]
                                [ text
                                    ("system.services.<name> = {\n"
                                        ++ "  _class = \"service\";\n"
                                        ++ "  imports = [ pkgs."
                                        ++ pkg
                                        ++ ".services."
                                        ++ mod_
                                        ++ " ];\n"
                                        ++ nestedOption "  "
                                        ++ "};"
                                    )
                                ]
                            ]
                        ]
                    ]

                _ ->
                    []

        "option" ->
            [ div [] [ text "Usage" ]
            , div []
                [ pre []
                    [ code [ class "code-block" ]
                        [ text
                            ("# configuration.nix\n"
                                ++ "{\n"
                                ++ "  _class = \"nixos\";\n"
                                ++ nestedOption "  "
                                ++ "}"
                            )
                        ]
                    ]
                ]
            ]

        "home-manager-option" ->
            [ div [] [ text "Usage" ]
            , div []
                [ pre []
                    [ code [ class "code-block" ]
                        [ text
                            ("# home.nix\n"
                                ++ "{\n"
                                ++ "  _class = \"homeManager\";\n"
                                ++ nestedOption "  "
                                ++ "}"
                            )
                        ]
                    ]
                ]
            ]

        _ ->
            []


findSource :
    List NixOSChannel
    -> String
    -> ResultItemSource
    -> List (Html a)
findSource nixosChannels channel source =
    let
        githubUrlPrefix branch =
            "https://github.com/NixOS/nixpkgs/blob/" ++ branch ++ "/"

        -- Home Manager options are imported from the `release-XX.YY` branch of
        -- `nix-community/home-manager` matching the nixpkgs channel
        -- (see `flake-info/src/commands/nixpkgs_info.rs`), or `master` for
        -- `nixos-unstable`. Their `option_source` paths resolve against that
        -- repo, not nixpkgs.
        homeManagerBranch nixpkgsBranch =
            if nixpkgsBranch == "nixos-unstable" then
                "master"

            else
                "release-" ++ String.dropLeft (String.length "nixos-") nixpkgsBranch

        homeManagerUrlPrefix branch =
            "https://github.com/nix-community/home-manager/blob/" ++ branch ++ "/"

        cleanPosition value =
            if String.startsWith "source/" value then
                String.dropLeft 7 value

            else
                value

        asGithubLink value =
            case List.Extra.find (\x -> x.id == channel) nixosChannels of
                Just channelDetails ->
                    let
                        prefix =
                            if source.docType == "home-manager-option" then
                                homeManagerUrlPrefix (homeManagerBranch channelDetails.branch)

                            else
                                githubUrlPrefix channelDetails.branch
                    in
                    a
                        [ href <| prefix ++ (value |> String.replace ":" "#L")
                        , target "_blank"
                        ]
                        [ text value ]

                Nothing ->
                    text <| cleanPosition value

        asFlakeSourceLink flakeUrl_ value =
            let
                looksLikePath v =
                    not (String.isEmpty v)
                        && not (String.contains " " v)
                        && not (String.contains "," v)

                ref =
                    Maybe.withDefault "HEAD" source.flakeRevision

                positionWithLine =
                    cleanPosition value |> String.replace ":" "#L"
            in
            if looksLikePath value && String.startsWith "https://github.com/" flakeUrl_ then
                a
                    [ href (flakeUrl_ ++ "/blob/" ++ ref ++ "/" ++ positionWithLine)
                    , target "_blank"
                    ]
                    [ text value ]

            else
                text value
    in
    case ( source.flake, source.flakeUrl, source.source ) of
        -- its a flake
        ( Just (name :: attrs), Just flakeUrl_, _ ) ->
            let
                module_ : String
                module_ =
                    List.head attrs
                        |> Maybe.map (\m -> "(Module: " ++ m ++ ")")
                        |> Maybe.withDefault "(default)"
            in
            List.append
                (source.source
                    |> Maybe.map
                        (\source_ ->
                            [ asFlakeSourceLink flakeUrl_ source_
                            , span [] [ text " in " ]
                            ]
                        )
                    |> Maybe.withDefault []
                )
                [ span [] [ text "Flake: " ]
                , a [ href flakeUrl_ ] [ text <| name ++ module_ ]
                ]

        ( Nothing, _, Just source_ ) ->
            [ asGithubLink source_ ]

        _ ->
            [ span [] [ text "Not Found" ] ]


{-| Segments making up an option's display name. Each `(text, Just q)` becomes
a clickable link to an options search for `q`; `(text, Nothing)` is static.
Every dotted segment of the option name links to its own prefix
(`programs` -> `programs.firefox` -> ...).
-}
optionNameSegments : ResultItemSource -> List ( String, Maybe String )
optionNameSegments source =
    let
        parts =
            String.split "." source.name
    in
    parts
        |> List.indexedMap
            (\idx part ->
                ( part
                , parts |> List.take (idx + 1) |> String.join "." |> Just
                )
            )


viewOptionNamePath : String -> OptionSource -> String -> List ( String, Maybe String ) -> Html Msg
viewOptionNamePath channel activeSource optionName segments =
    let
        lastIndex =
            List.length segments - 1

        groupRoute q =
            Route.Options
                { query = Just q
                , channel = Just channel
                , show = Nothing
                , from = Nothing
                , size = Nothing
                , buckets = Nothing
                , sort = Nothing
                , type_ = Nothing
                , activeOptionSource = activeSource
                }

        renderSegment idx ( segText, query ) =
            let
                element =
                    case query of
                        Just q ->
                            a
                                [ Route.href (groupRoute q), class "option-name-group" ]
                                [ text segText ]

                        Nothing ->
                            text segText

                separator =
                    if idx < lastIndex then
                        [ text "." ]

                    else
                        []
            in
            element :: separator
    in
    div [ class "option-name-path" ]
        [ pre []
            [ code [ class "code-block" ]
                (segments |> List.indexedMap renderSegment |> List.concat)
            ]
        , button
            [ type_ "button"
            , class "option-copy-button"
            , title "Copy option name"
            , onClick (CopyOptionName optionName)
            ]
            [ text "Copy" ]
        ]



-- API


{-| Issue a single ES query restricted to the active tab's source plus
one tiny `size: 0` count query per inactive source so the tabs can
display hit-count badges. Active-tab body and count bodies are all
byte-stable across users on identical input, so `request_cache` hits
amortize the cost; size:0 in particular is the workload that cache
was designed for.
-}
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
    -> OptionSource
    -> Cmd Msg
makeRequest options nixosChannels _ channel query from size _ sort activeSource =
    let
        activeQuery : Cmd (Search.Msg ResultItemSource ResultAggregations)
        activeQuery =
            Search.makeRequestTask
                (makeRequestBody
                    [ Route.optionSourceDocType activeSource ]
                    query
                    from
                    size
                    sort
                )
                nixosChannels
                channel
                decodeResultItemSource
                decodeResultAggregations
                options
                |> Task.attempt (RemoteData.fromResult >> Search.QueryResponse)

        countQuery : OptionSource -> Cmd (Search.Msg ResultItemSource ResultAggregations)
        countQuery source =
            Search.makeRequestTask
                (makeRequestBody
                    [ Route.optionSourceDocType source ]
                    query
                    0
                    0
                    sort
                )
                nixosChannels
                channel
                decodeResultItemSource
                decodeResultAggregations
                options
                |> Task.attempt
                    (\result ->
                        case result of
                            Ok r ->
                                Search.SourceCount
                                    (Route.optionSourceId source)
                                    r.hits.total.value

                            Err _ ->
                                -- Swallow the error; the badge just won't
                                -- appear for that tab. The active tab's
                                -- own failure mode is handled by `result`.
                                Search.NoOp
                    )

        inactiveSources =
            Route.allOptionSources
                |> List.filter (\s -> s /= activeSource)
    in
    (activeQuery :: List.map countQuery inactiveSources)
        |> Cmd.batch
        |> Cmd.map SearchMsg


makeRequestBody : List String -> String -> Int -> Int -> Search.Sort -> Body
makeRequestBody types query from size sort =
    Search.makeRequestBody
        (String.trim query)
        from
        size
        sort
        types
        "option_name"
        []
        []
        []
        [ "option_name", "option_name_query" ]
        [ ( "option_name", 6.0 )
        , ( "option_name_query", 6.0 )
        , ( "option_description", 1.0 )
        , ( "flake_name", 0.5 )
        , ( "service_package", 3.0 )
        , ( "service_packages", 3.0 )
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
        |> Json.Decode.Pipeline.required "type" Json.Decode.string
        |> Json.Decode.Pipeline.optional "option_flake"
            (Json.Decode.map Just <| Json.Decode.list Json.Decode.string)
            Nothing
        |> Json.Decode.Pipeline.optional "flake_name" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_description" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "flake_resolved" (Json.Decode.map Just decodeResolvedFlake) Nothing
        |> Json.Decode.Pipeline.optional "revision" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "service_package" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "service_module" (Json.Decode.map Just Json.Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "service_packages" (Json.Decode.list Json.Decode.string) []


decodeResultAggregations : Json.Decode.Decoder ResultAggregations
decodeResultAggregations =
    Json.Decode.map ResultAggregations
        (Json.Decode.field "all" decodeResultAggregationsAll)


decodeResultAggregationsAll : Json.Decode.Decoder AggregationsAll
decodeResultAggregationsAll =
    Json.Decode.map AggregationsAll
        (Json.Decode.field "doc_count" Json.Decode.int)
