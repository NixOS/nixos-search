module Search.Typeahead exposing
    ( Model
    , Msg
    , focusModel
    , hide
    , hideAfterBlur
    , hideModel
    , init
    , queryChanged
    , update
    , viewDropdown
    )

{-| Per-keystroke suggestion dropdown.

Supports two backends, selected per `(searchType, activeOptionSource)`:

  - `EsBacked` — debounced request to ES `*.edge` subfields; used for
    NixOS options, packages, and any source without a static corpus.
  - `StaticBacked` — one-time JSON fetch from `/autocomplete/<key>.json`,
    then pure client-side multi-word ranking; used for Modular Services
    and Home Manager options to avoid per-keystroke ES queries.

When `preferStatic` is `False` (save-data / slow connection), Modular
Services and Home Manager sources fall back to `EsBacked` instead of
fetching a multi-MB corpus; per-keystroke ES bytes are lower than one
large download for users who run only a handful of searches.

-}

import Base64
import Dict exposing (Dict)
import Html exposing (Html, a, li, span, text, ul)
import Html.Attributes exposing (class, href)
import Http
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Process
import Route exposing (OptionSource(..), SearchType(..), optionSourceDocType, optionSourceId)
import Set exposing (Set)
import Task



-- TYPES
--
-- Row-polymorphic `Options` and `Channel` avoid importing the concrete
-- `Search` module (which would form an import cycle).


type alias Options r =
    { r
        | mappingSchemaVersion : Int
        , url : String
        , username : String
        , password : String
    }


type alias Channel r =
    { r | id : String, branch : String }


type Backend
    = EsBacked
    | StaticBacked StaticKey


{-| Cache key: category name ("services", "hm") × channel id.
Tuples of `String` are `comparable` so they work as `Dict`/`Set` keys.
-}
type alias StaticKey =
    ( String, String )


type alias Corpus =
    List Item


type alias Item =
    { name : String
    , navigateTo : String
    }


type alias Suggestion =
    { primary : String
    , navigateTo : String
    }



-- MODEL


type alias Model =
    { token : Int
    , suggestions : List Suggestion
    , preferStatic : Bool
    , visible : Bool
    , corpora : Dict StaticKey Corpus
    , loading : Set StaticKey
    }


init : Bool -> Model
init preferStatic =
    { token = 0
    , suggestions = []
    , preferStatic = preferStatic
    , visible = False
    , corpora = Dict.empty
    , loading = Set.empty
    }



-- DEBOUNCE
--
-- Longer debounce and 3-char minimum keep load on the shared ES instance
-- modest. Static-backed sources ignore the debounce (no network cost).


debounceMs : Float
debounceMs =
    250


minQueryLength : Int
minQueryLength =
    3


maxResults : Int
maxResults =
    8



-- BACKEND SELECTION


backendFor : Bool -> SearchType -> OptionSource -> String -> Backend
backendFor preferStatic searchType source channel =
    case ( preferStatic, searchType, source ) of
        ( True, OptionSearch, ModularServiceOptions ) ->
            StaticBacked ( "services", channel )

        ( True, OptionSearch, HomeManagerOptionSource ) ->
            StaticBacked ( "hm", channel )

        _ ->
            EsBacked



-- UPDATE


type Msg
    = Fire Int
    | Response Int (Result Http.Error (List Suggestion))
    | Loaded StaticKey (Result Http.Error Corpus)
    | Hide


hide : Msg
hide =
    Hide


hideModel : Model -> Model
hideModel m =
    { m | visible = False }


focusModel : Model -> Model
focusModel m =
    if not (List.isEmpty m.suggestions) then
        { m | visible = True }

    else
        m


hideAfterBlur : Cmd Msg
hideAfterBlur =
    Process.sleep 200 |> Task.perform (\_ -> Hide)


queryChanged :
    Options r
    -> List (Channel c)
    -> SearchType
    -> OptionSource
    -> String
    -> String
    -> Model
    -> ( Model, Cmd Msg )
