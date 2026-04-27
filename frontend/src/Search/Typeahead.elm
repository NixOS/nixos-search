module Search.Typeahead exposing
    ( Model
    , Msg
    , disabled
    , focusModel
    , hide
    , hideAfterBlur
    , hideModel
    , init
    , queryChanged
    , update
    , viewDropdown
    )

{-| Per-keystroke suggestion dropdown with two backends.

Static assets are preferred where available: `/autocomplete/<source>-<channel>.json`
is fetched once per session (where `<source>` is the `optionSourceId`, e.g.
`home_manager` or `modular_service`) and searched client-side with multi-word
ranking. This covers Modular Services and Home Manager options without touching
the Elasticsearch instance -- cheap on metered networks.

For the categories the static corpus does not cover (Packages and NixOS Options)
we fall back to a small debounced Elasticsearch query against the existing
`*.edge` ngram subfields, with a stale-token drop.

When `preferStatic` is `False` (save-data / slow connection) both backends are a
no-op and `viewDropdown` renders nothing, so behavior matches the pre-change
submit-on-enter UX.

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
import Regex
import Route exposing (OptionSource(..), SearchType(..))
import Set exposing (Set)
import Task
import Url



-- TYPES
--
-- Function signatures use record-extension types instead of importing the
-- concrete `Search.Options` / `Search.NixOSChannel`, so this module does
-- not need to depend on `Search` (which would form an import cycle).


type alias Options r =
    { r
        | mappingSchemaVersion : Int
        , url : String
        , username : String
        , password : String
    }


type alias Channel r =
    { r | id : String, branch : String }


{-| Cache key: `optionSourceId` × channel id (e.g. `"home_manager"` × `"25.11"`).
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
    , secondary : Maybe String
    , navigateTo : String
    }



-- MODEL


type alias Model =
    { suggestions : List Suggestion
    , preferStatic : Bool
    , visible : Bool
    , corpora : Dict StaticKey Corpus
    , loading : Set StaticKey
    , token : Int
    }


init : Bool -> Model
init preferStatic =
    { suggestions = []
    , preferStatic = preferStatic
    , visible = False
    , corpora = Dict.empty
    , loading = Set.empty
    , token = 0
    }


disabled : Model -> Bool
disabled m =
    not m.preferStatic



-- CONSTANTS


minQueryLength : Int
minQueryLength =
    3


maxResults : Int
maxResults =
    8


debounceMs : Float
debounceMs =
    150



-- BACKEND SELECTION


{-| Categories the static corpus covers get a `Just` key; everything else
(`NixosOptions` and all package searches) returns `Nothing` and falls through
to the Elasticsearch backend.
-}
staticKeyFor : SearchType -> OptionSource -> String -> Maybe StaticKey
staticKeyFor searchType source channel =
    case searchType of
        OptionSearch ->
            case source of
                NixosOptions ->
                    Nothing

                _ ->
                    Just ( Route.optionSourceId source, channel )

        _ ->
            Nothing



-- UPDATE


type Msg
    = Loaded StaticKey (Result Http.Error Corpus)
    | Fire Int
    | Response Int (Result Http.Error (List Suggestion))
    | Hide


{-| Synchronous "close the dropdown now" message -- for submit and Escape.
-}
hide : Msg
hide =
    Hide


{-| Direct model update equivalent to dispatching `hide`. Useful when the
parent already has the model in hand and would rather not round-trip
through `update` for context arguments it doesn't have.
-}
hideModel : Model -> Model
hideModel m =
    { m | visible = False }


{-| Re-show the dropdown if we already have suggestions cached. Called on
input focus so the user can see prior matches without retyping.
-}
focusModel : Model -> Model
focusModel m =
    if m.preferStatic && not (List.isEmpty m.suggestions) then
        { m | visible = True }

    else
        m


{-| Delayed "close the dropdown" message -- for blur. The delay gives the
browser time to dispatch a click on a suggestion link before we tear it
down (otherwise the click target is gone before navigation triggers).
-}
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
    if not model.preferStatic then
        ( model, Cmd.none )

    else
        case staticKeyFor searchType activeSource channel of
            Just key ->
                let
                    trimmed =
                        String.trim query
                in
                if String.length trimmed < minQueryLength then
                    ( { model | suggestions = [], visible = False }
                    , Cmd.none
                    )

                else
                    case Dict.get key model.corpora of
                        Just corpus ->
                            let
                                ranked =
                                    rankCorpus trimmed corpus
                            in
                            ( { model
                                | suggestions = ranked
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
                            ( { model | loading = Set.insert key model.loading }
                            , fetchCmd
                            )

            Nothing ->
                -- Elasticsearch fallback: debounce with a stale-token drop.
                let
                    trimmed =
                        String.trim query

                    nextToken =
                        model.token + 1
                in
                if String.length trimmed < 2 then
                    ( { model | token = nextToken, suggestions = [], visible = False }
                    , Cmd.none
                    )

                else
                    ( { model | token = nextToken, visible = True }
                    , Process.sleep debounceMs |> Task.perform (\_ -> Fire nextToken)
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
        Loaded key result ->
            case result of
                Err _ ->
                    ( { model | loading = Set.remove key model.loading }
                    , Cmd.none
                    )

                Ok corpus ->
                    let
                        newModel =
                            { model
                                | corpora = Dict.insert key corpus model.corpora
                                , loading = Set.remove key model.loading
                            }

                        trimmed =
                            String.trim query
                    in
                    -- Re-rank immediately if this corpus is the one the current query would use.
                    if String.length trimmed >= minQueryLength && staticKeyFor searchType activeSource channel == Just key then
                        let
                            ranked =
                                rankCorpus trimmed corpus
                        in
                        ( { newModel | suggestions = ranked, visible = not (List.isEmpty ranked) }
                        , Cmd.none
                        )

                    else
                        ( newModel, Cmd.none )

        Fire token ->
            if token /= model.token then
                ( model, Cmd.none )

            else
                ( model, fetch options nixosChannels searchType channel query token )

        Response token result ->
            if token /= model.token then
                ( model, Cmd.none )

            else
                case result of
                    Ok suggestions ->
                        ( { model | suggestions = suggestions, visible = True }, Cmd.none )

                    Err _ ->
                        ( { model | suggestions = [], visible = False }, Cmd.none )

        Hide ->
            ( { model | visible = False }, Cmd.none )



-- VIEW


viewDropdown : Model -> Html msg
viewDropdown model =
    if not model.preferStatic || not model.visible || List.isEmpty model.suggestions then
        text ""

    else
        ul [ class "typeahead-suggestions" ]
            (List.map viewSuggestion model.suggestions)


viewSuggestion : Suggestion -> Html msg
viewSuggestion s =
    li [ class "typeahead-item" ]
        [ a [ href s.navigateTo ]
            [ span [ class "typeahead-primary" ] [ text s.primary ]
            , case s.secondary of
                Just sec ->
                    span [ class "typeahead-secondary" ] [ text sec ]

                Nothing ->
                    text ""
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
    let
        docType =
            case category of
                "home_manager" ->
                    "home-manager-option"

                "modular_service" ->
                    "service"

                _ ->
                    "option"
    in
    Json.Decode.map
        (\name ->
            let
                parentQuery =
                    case List.reverse (String.split "." name) of
                        _ :: rest ->
                            if List.isEmpty rest then
                                name

                            else
                                rest |> List.reverse |> String.join "."

                        [] ->
                            name
            in
            { name = name
            , navigateTo =
                "/options?channel=" ++ channel ++ "&source=" ++ category ++ "&query=" ++ parentQuery ++ "#show=" ++ docType ++ ":" ++ name
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
                , secondary = Nothing
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



-- ELASTICSEARCH FALLBACK


fetch :
    Options r
    -> List (Channel c)
    -> SearchType
    -> String
    -> String
    -> Int
    -> Cmd Msg
fetch options nixosChannels searchType channel query token =
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
            ]
        , url = options.url ++ "/" ++ index ++ "/_search"
        , body = body
        , expect = Http.expectJson (Response token) (decodeSuggestions searchType channel)
        , timeout = Just 4000
        , tracker = Just "typeahead"
        }


requestBody : SearchType -> String -> Http.Body
requestBody searchType query =
    let
        ( typeFilter, edgeFields ) =
            case searchType of
                PackageSearch ->
                    ( "package"
                    , [ ( "package_attr_name.edge", 4.0 )
                      , ( "package_pname.edge", 3.0 )
                      , ( "package_description.edge", 0.5 )
                      ]
                    )

                OptionSearch ->
                    ( "option"
                    , [ ( "option_name.edge", 4.0 )
                      , ( "option_description.edge", 0.5 )
                      ]
                    )

        fieldsArray =
            edgeFields
                |> List.map (\( f, b ) -> f ++ "^" ++ String.fromFloat b)
    in
    Http.jsonBody
        (Json.Encode.object
            [ ( "from", Json.Encode.int 0 )
            , ( "size", Json.Encode.int maxResults )
            , ( "_source"
              , Json.Encode.list Json.Encode.string
                    [ "type"
                    , "package_attr_name"
                    , "package_pname"
                    , "package_description"
                    , "option_name"
                    , "option_description"
                    ]
              )
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
                            , ( "must"
                              , Json.Encode.list Json.Encode.object
                                    [ [ ( "multi_match"
                                        , Json.Encode.object
                                            [ ( "query", Json.Encode.string query )
                                            , ( "type", Json.Encode.string "best_fields" )
                                            , ( "operator", Json.Encode.string "and" )
                                            , ( "fields", Json.Encode.list Json.Encode.string fieldsArray )
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


decodeSuggestions : SearchType -> String -> Json.Decode.Decoder (List Suggestion)
decodeSuggestions searchType channel =
    Json.Decode.at [ "hits", "hits" ]
        (Json.Decode.list (decodeHit searchType channel))


decodeHit : SearchType -> String -> Json.Decode.Decoder Suggestion
decodeHit searchType channel =
    Json.Decode.field "_source" (decodeSource searchType channel)


decodeSource : SearchType -> String -> Json.Decode.Decoder Suggestion
decodeSource searchType channel =
    case searchType of
        PackageSearch ->
            Json.Decode.succeed
                (\attr pname description ->
                    { primary = attr
                    , secondary =
                        if attr == pname || pname == "" then
                            Maybe.map stripHtml description

                        else
                            Just pname
                    , navigateTo =
                        "/packages?channel=" ++ channel ++ "&query=" ++ attr ++ "#show=" ++ Url.percentEncode attr
                    }
                )
                |> Json.Decode.Pipeline.required "package_attr_name" Json.Decode.string
                |> Json.Decode.Pipeline.optional "package_pname" Json.Decode.string ""
                |> Json.Decode.Pipeline.optional "package_description"
                    (Json.Decode.map Just Json.Decode.string)
                    Nothing

        OptionSearch ->
            Json.Decode.succeed
                (\name description ->
                    { primary = name
                    , secondary = Maybe.map stripHtml description
                    , navigateTo =
                        "/options?channel=" ++ channel ++ "&query=" ++ name ++ "#show=option:" ++ name
                    }
                )
                |> Json.Decode.Pipeline.required "option_name" Json.Decode.string
                |> Json.Decode.Pipeline.optional "option_description"
                    (Json.Decode.map Just Json.Decode.string)
                    Nothing


{-| Description fields come pre-rendered as HTML (e.g. `<rendered-html><p>…</p></rendered-html>`).
The dropdown is plain text, so strip tags and collapse whitespace before display.
-}
stripHtml : String -> String
stripHtml s =
    let
        tagRegex =
            Regex.fromString "<[^>]*>"
                |> Maybe.withDefault Regex.never

        wsRegex =
            Regex.fromString "\\s+"
                |> Maybe.withDefault Regex.never
    in
    s
        |> Regex.replace tagRegex (\_ -> " ")
        |> Regex.replace wsRegex (\_ -> " ")
        |> String.trim
