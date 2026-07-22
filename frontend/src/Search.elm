module Search exposing
    ( Aggregation
    , AggregationsBucketItem
    , BucketInputType(..)
    , Details(..)
    , Model
    , Msg(..)
    , NixOSChannel
    , NixOSChannelStatus
    , NixOSChannels
    , Options
    , ResultHits
    , ResultHitsTotal
    , ResultItem
    , SearchResult
    , Sort(..)
    , Terms
    , decodeAggregation
    , decodeNixOSChannels
    , decodeResolvedFlake
    , defaultFlakeId
    , elementId
    , init
    , makeRequest
    , makeRequestTask
    , onClickStop
    , shouldLoad
    , showMoreButton
    , trapClick
    , update
    , view
    , viewBucket
    , viewFlakes
    , viewResult
    , viewSearchInput
    )

import Array
import Base64
import Browser.Dom
import Browser.Navigation
import Components.Button exposing (viewButton)
import Dict exposing (Dict)
import Html
    exposing
        ( Html
        , a
        , aside
        , code
        , div
        , fieldset
        , form
        , h1
        , h2
        , h4
        , input
        , label
        , legend
        , li
        , option
        , p
        , select
        , span
        , strong
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( autocomplete
        , autofocus
        , checked
        , class
        , classList
        , disabled
        , href
        , id
        , name
        , placeholder
        , type_
        , value
        )
import Html.Events
    exposing
        ( on
        , onBlur
        , onClick
        , onFocus
        , onInput
        , onSubmit
        )
import Http
import Json.Decode
import Json.Decode.Pipeline
import RemoteData
import Route
    exposing
        ( OptionSource
        , SearchType(..)
        , allTypes
        , searchTypeToTitle
        )
import Search.Typeahead as Typeahead
import Task


type alias Model a b =
    { channel : String
    , flake : String
    , query : String
    , result : RemoteData.WebData (SearchResult a b)
    , show : Maybe String
    , from : Int
    , size : Int
    , buckets : Maybe String
    , sort : Sort
    , showUsageDetails : Details
    , searchType : Route.SearchType
    , redirectedChannel : Maybe String
    , urlChannel : Maybe String
    , activeOptionSource : Route.OptionSource

    -- Hit counts per option source, keyed by `Route.optionSourceId`.
    -- The active source's count is written here on `QueryResponse`,
    -- inactive sources' counts arrive via `SourceCount`. Surviving
    -- across tab switches keeps the badges visible while the new
    -- tab's full query is in flight.
    , sourceCounts : Dict String Int

    -- Last successful result, retained while a new query is in flight
    -- so the UI can keep showing it (with a spinner) instead of
    -- flashing the full loader. Cleared once the new response lands.
    , previousResult : Maybe (SearchResult a b)
    , options : Options
    , typeahead : Typeahead.Model
    }


type alias SearchResult a b =
    { hits : ResultHits a
    , aggregations : b
    }


type alias ResultHits a =
    { total : ResultHitsTotal
    , max_score : Maybe Float
    , hits : List (ResultItem a)
    }


type alias ResultHitsTotal =
    { value : Int
    , relation : String
    }


type alias ResultItem a =
    { index : String
    , id : String
    , score : Maybe Float
    , source : a
    , text : Maybe String
    , matched_queries : Maybe (List String)
    }


type alias Aggregation =
    { doc_count_error_upper_bound : Int
    , sum_other_doc_count : Int
    , buckets : List AggregationsBucketItem
    }


type alias AggregationsBucketItem =
    { doc_count : Int
    , key : String
    }


type Sort
    = Relevance
    | AlphabeticallyAsc
    | AlphabeticallyDesc


type alias NixOSChannels =
    { default : String
    , channels : List NixOSChannel
    }


type alias NixOSChannel =
    { id : String
    , status : NixOSChannelStatus
    , jobset : String
    , branch : String
    }


type NixOSChannelStatus
    = Rolling
    | Beta
    | Stable
    | Deprecated


decodeNixOSChannels : Json.Decode.Decoder NixOSChannels
decodeNixOSChannels =
    Json.Decode.map2 NixOSChannels
        (Json.Decode.field "default" Json.Decode.string)
        (Json.Decode.field "channels" (Json.Decode.list decodeNixOSChannel))


decodeNixOSChannel : Json.Decode.Decoder NixOSChannel
decodeNixOSChannel =
    Json.Decode.map4 NixOSChannel
        (Json.Decode.field "id" Json.Decode.string)
        (Json.Decode.field "status"
            (Json.Decode.string
                |> Json.Decode.andThen
                    (\status ->
                        case status of
                            "rolling" ->
                                Json.Decode.succeed Rolling

                            "beta" ->
                                Json.Decode.succeed Beta

                            "stable" ->
                                Json.Decode.succeed Stable

                            "deprecated" ->
                                Json.Decode.succeed Deprecated

                            _ ->
                                Json.Decode.fail ("Unknown status: " ++ status)
                    )
            )
        )
        (Json.Decode.field "jobset" Json.Decode.string)
        (Json.Decode.field "branch" Json.Decode.string)


type alias ResolvedFlake =
    { type_ : String
    , owner : Maybe String
    , repo : Maybe String
    , url : Maybe String
    }


decodeResolvedFlake : Json.Decode.Decoder String
decodeResolvedFlake =
    let
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
                repoPath =
                    case ( resolved_.owner, resolved_.repo ) of
                        ( Just owner, Just repo ) ->
                            Just <| owner ++ "/" ++ repo

                        _ ->
                            Nothing

                result =
                    case resolved_.type_ of
                        "github" ->
                            Maybe.map (\repoPath_ -> "https://github.com/" ++ repoPath_) repoPath

                        "gitlab" ->
                            Maybe.map (\repoPath_ -> "https://gitlab.com/" ++ repoPath_) repoPath

                        "sourcehut" ->
                            Maybe.map (\repoPath_ -> "https://sr.ht/" ++ repoPath_) repoPath

                        "git" ->
                            resolved_.url

                        _ ->
                            Nothing
            in
            Maybe.withDefault "INVALID FLAKE ORIGIN" result
        )
        resolved