queryChanged options nixosChannels searchType activeSource channel query model =
    let
        trimmed =
            String.trim query

        nextToken =
            model.token + 1
    in
    if String.length trimmed < minQueryLength then
        ( { model | token = nextToken, suggestions = [], visible = False }
        , Cmd.none
        )

    else
        case backendFor model.preferStatic searchType activeSource channel of
            EsBacked ->
                ( { model | token = nextToken, visible = True }
                , Process.sleep debounceMs |> Task.perform (\_ -> Fire nextToken)
                )

            StaticBacked key ->
                case Dict.get key model.corpora of
                    Just corpus ->
                        let
                            ranked =
                                rankCorpus trimmed corpus
                        in
                        ( { model
                            | token = nextToken
                            , suggestions = ranked
                            , visible = not (List.isEmpty ranked)
                          }
                        , Cmd.none
                        )

                    Nothing ->
                        let
                            fetchCmd =
                                if Set.member key model.loading then
                                    Cmd.none

                                else
                                    fetchCorpus key
                        in
                        ( { model
                            | token = nextToken
                            , loading = Set.insert key model.loading
                          }
                        , fetchCmd
                        )


update :
    Options r
    -> List (Channel c)
    -> SearchType
    -> OptionSource
    -> String
    -> String
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update options nixosChannels searchType activeSource channel query msg model =
    case msg of
        Fire token ->
            if token /= model.token then
                ( model, Cmd.none )

            else
                ( model, fetch options nixosChannels searchType activeSource channel query token )

        Response token result ->
            if token /= model.token then
                ( model, Cmd.none )

            else
                case result of
                    Ok suggestions ->
                        ( { model | suggestions = suggestions, visible = True }, Cmd.none )

                    Err _ ->
                        ( { model | suggestions = [], visible = False }, Cmd.none )

        Loaded key result ->
            let
                corpus =
                    Result.withDefault [] result

                newModel =
                    { model
                        | corpora = Dict.insert key corpus model.corpora
                        , loading = Set.remove key model.loading
                    }

                trimmed =
                    String.trim query
            in
            -- Re-rank immediately if this corpus is the one the current query would use.
            if String.length trimmed >= minQueryLength && backendFor model.preferStatic searchType activeSource channel == StaticBacked key then
                let
                    ranked =
                        rankCorpus trimmed corpus
                in
                ( { newModel | suggestions = ranked, visible = not (List.isEmpty ranked) }
                , Cmd.none
                )

            else
                ( newModel, Cmd.none )

        Hide ->
            ( { model | visible = False }, Cmd.none )



-- VIEW


viewDropdown : Model -> Html msg
viewDropdown model =
    if not model.visible || List.isEmpty model.suggestions then
        text ""

    else
        ul [ class "typeahead-suggestions" ]
            (List.map viewSuggestion model.suggestions)


viewSuggestion : Suggestion -> Html msg
viewSuggestion s =
    li [ class "typeahead-item" ]
        [ a [ href s.navigateTo ]
            [ span [ class "typeahead-primary" ] [ text s.primary ]
            ]
        ]



-- STATIC CORPUS


fetchCorpus : StaticKey -> Cmd Msg
fetchCorpus (( category, channel ) as key) =
    Http.get
        { url = "/autocomplete/" ++ category ++ "-" ++ channel ++ ".json"
        , expect = Http.expectJson (Loaded key) (decodeCorpus category channel)
        }


decodeCorpus : String -> String -> Json.Decode.Decoder Corpus
decodeCorpus category channel =
    Json.Decode.list (decodeItem category channel)


decodeItem : String -> String -> Json.Decode.Decoder Item
decodeItem category channel =
    Json.Decode.map
        (\name ->
            let
                src =
                    case category of
                        "services" ->
                            ModularServiceOptions

                        "hm" ->
                            HomeManagerOptionSource

                        _ ->
                            NixosOptions

                sourceSuffix =
                    if src == NixosOptions then
                        ""

                    else
                        "&source=" ++ optionSourceId src

                showPrefix =
                    optionSourceDocType src ++ ":"
            in
            { name = name
            , navigateTo =
                "/options?channel=" ++ channel ++ "&show=" ++ showPrefix ++ name ++ "&query=" ++ name ++ sourceSuffix
            }
        )
        (Json.Decode.field "name" Json.Decode.string)



