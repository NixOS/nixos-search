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

{-| Lightweight per-keystroke suggestions UI.

Sits alongside the existing search form. The parent (`Search`) calls
`queryChanged` whenever the input changes; we debounce, fire a small
ES query against the existing `*.edge` subfields, and render a
dropdown of links the user can click to jump straight to a result.

When `disabled` is true (data-saver mode), `queryChanged` returns no
Cmd and `viewDropdown` returns an empty node.

-}

import Base64
import Html exposing (Html, a, li, span, text, ul)
import Html.Attributes exposing (class, href)
import Http
import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Process
import Regex
import Route exposing (SearchType(..))
import Task



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



-- MODEL


type alias Model =
    { token : Int
    , suggestions : List Suggestion
    , enabled : Bool
    , visible : Bool
    }


type alias Suggestion =
    { primary : String
    , secondary : Maybe String
    , navigateTo : String
    }


init : Bool -> Model
init enabled =
    { token = 0
    , suggestions = []
    , enabled = enabled
    , visible = False
    }


disabled : Model -> Bool
disabled m =
    not m.enabled



-- DEBOUNCE


debounceMs : Float
debounceMs =
    150


maxResults : Int
maxResults =
    8



-- UPDATE


type Msg
    = Fire Int
    | Response Int (Result Http.Error (List Suggestion))
    | Hide


{-| Synchronous "close the dropdown now" message — for submit and Escape.
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
    if m.enabled && not (List.isEmpty m.suggestions) then
        { m | visible = True }

    else
        m


{-| Delayed "close the dropdown" message — for blur. The delay gives the
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
    -> String
    -> String
    -> Model
    -> ( Model, Cmd Msg )
queryChanged _ _ _ _ query model =
    if not model.enabled then
        ( model, Cmd.none )

    else
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
    -> String
    -> String
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
update options nixosChannels searchType channel query msg model =
    case msg of
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
    if not model.enabled || not model.visible || List.isEmpty model.suggestions then
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



-- HTTP


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
                        "/packages?channel=" ++ channel ++ "&show=" ++ attr ++ "&query=" ++ attr
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
                        "/options?channel=" ++ channel ++ "&show=" ++ name ++ "&query=" ++ name
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