init :
    Options
    -> Bool
    -> Route.SearchArgs
    -> String
    -> List NixOSChannel
    -> Maybe (Model a b)
    -> ( Model a b, Cmd (Msg a b) )
init options preferStatic args defaultNixOSChannel nixosChannels maybeModel =
    let
        getField getFn default =
            maybeModel
                |> Maybe.map getFn
                |> Maybe.withDefault default

        modelChannel =
            getField .channel defaultNixOSChannel

        requestedChannel =
            args.channel
                |> Maybe.withDefault modelChannel

        isValidChannel ch =
            List.any (\c -> c.id == ch) nixosChannels

        ( validChannel, redirected ) =
            if isValidChannel requestedChannel then
                ( requestedChannel, Nothing )

            else
                ( defaultNixOSChannel, args.channel )
    in
    ( { channel = validChannel
      , redirectedChannel = redirected
      , flake = defaultFlakeId
      , query =
            case args.query of
                Just q ->
                    q

                Nothing ->
                    args.show
                        |> Maybe.withDefault defaultSearchArgs.query
      , result = getField .result RemoteData.NotAsked
      , show = args.show
      , from =
            args.from
                |> Maybe.withDefault defaultSearchArgs.from
      , size =
            args.size
                |> Maybe.withDefault defaultSearchArgs.size
      , buckets = args.buckets
      , sort =
            args.sort
                |> Maybe.andThen fromSortId
                |> Maybe.withDefault defaultSearchArgs.sort
      , showUsageDetails = Unset
      , searchType =
            args.type_
                |> Maybe.withDefault defaultSearchArgs.searchType
      , activeOptionSource = args.activeOptionSource
      , sourceCounts = Dict.empty
      , previousResult = Nothing
      , urlChannel = args.channel
      , options = options
      , typeahead = Typeahead.init preferStatic
      }
        |> ensureLoading nixosChannels
    , Browser.Dom.focus "search-query-input" |> Task.attempt (\_ -> NoOp)
    )


defaultSearchArgs :
    { query : String
    , from : Int
    , size : Int
    , sort : Sort
    , searchType : SearchType
    }
defaultSearchArgs =
    { query = ""
    , from = 0
    , size = 50
    , sort = Relevance
    , searchType = Route.PackageSearch
    }


shouldLoad :
    Model a b
    -> Bool
shouldLoad model =
    model.result == RemoteData.Loading


ensureLoading :
    List NixOSChannel
    -> Model a b
    -> Model a b
ensureLoading nixosChannels model =
    if
        not (String.isEmpty model.query)
            && List.any (\channel -> channel.id == model.channel) nixosChannels
    then
        -- Save the current Success result so views can keep showing it
        -- (with a spinner overlay) while the new response is in flight,
        -- rather than flashing the full loader. Source counts are left
        -- alone: they get overwritten as new responses arrive, which
        -- avoids tab badges blanking on every tab switch.
        { model
            | result = RemoteData.Loading
            , previousResult =
                case model.result of
                    RemoteData.Success r ->
                        Just r

                    _ ->
                        model.previousResult
        }

    else
        model


elementId : String -> Html.Attribute msg
elementId str =
    Html.Attributes.id <| "result-" ++ str



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg a b
    = NoOp
    | SortChange Sort
    | BucketsChange String
    | ChannelChange String
    | SubjectChange SearchType
    | QueryInput String
    | QueryInputSubmit
    | QueryResponse (RemoteData.WebData (SearchResult a b))
    | ShowDetails String
    | ChangePage Int
    | ShowUsageDetails Details
    | SetActiveOptionSource OptionSource
    | SourceCount String Int
    | TypeaheadMsg Typeahead.Msg
    | TypeaheadBlur
    | TypeaheadFocus