-- CLIENT-SIDE RANKING
--
-- Tokenise the query on whitespace; every token must match the item.
-- Dot-segment prefix is the high-value match for NixOS-shaped names
-- like `services.php-fpm.user`.


rankCorpus : String -> Corpus -> List Suggestion
rankCorpus query corpus =
    let
        tokens =
            query
                |> String.toLower
                |> String.words
    in
    corpus
        |> List.filterMap
            (\item ->
                score tokens item
                    |> Maybe.map (\s -> ( s, item ))
            )
        |> List.sortWith (\( s1, _ ) ( s2, _ ) -> compare s2 s1)
        |> List.take maxResults
        |> List.map
            (\( _, item ) ->
                { primary = item.name
                , navigateTo = item.navigateTo
                }
            )


score : List String -> Item -> Maybe Int
score tokens item =
    let
        nameLower =
            String.toLower item.name

        perToken tok =
            if nameLower == tok then
                Just 100

            else if String.startsWith tok nameLower then
                Just 80

            else if prefixOfSegment tok nameLower then
                Just 60

            else if String.contains tok nameLower then
                Just 40

            else
                Nothing

        results =
            List.map perToken tokens
    in
    if List.any ((==) Nothing) results then
        Nothing

    else
        results
            |> List.filterMap identity
            |> List.sum
            |> Just


prefixOfSegment : String -> String -> Bool
prefixOfSegment tok name =
    String.split "." name
        |> List.any (String.startsWith tok)



-- ES-BACKED HTTP


fetch :
    Options r
    -> List (Channel c)
    -> SearchType
    -> OptionSource
    -> String
    -> String
    -> Int
    -> Cmd Msg
