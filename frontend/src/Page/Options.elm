module Page.Options exposing
    ( AggregationsAll
    , Model
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
import Route exposing (OptionSource, SearchType)
import Search
    exposing
        ( Details
        , NixOSChannel
        , decodeResolvedFlake
        )
import Set exposing (Set)
import SyntaxHighlight exposing (elm, oneDark, toBlockHtml, useTheme)
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
    let
        enabledCount =
            List.length Route.allOptionSources - Set.size model.excludedOptionSources
    in
    Search.view { categoryName = "options" }
        [ text "Search more than "
        , strong [] [ text "20 000 options" ]
        ]
        nixosChannels
        model
        (viewSuccess (enabledCount > 1))
        viewBuckets
        SearchMsg
        [ viewIncludeTogglesGroup model.excludedOptionSources ]


viewIncludeTogglesGroup : Set String -> Html Msg
viewIncludeTogglesGroup excluded =
    li [ class "search-include-toggles" ]
        [ ul [] <|
            li [ class "header" ] [ text "Show" ]
                :: List.map (viewIncludeToggle excluded) Route.allOptionSources
        ]


viewIncludeToggle : Set String -> OptionSource -> Html Msg
viewIncludeToggle excluded source =
    let
        id =
            Route.optionSourceId source

        isChecked =
            not (Set.member id excluded)
    in
    li [ class ("search-include-" ++ id ++ "-options") ]
        [ label []
            [ input
                [ type_ "checkbox"
                , checked isChecked
                , onCheck (\b -> SearchMsg (Search.SetOptionSourceIncluded source b))
                ]
                []
            , text (" " ++ Route.optionSourceLabel source)
            ]
        ]


viewBuckets :
    Maybe String
    -> Search.SearchResult ResultItemSource ResultAggregations
    -> List (Html Msg)
viewBuckets _ _ =
    []


viewSuccess :
    Bool
    -> List NixOSChannel
    -> String
    -> Details
    -> Maybe String
    -> List (Search.ResultItem ResultItemSource)
    -> Html Msg
viewSuccess showBadges nixosChannels channel _ show hits =
    ul []
        (List.map
            (viewResultItem nixosChannels channel show showBadges)
            hits
        )


viewResultItem :
    List NixOSChannel
    -> String
    -> Maybe String
    -> Bool
    -> Search.ResultItem ResultItemSource
    -> Html Msg
viewResultItem nixosChannels channel show showBadges item =
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

        nameSegments =
            optionNameSegments item.source

        displayName =
            nameSegments |> List.map Tuple.first |> String.join "."

        showDetails =
            if Just (item.source.docType ++ ":" ++ item.source.name) == show then
                Just <|
                    div [ Html.Attributes.map SearchMsg Search.trapClick ] <|
                        let
                            pkgLink pkg =
                                a
                                    [ href ("/packages?channel=" ++ channel ++ "&query=" ++ pkg ++ "&show=" ++ pkg) ]
                                    [ code [] [ text pkg ] ]
                        in
                        [ div [] [ text "Name" ]
                        , div [] [ viewOptionNamePath channel nameSegments ]
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
                            ++ (if isService then
                                    case ( item.source.servicePackage, item.source.serviceModule ) of
                                        ( Just pkg, Just mod_ ) ->
                                            let
                                                -- Re-indent a (possibly multi-line) value so
                                                -- every line after the first aligns with `indent`.
                                                indentValue indent val =
                                                    case String.split "\n" val of
                                                        [] ->
                                                            val

                                                        first :: rest ->
                                                            first
                                                                ++ String.concat
                                                                    (List.map (\l -> "\n" ++ indent ++ l) rest)

                                                -- Only use defaults that look like plain Nix
                                                -- expressions (from `literalExpression`).
                                                -- Rendered HTML/markdown defaults are not
                                                -- useful in a code snippet.
                                                isNixLiteral val =
                                                    not (String.contains "<" val)

                                                leafValue indent =
                                                    item.source.default
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
                                                    String.split "." item.source.name

                                                nestedOption =
                                                    nestOption optionParts "  "
                                            in
                                            [ div [] [ text "Usage" ]
                                            , div []
                                                [ pre []
                                                    [ code [ class "code-block" ]
                                                        [ text
                                                            ("system.services.<name> = {\n"
                                                                ++ "  imports = [ pkgs."
                                                                ++ pkg
                                                                ++ ".services."
                                                                ++ mod_
                                                                ++ " ];\n"
                                                                ++ nestedOption
                                                                ++ "};"
                                                            )
                                                        ]
                                                    ]
                                                ]
                                            ]

                                        _ ->
                                            []

                                else
                                    []
                               )
                            ++ [ div [] [ text "Declared in" ]
                               , div [] <| findSource nixosChannels channel item.source
                               ]

            else
                Nothing

        itemId =
            item.source.docType ++ ":" ++ item.source.name

        toggle =
            SearchMsg (Search.ShowDetails itemId)

        isOpen =
            Just itemId == show

        categoryBadge =
            if showBadges then
                let
                    ( badgeText, badgeClass ) =
                        case item.source.docType of
                            "option" ->
                                ( "NixOS", "badge-nixos" )

                            "service" ->
                                ( "Service", "badge-service" )

                            _ ->
                                ( "Other", "badge-other" )
                in
                [ li []
                    [ span [ class "option-badge-column" ]
                        [ span [ class ("option-badge " ++ badgeClass) ]
                            [ text badgeText ]
                        ]
                    ]
                ]

            else
                []
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
                    (categoryBadge
                        ++ [ li []
                                [ a
                                    [ onClick toggle
                                    , href ""
                                    ]
                                    [ text displayName ]
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
            case List.Extra.find (\x -> x.id == channel) nixosChannels of
                Just channelDetails ->
                    a
                        [ href <| githubUrlPrefix channelDetails.branch ++ (value |> String.replace ":" "#L")
                        , target "_blank"
                        ]
                        [ text value ]

                Nothing ->
                    text <| cleanPosition value
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
                            [ asGithubLink source_
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
Every non-final dotted segment of the option name links to its own prefix
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


viewOptionNamePath : String -> List ( String, Maybe String ) -> Html Msg
viewOptionNamePath channel segments =
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
                , excludedOptionSources = Set.empty
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
    div []
        [ pre []
            [ code [ class "code-block" ]
                (segments |> List.indexedMap renderSegment |> List.concat)
            ]
        ]



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
    -> Set String
    -> Cmd Msg
makeRequest options nixosChannels _ channel query from size _ sort excludedOptionSources =
    let
        types =
            Route.allOptionSources
                |> List.filter
                    (\source ->
                        not (Set.member (Route.optionSourceId source) excludedOptionSources)
                    )
                |> List.map Route.optionSourceDocType
    in
    Search.makeRequest
        (makeRequestBody types query from size sort)
        nixosChannels
        channel
        decodeResultItemSource
        decodeResultAggregations
        options
        Search.QueryResponse
        (Just "query-options")
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