type Details
    = ViaNixShell
    | ViaNixOS
    | ViaNixProfile
    | ViaNixEnv
    | FromFlake
    | Unset


scrollToEntry :
    Maybe String
    -> Cmd (Msg a b)
scrollToEntry val =
    let
        doScroll id =
            Browser.Dom.getElement ("result-" ++ id)
                |> Task.andThen (\{ element } -> Browser.Dom.setViewport element.x element.y)
                |> Task.attempt (always NoOp)
    in
    Maybe.withDefault Cmd.none <| Maybe.map doScroll val


update :
    Route.SearchRoute
    -> Browser.Navigation.Key
    -> Msg a b
    -> Model a b
    -> List NixOSChannel
    -> ( Model a b, Cmd (Msg a b) )
update toRoute navKey msg model nixosChannels =
    case msg of
        NoOp ->
            ( model
            , Cmd.none
            )

        SortChange sort ->
            { model
                | sort = sort
                , show = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        BucketsChange buckets ->
            { model
                | buckets =
                    if String.isEmpty buckets then
                        Nothing

                    else
                        Just buckets
                , show = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        ChannelChange channel ->
            if channel == model.channel then
                ( model, Cmd.none )

            else
                { model
                    | channel = channel
                    , urlChannel = Just channel
                    , redirectedChannel = Nothing
                    , show = Nothing
                    , from = 0
                }
                    |> ensureLoading nixosChannels
                    |> pushUrl toRoute navKey

        SubjectChange subject ->
            { model
                | searchType = subject
                , show = Nothing
                , buckets = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        QueryInput query ->
            let
                ( typeaheadModel, typeaheadCmd ) =
                    Typeahead.queryChanged model.options
                        nixosChannels
                        model.searchType
                        model.activeOptionSource
                        model.channel
                        query
                        model.typeahead
            in
            ( { model | query = query, typeahead = typeaheadModel }
            , Cmd.map TypeaheadMsg typeaheadCmd
            )

        QueryInputSubmit ->
            { model
                | from = 0
                , show = Nothing
                , typeahead = Typeahead.hideModel model.typeahead
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        QueryResponse result ->
            let
                -- Mirror the active tab's count into the per-source dict
                -- so tabs read uniformly from one place. Pages that don't
                -- use option-source tabs (Packages, Flakes) just write
                -- into a dict no one reads.
                updatedCounts =
                    case result of
                        RemoteData.Success r ->
                            let
                                activeSourceId =
                                    Route.optionSourceId model.activeOptionSource
                            in
                            Dict.insert
                                activeSourceId
                                r.hits.total.value
                                model.sourceCounts

                        _ ->
                            model.sourceCounts

                -- A fresh Success replaces the stale-while-loading copy.
                -- Failure keeps the previous result available so the user
                -- sees the prior data alongside an error rather than a
                -- blank page.
                clearedPrevious =
                    case result of
                        RemoteData.Success _ ->
                            Nothing

                        _ ->
                            model.previousResult
            in
            ( { model
                | result = result
                , sourceCounts = updatedCounts
                , previousResult = clearedPrevious
              }
            , scrollToEntry model.show
            )

        ShowDetails selected ->
            { model
                | show =
                    if model.show == Just selected then
                        Nothing

                    else
                        Just selected
            }
                |> pushUrl toRoute navKey

        ChangePage from ->
            { model | from = from }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        ShowUsageDetails details ->
            { model | showUsageDetails = details }
                |> pushUrl toRoute navKey

        SourceCount sourceId count ->
            ( { model
                | sourceCounts =
                    Dict.insert sourceId count model.sourceCounts
              }
            , Cmd.none
            )

        SetActiveOptionSource source ->
            { model
                | activeOptionSource = source
                , show = Nothing
                , from = 0
            }
                |> ensureLoading nixosChannels
                |> pushUrl toRoute navKey

        TypeaheadMsg subMsg ->
            let
                ( typeaheadModel, typeaheadCmd ) =
                    Typeahead.update model.options
                        nixosChannels
                        model.searchType
                        model.activeOptionSource
                        model.channel
                        model.query
                        subMsg
                        model.typeahead
            in
            ( { model | typeahead = typeaheadModel }, Cmd.map TypeaheadMsg typeaheadCmd )

        TypeaheadBlur ->
            ( model, Cmd.map TypeaheadMsg Typeahead.hideAfterBlur )

        TypeaheadFocus ->
            ( { model | typeahead = Typeahead.focusModel model.typeahead }, Cmd.none )


pushUrl :
    Route.SearchRoute
    -> Browser.Navigation.Key
    -> Model a b
    -> ( Model a b, Cmd msg )
pushUrl toRoute navKey model =
    ( model
    , Browser.Navigation.pushUrl navKey <| createUrl toRoute model
    )


createUrl :
    Route.SearchRoute
    -> Model a b
    -> String
createUrl toRoute model =
    let
        justIfNotDefault : t -> t -> Maybe t
        justIfNotDefault fromModel fromDefault =
            if fromModel == fromDefault then
                Nothing

            else
                Just fromModel
    in
    Route.routeToString <|
        toRoute
            { channel = model.urlChannel
            , query = justIfNotDefault model.query defaultSearchArgs.query
            , show = model.show
            , from = justIfNotDefault model.from defaultSearchArgs.from
            , size = justIfNotDefault model.size defaultSearchArgs.size
            , buckets = model.buckets
            , sort =
                justIfNotDefault model.sort defaultSearchArgs.sort
                    |> Maybe.map toSortId
            , type_ = justIfNotDefault model.searchType defaultSearchArgs.searchType
            , activeOptionSource = model.activeOptionSource
            }



-- VIEW


defaultFlakeId : String
defaultFlakeId =
    "group-manual"


sortBy : List Sort
sortBy =
    [ Relevance
    , AlphabeticallyAsc
    , AlphabeticallyDesc
    ]


type alias Terms =
    { field : String
    , size : Int
    , include : Maybe (List String)
    }


toSortTitle : Sort -> String
toSortTitle sort =
    case sort of
        AlphabeticallyAsc ->
            "Alphabetically Ascending"

        AlphabeticallyDesc ->
            "Alphabetically Descending"

        Relevance ->
            "Best Match"


toSortId : Sort -> String
toSortId sort =
    case sort of
        AlphabeticallyAsc ->
            "alpha_asc"

        AlphabeticallyDesc ->
            "alpha_desc"

        Relevance ->
            "relevance"


fromSortId : String -> Maybe Sort
fromSortId id =
    case id of
        "alpha_asc" ->
            Just AlphabeticallyAsc

        "alpha_desc" ->
            Just AlphabeticallyDesc

        "relevance" ->
            Just Relevance

        _ ->
            Nothing


view :
    { categoryName : String
    }
    -> List (Html c)
    -> List NixOSChannel
    -> Model a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> (Msg a b -> c)
    -> List (Html c)
    -> Html c
view { categoryName } title nixosChannels model viewSuccess viewBuckets outMsg searchBuckets =
    let
        resultStatus =
            case model.result of
                RemoteData.NotAsked ->
                    "not-asked"

                RemoteData.Loading ->
                    "loading"

                RemoteData.Success _ ->
                    "success"

                RemoteData.Failure _ ->
                    "failure"
    in
    div
        [ class <| "search-page " ++ resultStatus ]
        ([ h1 [] title
         , viewSearchInput nixosChannels outMsg categoryName (Just model.channel) model.query (Just model.typeahead) model.sort
         ]
            ++ (case model.redirectedChannel of
                    Just oldChannel ->
                        [ p [ class "alert alert-info" ]
                            [ text <| "Channel \"" ++ oldChannel ++ "\" is no longer available. Showing results for \"" ++ model.channel ++ "\" instead."
                            ]
                        ]

                    Nothing ->
                        []
               )
            ++ [ viewResult nixosChannels outMsg categoryName model viewSuccess viewBuckets searchBuckets ]
        )


viewFlakes :
    (Msg a b -> msg)
    -> SearchType
    -> List (Html msg)
viewFlakes outMsg selectedCategory =
    viewBucket
        RadioInput
        "Category"
        (List.map (\cat -> { key = searchTypeToTitle cat, doc_count = 0 }) allTypes)
        (\title ->
            outMsg
                (SubjectChange
                    (if title == "Packages" then
                        PackageSearch

                     else
                        OptionSearch
                    )
                )
        )
        [ searchTypeToTitle selectedCategory ]
        []


viewResult :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> Model a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> List (Html c)
    -> Html c
viewResult nixosChannels outMsg categoryName model viewSuccess viewBuckets searchBuckets =
    case model.result of
        RemoteData.NotAsked ->
            if List.isEmpty searchBuckets then
                div [] []

            else
                div [ class "search-results" ]
                    [ aside [ class "search-sidebar" ] searchBuckets
                    ]

        RemoteData.Loading ->
            case model.previousResult of
                Just prev ->
                    -- Stale-while-revalidating: keep the previous result
                    -- on screen and overlay a small spinner so the page
                    -- doesn't blank out on every re-fetch (e.g. tab
                    -- switch). The view path is the same as Success.
                    let
                        buckets =
                            viewBuckets model.buckets prev
                    in
                    div [ class "search-results", class "loading-overlay" ]
                        [ aside [ class "search-sidebar" ] (searchBuckets ++ buckets)
                        , div []
                            (viewResults nixosChannels model prev viewSuccess outMsg categoryName)
                        ]

                Nothing ->
                    div [ class "loader-wrapper" ]
                        [ aside [ class "search-sidebar" ] searchBuckets
                        , div [ class "loader" ] [ text "Loading..." ]
                        , h2 [] [ text "Searching..." ]
                        ]

        RemoteData.Success result ->
            let
                buckets =
                    viewBuckets model.buckets result
            in
            if result.hits.total.value == 0 && List.isEmpty buckets then
                div [ class "search-results" ]
                    [ aside [ class "search-sidebar" ] searchBuckets
                    , viewNoResults categoryName model.activeOptionSource model.query model.channel
                    ]

            else
                div [ class "search-results" ]
                    [ aside [ class "search-sidebar" ] (searchBuckets ++ buckets)
                    , div []
                        (viewResults nixosChannels model result viewSuccess outMsg categoryName)
                    ]

        RemoteData.Failure error ->
            let
                ( errorTitle, errorMessage ) =
                    case error of
                        Http.BadUrl text ->
                            ( "Bad Url!", text )

                        Http.Timeout ->
                            ( "Timeout!", "Request to the server timeout." )

                        Http.NetworkError ->
                            ( "Network Error!", "A network request to the search backend failed. This is either due to a content blocker or a networking issue." )

                        Http.BadStatus code ->
                            ( "Bad Status", "Server returned " ++ String.fromInt code )

                        Http.BadBody text ->
                            ( "Bad Body", text )
            in
            div []
                [ div [ class "alert alert-error" ]
                    [ h4 [] [ text errorTitle ]
                    , text errorMessage
                    ]
                ]


viewNoResults :
    String
    -> Route.OptionSource
    -> String
    -> String
    -> Html c
viewNoResults categoryName activeOptionSource query channel =
    let
        nixpkgsIssues =
            Html.a [ href ("https://github.com/NixOS/nixpkgs/issues?q=" ++ query) ]
                [ text "search nixpkgs issues" ]

        body =
            if categoryName == "packages" then
                [ text "You might want to "
                , Html.a [ href "https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md#quick-start-to-adding-a-package" ]
                    [ text "add a package" ]
                , text " or "
                , nixpkgsIssues
                , text "."
                ]

            else if categoryName == "modular services" then
                [ text "Not all packages provide modular services. You might want to "
                , nixpkgsIssues
                , text "."
                ]

            else if activeOptionSource == Route.HomeManagerOptionSource then
                let
                    homeManagerIssues =
                        Html.a [ href ("https://github.com/nix-community/home-manager/issues?q=" ++ query) ]
                            [ text "search home-manager issues" ]
                in
                [ text "You might want to ", homeManagerIssues, text "." ]

            else if activeOptionSource == Route.DarwinOptionSource then
                let
                    darwinIssues =
                        Html.a [ href ("https://github.com/nix-darwin/nix-darwin/issues?q=" ++ query) ]
                            [ text "search nix-darwin issues" ]
                in
                [ text "You might want to ", darwinIssues, text "." ]

            else
                [ text "You might want to ", nixpkgsIssues, text "." ]
    in
    div [ class "search-no-results" ]
        (h2 [] [ text <| "No " ++ categoryName ++ " found!" ]
            :: crossSearchHint categoryName query channel
            ++ body
        )


{-| Packages and options live on separate tabs, and it's easy to land on
the wrong one (issue #1062). When a search comes up empty on one, point the
user at the other with the same query and channel carried over.
-}
crossSearchHint : String -> String -> String -> List (Html c)
crossSearchHint categoryName query channel =
    let
        args : Route.SearchArgs
        args =
            { query = Just query
            , channel = Just channel
            , show = Nothing
            , from = Nothing
            , size = Nothing
            , buckets = Nothing
            , sort = Nothing
            , type_ = Nothing
            , activeOptionSource = Route.defaultOptionSource
            }

        hint : String -> String -> Route.Route -> List (Html c)
        hint lead linkText route =
            [ p [ class "search-cross-hint" ]
                [ text lead
                , Html.a [ Route.href route ] [ text linkText ]
                , text " instead."
                ]
            ]
    in
    case categoryName of
        "packages" ->
            hint "Looking for a NixOS option? " ("Search options for " ++ query) (Route.Options args)

        "options" ->
            hint "Looking for a package? " ("Search packages for " ++ query) (Route.Packages args)

        _ ->
            []


closeButton : Html a
closeButton =
    span [] []


type BucketInputType
    = CheckboxInput
    | RadioInput


viewBucket :
    BucketInputType
    -> String
    -> List AggregationsBucketItem
    -> (String -> a)
    -> List String
    -> List (Html a)
    -> List (Html a)
viewBucket inputType title buckets searchMsgFor selectedBucket sets =
    List.append
        sets
        (if List.isEmpty buckets then
            []

         else
            [ fieldset [ class "search-bucket" ]
                (legend [ class "header" ] [ text title ]
                    :: List.map
                        (\bucket ->
                            let
                                isSelected =
                                    List.member bucket.key selectedBucket

                                inputTypeName =
                                    case inputType of
                                        CheckboxInput ->
                                            "checkbox"

                                        RadioInput ->
                                            "radio"
                            in
                            label
                                [ classList [ ( "selected", isSelected ) ]
                                ]
                                [ span [] [ text bucket.key ]
                                , if isSelected || bucket.doc_count <= 0 then
                                    closeButton

                                  else
                                    span [] [ span [ class "badge" ] [ text <| String.fromInt bucket.doc_count ] ]
                                , input
                                    [ type_ inputTypeName
                                    , name title
                                    , checked isSelected
                                    , onClick <| searchMsgFor bucket.key
                                    ]
                                    []
                                ]
                        )
                        buckets
                )
            ]
        )


viewSearchInput :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> Maybe String
    -> String
    -> Maybe Typeahead.Model
    -> Sort
    -> Html c
viewSearchInput nixosChannels outMsg categoryName selectedChannel searchQuery maybeTypeahead currentSort =
    form
        [ onSubmit (outMsg QueryInputSubmit)
        , class "search-input"
        ]
        [ div [ class "search-input-top" ]
            [ div [ class "search-input-with-typeahead" ]
                [ input
                    [ type_ "text"
                    , id "search-query-input"

                    -- not really sure how to make this better, sadly
                    -- TODO: improve me
                    , autocomplete (categoryName == "3rd-party flake packages")
                    , autofocus True
                    , placeholder <| "Search for " ++ categoryName
                    , onInput (outMsg << QueryInput)
                    , onFocus (outMsg TypeaheadFocus)
                    , onBlur (outMsg TypeaheadBlur)
                    , on "keydown"
                        (Json.Decode.field "key" Json.Decode.string
                            |> Json.Decode.andThen
                                (\key ->
                                    if key == "Escape" then
                                        Json.Decode.succeed (outMsg (TypeaheadMsg Typeahead.hide))

                                    else
                                        Json.Decode.fail "not Escape"
                                )
                        )
                    , value searchQuery
                    ]
                    []
                , case maybeTypeahead of
                    Just typeaheadModel ->
                        Html.map (outMsg << TypeaheadMsg) (Typeahead.viewDropdown typeaheadModel)

                    Nothing ->
                        text ""
                ]
            , viewButton [ type_ "submit", class "search-input-submit" ]
                [ text "Search" ]
            ]
        , div [ class "search-input-options" ]
            ((selectedChannel
                |> Maybe.map (\x -> viewChannels nixosChannels outMsg x)
                |> Maybe.withDefault []
             )
                ++ [ Html.map outMsg (viewSortSelection currentSort) ]
            )
        ]


viewChannels :
    List NixOSChannel
    -> (Msg a b -> c)
    -> String
    -> List (Html c)
viewChannels nixosChannels outMsg selectedChannel =
    if List.isEmpty nixosChannels then
        []

    else
        List.append
            [ fieldset
                [ class "radio-group-segmented channel-radios" ]
                (legend [ class "channel-title" ] [ text "Channels:" ]
                    :: List.map
                        (\channel ->
                            label
                                [ classList
                                    [ ( "btn", True )
                                    , ( "channel-radio", True )
                                    , ( "active", channel.id == selectedChannel )
                                    ]
                                ]
                                [ text channel.id
                                , input
                                    [ type_ "radio"
                                    , name "channel"
                                    , checked (channel.id == selectedChannel)
                                    , onClick <| outMsg (ChannelChange channel.id)
                                    ]
                                    []
                                ]
                        )
                        nixosChannels
                )
            ]
            (if List.any (\{ id } -> id == selectedChannel) nixosChannels then
                []

             else
                [ p [ class "alert alert-error" ]
                    [ h4 [] [ text "Wrong channel selected!" ]
                    , text <| "Please select one of the channels above!"
                    ]
                ]
            )


viewResults :
    List NixOSChannel
    -> Model a b
    -> SearchResult a b
    ->
        (List NixOSChannel
         -> String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    -> (Msg a b -> c)
    -> String
    -> List (Html c)
viewResults nixosChannels model result viewSuccess outMsg categoryName =
    let
        from =
            String.fromInt (model.from + 1)

        to =
            String.fromInt
                (if model.from + model.size > result.hits.total.value then
                    result.hits.total.value

                 else
                    model.from + model.size
                )
    in
    [ div []
        [ h2 []
            (List.append
                [ text "Showing results "
                , text from
                , text "-"
                , text to
                , text " of "
                ]
                (if result.hits.total.value == 10000 then
                    [ text "more than 10000."
                    , p [ class "search-refine-hint" ]
                        [ text "Please provide more precise search terms." ]
                    ]

                 else
                    let
                        total =
                            String.fromInt result.hits.total.value
                    in
                    [ strong []
                        [ text total
                        , text " "
                        , text categoryName
                        ]
                    , text "."
                    ]
                )
            )
        , p []
            (case List.head result.hits.hits of
                Nothing ->
                    []

                Just elem ->
                    case Array.get 3 (Array.fromList (String.split "-" elem.index)) of
                        Nothing ->
                            []

                        Just commit ->
                            [ text "Data from nixpkgs "
                            , a [ href ("https://github.com/NixOS/nixpkgs/tree/" ++ commit) ]
                                [ code [] [ text (String.slice 0 8 commit) ] ]
                            , text "."
                            ]
            )
        ]
    , viewSuccess nixosChannels model.channel model.showUsageDetails model.show result.hits.hits
    , Html.map outMsg <| viewPager model result.hits.total.value
    ]


viewSortSelection :
    Sort
    -> Html (Msg a b)
viewSortSelection currentSort =
    Html.node "sort-select-wrapper"
        [ class "btn pull-right sort-container" ]
        [ span [ class "sort-label" ] [ text "Sort: " ]
        , select
            [ id "sort-select"
            , name "sort"
            , class "sort-select"
            , value (toSortId currentSort)
            , onInput
                (\val ->
                    case fromSortId val of
                        Just s ->
                            SortChange s

                        Nothing ->
                            NoOp
                )
            ]
            (List.map
                (\sort ->
                    option
                        [ value (toSortId sort) ]
                        [ text <| toSortTitle sort ]
                )
                sortBy
            )
        ]


viewPager :
    Model a b
    -> Int
    -> Html (Msg a b)
viewPager model total =
    div []
        [ ul [ class "pager" ]
            [ li []
                [ viewButton
                    [ disabled (model.from == 0)
                    , onClick <|
                        if model.from == 0 then
                            NoOp

                        else
                            ChangePage 0
                    ]
                    [ text "First" ]
                ]
            , li []
                [ viewButton
                    [ disabled (model.from == 0)
                    , onClick <|
                        if model.from - model.size < 0 then
                            NoOp

                        else
                            ChangePage <| model.from - model.size
                    ]
                    [ text "Previous" ]
                ]
            , li []
                [ viewButton
                    [ disabled (model.from + model.size >= total)
                    , onClick <|
                        if model.from + model.size >= total then
                            NoOp

                        else
                            ChangePage <| model.from + model.size
                    ]
                    [ text "Next" ]
                ]
            , li []
                [ viewButton
                    [ disabled (model.from + model.size >= total)
                    , onClick <|
                        if model.from + model.size >= total then
                            NoOp

                        else
                            let
                                remainder =
                                    if remainderBy model.size total == 0 then
                                        1

                                    else
                                        0
                            in
                            ChangePage <| ((total // model.size) - remainder) * model.size
                    ]
                    [ text "Last" ]
                ]
            ]
        ]



-- API


type alias Options =
    { mappingSchemaVersion : Int
    , url : String
    , username : String
    , password : String
    }


makeRequest :
    Http.Body
    -> List NixOSChannel
    -> String
    -> Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Options
    -> (RemoteData.WebData (SearchResult a b) -> Msg a b)
    -> Maybe String
    -> Cmd (Msg a b)
makeRequest body nixosChannels channel decodeResultItemSource decodeResultAggregations options responseMsg tracker =
    let
        branch : String
        branch =
            nixosChannels
                |> List.filter (\x -> x.id == channel)
                |> List.head
                |> Maybe.map (\x -> x.branch)
                |> Maybe.withDefault channel

        index =
            "latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ branch
    in
    Http.riskyRequest
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = body
        , expect =
            Http.expectJson
                (RemoteData.fromResult >> responseMsg)
                (decodeResult decodeResultItemSource decodeResultAggregations)
        , timeout = Nothing
        , tracker = tracker
        }


{-| Task-returning variant of `makeRequest` so callers can combine several
HTTP requests into a single Cmd via `Task.sequence` / `Task.map`. Used by
the Options page to fan out one ES request per included source and merge
the responses into a single `SearchResult` before delivering it to the
search update flow.
-}
makeRequestTask :
    Http.Body
    -> List NixOSChannel
    -> String
    -> Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Options
    -> Task.Task Http.Error (SearchResult a b)
makeRequestTask body nixosChannels channel decodeResultItemSource decodeResultAggregations options =
    let
        branch : String
        branch =
            nixosChannels
                |> List.filter (\x -> x.id == channel)
                |> List.head
                |> Maybe.map (\x -> x.branch)
                |> Maybe.withDefault channel

        index =
            "latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ branch
    in
    -- `request_cache=true` opts these federated per-source queries into ES's
    -- shard request cache. The cache is normally only used for `size:0`
    -- aggregations; opting in is safe here because each query body is
    -- byte-stable across users (only the user query varies), making cache
    -- hits real and useful. Index refreshes invalidate automatically.
    Http.riskyTask
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))
            ]
        , url = options.url ++ "/" ++ index ++ "/_search?request_cache=true"
        , body = body
        , resolver =
            Http.stringResolver <|
                \response ->
                    case response of
                        Http.GoodStatus_ _ s ->
                            Json.Decode.decodeString
                                (decodeResult decodeResultItemSource decodeResultAggregations)
                                s
                                |> Result.mapError (Json.Decode.errorToString >> Http.BadBody)

                        Http.BadStatus_ meta _ ->
                            Err (Http.BadStatus meta.statusCode)

                        Http.NetworkError_ ->
                            Err Http.NetworkError

                        Http.Timeout_ ->
                            Err Http.Timeout

                        Http.BadUrl_ url ->
                            Err (Http.BadUrl url)
        , timeout = Nothing
        }



-- JSON


decodeResult :
    Json.Decode.Decoder a
    -> Json.Decode.Decoder b
    -> Json.Decode.Decoder (SearchResult a b)
decodeResult decodeResultItemSource decodeResultAggregations =
    Json.Decode.map2 SearchResult
        (Json.Decode.field "hits" (decodeResultHits decodeResultItemSource))
        (Json.Decode.field "aggregations" decodeResultAggregations)


decodeResultHits : Json.Decode.Decoder a -> Json.Decode.Decoder (ResultHits a)
decodeResultHits decodeResultItemSource =
    Json.Decode.map3 ResultHits
        (Json.Decode.field "total" decodeResultHitsTotal)
        (Json.Decode.field "max_score" (Json.Decode.nullable Json.Decode.float))
        (Json.Decode.field "hits" (Json.Decode.list (decodeResultItem decodeResultItemSource)))


decodeResultHitsTotal : Json.Decode.Decoder ResultHitsTotal
decodeResultHitsTotal =
    Json.Decode.map2 ResultHitsTotal
        (Json.Decode.field "value" Json.Decode.int)
        (Json.Decode.field "relation" Json.Decode.string)


decodeResultItem : Json.Decode.Decoder a -> Json.Decode.Decoder (ResultItem a)
decodeResultItem decodeResultItemSource =
    Json.Decode.map6 ResultItem
        (Json.Decode.field "_index" Json.Decode.string)
        (Json.Decode.field "_id" Json.Decode.string)
        (Json.Decode.field "_score" (Json.Decode.nullable Json.Decode.float))
        (Json.Decode.field "_source" decodeResultItemSource)
        (Json.Decode.maybe (Json.Decode.field "text" Json.Decode.string))
        (Json.Decode.maybe (Json.Decode.field "matched_queries" (Json.Decode.list Json.Decode.string)))


decodeAggregation : Json.Decode.Decoder Aggregation
decodeAggregation =
    Json.Decode.map3 Aggregation
        (Json.Decode.field "doc_count_error_upper_bound" Json.Decode.int)
        (Json.Decode.field "sum_other_doc_count" Json.Decode.int)
        (Json.Decode.field "buckets" (Json.Decode.list decodeAggregationBucketItem))


decodeAggregationBucketItem : Json.Decode.Decoder AggregationsBucketItem
decodeAggregationBucketItem =
    Json.Decode.map2 AggregationsBucketItem
        (Json.Decode.field "doc_count" Json.Decode.int)
        (Json.Decode.field "key" Json.Decode.string)



-- Html Helper elemetnts


showMoreButton : msg -> Bool -> Html msg
showMoreButton toggle isOpen =
    div [ class "result-item-show-more-wrapper" ]
        [ a
            [ href "#"
            , onClick toggle
            , class "result-item-show-more"
            ]
            [ text <|
                if isOpen then
                    "▲▲▲ Hide package details ▲▲▲"

                else
                    "▾▾▾ Show more package details ▾▾▾"
            ]
        ]



-- Html Event Helpers


onClickStop : msg -> Html.Attribute msg
onClickStop message =
    Html.Events.custom "click" <|
        Json.Decode.succeed
            { message = message
            , stopPropagation = True
            , preventDefault = True
            }


trapClick : Html.Attribute (Msg a b)
trapClick =
    Html.Events.stopPropagationOn "click" <|
        Json.Decode.succeed ( NoOp, True )