fetch options nixosChannels searchType source channel query token =
    let
        branch =
            nixosChannels
                |> List.filter (\c -> c.id == channel)
                |> List.head
                |> Maybe.map .branch
                |> Maybe.withDefault channel

        index =
            "latest-" ++ String.fromInt options.mappingSchemaVersion ++ "-" ++ branch

        body =
            requestBody searchType (String.trim query)
    in
    Http.riskyRequest
        { method = "POST"
        , headers =
            [ Http.header "Authorization"
                ("Basic " ++ Base64.encode (options.username ++ ":" ++ options.password))

            -- Tag typeahead traffic so it can be split from main search in
            -- nginx logs / ES audits and rate-limited without a redeploy.
            , Http.header "X-Typeahead" "1"
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = body
        , expect = Http.expectJson (Response token) (decodeSuggestions searchType source channel)
        , timeout = Just 4000
        , tracker = Just "typeahead"
        }


requestBody : SearchType -> String -> Http.Body
requestBody searchType query =
    let
        ( typeFilter, mainFields, fields ) =
            case searchType of
                PackageSearch ->
                    ( "package"
                    , [ "package_attr_name" ]
                    , [ ( "package_attr_name", 9.0 )
                      , ( "package_pname", 6.0 )
                      , ( "package_programs", 6.0 )
                      ]
                    )

                OptionSearch ->
                    ( "option"
                    , [ "option_name", "option_name_query" ]
                    , [ ( "option_name", 6.0 )
                      , ( "option_name_query", 6.0 )
                      ]
                    )

        ( negativeWords, positiveWords ) =
            String.toLower query
                |> String.words
                |> List.partition (String.startsWith "-")
                |> Tuple.mapFirst (List.map (String.dropLeft 1))

        dashUnderscoreVariants word =
            Set.toList
                (Set.fromList
                    [ String.replace "_" "-" word
                    , String.replace "-" "_" word
                    , word
                    ]
                )

        toWildcardQuery mainField queryWord =
            [ ( "wildcard"
              , Json.Encode.object
                    [ ( mainField
                      , Json.Encode.object
                            [ ( "value", Json.Encode.string ("*" ++ queryWord ++ "*") )
                            , ( "case_insensitive", Json.Encode.bool True )
                            ]
                      )
                    ]
              )
            ]

        allFields =
            List.concatMap
                (\( field, boost ) ->
                    [ field ++ "^" ++ String.fromFloat boost
                    , field ++ ".*^" ++ String.fromFloat (boost * 0.6)
                    ]
                )
                fields

        queryWordsWildCard =
            positiveWords
                |> List.concatMap dashUnderscoreVariants
                |> Set.fromList
                |> Set.toList

        multiMatchQuery =
            [ ( "multi_match"
              , Json.Encode.object
                    [ ( "type", Json.Encode.string "cross_fields" )
                    , ( "query", Json.Encode.string (String.join " " positiveWords) )
                    , ( "analyzer", Json.Encode.string "whitespace" )
                    , ( "auto_generate_synonyms_phrase_query", Json.Encode.bool False )
                    , ( "operator", Json.Encode.string "and" )
                    , ( "_name", Json.Encode.string ("multi_match_" ++ String.join "_" positiveWords) )
                    , ( "fields", Json.Encode.list Json.Encode.string allFields )
                    ]
              )
            ]

        searchQueries =
            multiMatchQuery
                :: List.concatMap
                    (\mf -> List.map (toWildcardQuery mf) queryWordsWildCard)
                    mainFields

        mustNotQueries =
            negativeWords
                |> List.concatMap dashUnderscoreVariants
                |> Set.fromList
                |> Set.toList
                |> List.concatMap (\w -> List.map (\mf -> toWildcardQuery mf w) mainFields)
    in
    Http.jsonBody
        (Json.Encode.object
            [ ( "from", Json.Encode.int 0 )
            , ( "size", Json.Encode.int maxResults )
            , ( "query"
              , Json.Encode.object
                    [ ( "bool"
                      , Json.Encode.object
                            [ ( "filter"
                              , Json.Encode.list Json.Encode.object
                                    [ [ ( "term"
                                        , Json.Encode.object
                                            [ ( "type", Json.Encode.string typeFilter ) ]
                                        )
                                      ]
                                    ]
                              )
                            , ( "must_not"
                              , Json.Encode.list Json.Encode.object mustNotQueries
                              )
                            , ( "must"
                              , Json.Encode.list Json.Encode.object
                                    [ [ ( "dis_max"
                                        , Json.Encode.object
                                            [ ( "tie_breaker", Json.Encode.float 0.7 )
                                            , ( "queries"
                                              , Json.Encode.list Json.Encode.object searchQueries
                                              )
                                            ]
                                        )
                                      ]
                                    ]
                              )
                            ]
                      )
                    ]
              )
            ]
        )


decodeSuggestions : SearchType -> OptionSource -> String -> Json.Decode.Decoder (List Suggestion)
decodeSuggestions searchType source channel =
    Json.Decode.at [ "hits", "hits" ]
        (Json.Decode.list (decodeHit searchType source channel))


decodeHit : SearchType -> OptionSource -> String -> Json.Decode.Decoder Suggestion
decodeHit searchType source channel =
    Json.Decode.field "_source" (decodeSource searchType source channel)


decodeSource : SearchType -> OptionSource -> String -> Json.Decode.Decoder Suggestion
decodeSource searchType source channel =
    case searchType of
        PackageSearch ->
            Json.Decode.map
                (\attr ->
                    { primary = attr
                    , navigateTo =
                        "/packages?channel=" ++ channel ++ "&show=" ++ attr ++ "&query=" ++ attr
                    }
                )
                (Json.Decode.field "package_attr_name" Json.Decode.string)

        OptionSearch ->
            let
                sourceSuffix =
                    if source == NixosOptions then
                        ""

                    else
                        "&source=" ++ optionSourceId source
            in
            Json.Decode.map
                (\name ->
                    { primary = name
                    , navigateTo =
                        "/options?channel=" ++ channel ++ "&show=" ++ optionSourceDocType source ++ ":" ++ name ++ "&query=" ++ name ++ sourceSuffix
                    }
                )
                (Json.Decode.field "option_name" Json.Decode.string)
