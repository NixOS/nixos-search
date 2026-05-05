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

{-| Per-keystroke suggestion dropdown backed by static JSON corpora.

Fetches `/autocomplete/<category>-<channel>.json` once per session and
searches client-side with multi-word ranking. Currently covers Modular
Services and Home Manager options.

When `enabled` is `False` (save-data / slow connection) every call is a
no-op and `viewDropdown` renders nothing.

-}

import Dict exposing (Dict)
import Html exposing (Html, a, li, span, text, ul)
import Html.Attributes exposing (class, href)
import Http
import Json.Decode
import Process
import Route exposing (OptionSource(..), SearchType(..))
import Set exposing (Set)
import Task



-- TYPES


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
    { suggestions : List Suggestion
    , preferStatic : Bool
    , visible : Bool
    , corpora : Dict StaticKey Corpus
    , loading : Set StaticKey
    }


init : Bool -> Model
init preferStatic =
    { suggestions = []
    , preferStatic = preferStatic
    , visible = False
    , corpora = Dict.empty
    , loading = Set.empty
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



-- BACKEND SELECTION


staticKeyFor : SearchType -> OptionSource -> String -> Maybe StaticKey
staticKeyFor searchType source channel =
    case ( searchType, source ) of
        ( OptionSearch, ModularServiceOptions ) ->
            Just ( "services", channel )

        ( OptionSearch, HomeManagerOptionSource ) ->
            Just ( "hm", channel )

        _ ->
            Nothing



-- UPDATE


type Msg
    = Loaded StaticKey (Result Http.Error Corpus)
    | Hide


hide : Msg
hide =
    Hide


hideModel : Model -> Model
hideModel m =
    { m | visible = False }


focusModel : Model -> Model
focusModel m =
    if m.preferStatic && not (List.isEmpty m.suggestions) then
        { m | visible = True }

    else
        m


hideAfterBlur : Cmd Msg
hideAfterBlur =
    Process.sleep 200 |> Task.perform (\_ -> Hide)


queryChanged :
    SearchType
    -> OptionSource
    -> String
    -> String
    -> Model
    -> ( Model, Cmd Msg )
queryChanged searchType activeSource channel query model =
    if not model.preferStatic then
        ( model, Cmd.none )

    else
        let
            trimmed =
                String.trim query
        in
        if String.length trimmed < minQueryLength then
            ( { model | suggestions = [], visible = False }
            , Cmd.none
            )

        else
            case staticKeyFor searchType activeSource channel of
                Nothing ->
                    ( { model | suggestions = [], visible = False }, Cmd.none )

                Just key ->
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


update :
    SearchType
    -> OptionSource
    -> String
    -> String
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update searchType activeSource channel query msg model =
    case msg of
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
            ]
        ]



-- STATIC CORPUS


fetchCorpus : StaticKey -> Cmd Msg
fetchCorpus (( category, channel ) as key) =
    Http.get
        { url = "/autocomplete/" ++ category ++ "-" ++ channel ++ ".json"
        , expect = Http.expectJson (Loaded key) (decodeCorpus channel)
        }


decodeCorpus : String -> Json.Decode.Decoder Corpus
decodeCorpus channel =
    Json.Decode.list (decodeItem channel)


decodeItem : String -> Json.Decode.Decoder Item
decodeItem channel =
    Json.Decode.map
        (\name ->
            { name = name
            , navigateTo =
                "/options?channel=" ++ channel ++ "&show=" ++ name ++ "&query=" ++ name
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
