module Main exposing (main)

import Base64
import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav exposing (Key)
import Html
    exposing
        ( Html
        , a
        , button
        , div
        , footer
        , form
        , h1
        , header
        , img
        , input
        , li
        , p
        , pre
        , table
        , tbody
        , td
        , text
        , th
        , thead
        , tr
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , colspan
        , href
        , src
        , type_
        , value
        )
import Html.Events
    exposing
        ( onClick
        , onInput
        , onSubmit
        )
import Http
import Json.Decode as D
import Json.Decode.Pipeline as DP
import Json.Encode as E
import RemoteData as R
import Url exposing (Url)
import Url.Builder as UrlBuilder
import Url.Parser as UrlParser
    exposing
        ( (<?>)
        , Parser
        )
import Url.Parser.Query as UrlParserQuery



-- ---------------------------
-- MODEL
-- ---------------------------


type alias Flags =
    { elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    }


type alias Model =
    { key : Key
    , elasticsearchUrl : String
    , elasticsearchUsername : String
    , elasticsearchPassword : String
    , page : Page
    }


type alias SearchModel =
    { query : Maybe String
    , result : R.WebData SearchResult
    , showDetailsFor : Maybe String
    }


type Page
    = SearchPage SearchModel



--| PackagePage SearchModel
--| MaintainerPage SearchModel


type alias SearchResult =
    { hits : SearchResultHits
    }


type alias SearchResultHits =
    { total : SearchResultHitsTotal
    , max_score : Maybe Float
    , hits : List SearchResultItem
    }


type alias SearchResultHitsTotal =
    { value : Int
    , relation : String -- TODO: this should probably be Enum
    }


type alias SearchResultItem =
    { index : String
    , id : String
    , score : Float
    , source : SearchResultItemSource
    }


type SearchResultItemSource
    = Package SearchResultPackage
    | Option SearchResultOption


type alias SearchResultPackage =
    { attr_name : String
    , name : String
    , version : String
    , description : Maybe String
    , longDescription : Maybe String
    , licenses : List SearchResultPackageLicense
    , maintainers : List SearchResultPackageMaintainer
    , platforms : List String
    , position : Maybe String
    , homepage : Maybe String
    }


type alias SearchResultOption =
    { option_name : String
    , description : String
    , type_ : String
    , default : String
    , example : String
    , source : String
    }


type alias SearchResultPackageLicense =
    { fullName : Maybe String
    , url : Maybe String
    }


type alias SearchResultPackageMaintainer =
    { name : String
    , email : String
    , github : String
    }


emptySearch : Page
emptySearch =
    SearchPage
        { query = Nothing
        , result = R.NotAsked
        , showDetailsFor = Nothing
        }


init : Flags -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    let
        model =
            { key = key
            , elasticsearchUrl = flags.elasticsearchUrl
            , elasticsearchUsername = flags.elasticsearchUsername
            , elasticsearchPassword = flags.elasticsearchPassword
            , page = UrlParser.parse urlParser url |> Maybe.withDefault emptySearch
            }
    in
    ( model
    , initPageCmd model model
    )


initPageCmd : Model -> Model -> Cmd Msg
initPageCmd oldModel model =
    let
        makeRequest query =
            Http.riskyRequest
                { method = "POST"
                , headers =
                    [ Http.header "Authorization" ("Basic " ++ Base64.encode (model.elasticsearchUsername ++ ":" ++ model.elasticsearchPassword))
                    ]
                , url = model.elasticsearchUrl ++ "/nixos-unstable-packages/_search"
                , body =
                    Http.jsonBody <|
                        E.object
                            [ ( "query"
                              , E.object
                                    [ ( "match"
                                      , E.object
                                            [ ( "attr_name"
                                              , E.object
                                                    [ ( "query", E.string query )

                                                    -- I'm not sure we need fuziness
                                                    --, ( "fuzziness", E.int 1 )
                                                    ]
                                              )
                                            ]
                                      )
                                    ]
                              )
                            ]
                , expect = Http.expectJson (R.fromResult >> SearchQueryResponse) decodeResult
                , timeout = Nothing
                , tracker = Nothing
                }
    in
    case oldModel.page of
        SearchPage oldSearchModel ->
            case model.page of
                SearchPage searchModel ->
                    if (oldSearchModel.query == searchModel.query) && R.isSuccess oldSearchModel.result then
                        Cmd.none

                    else
                        searchModel.query
                            |> Maybe.map makeRequest
                            |> Maybe.withDefault Cmd.none



-- ---------------------------
-- URL Parsing and Routing
-- ---------------------------


handleUrlRequest : Key -> UrlRequest -> Cmd msg
handleUrlRequest key urlRequest =
    case urlRequest of
        Internal url ->
            Nav.pushUrl key (Url.toString url)

        External url ->
            Nav.load url


urlParser : Parser (Page -> msg) msg
urlParser =
    UrlParser.oneOf
        [ UrlParser.map
            (\query showDetailsFor ->
                SearchPage
                    { query = query
                    , result = R.NotAsked
                    , showDetailsFor = showDetailsFor
                    }
            )
            (UrlParser.s "search" <?> UrlParserQuery.string "query" <?> UrlParserQuery.string "showDetailsFor")
        ]



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg
    = OnUrlRequest UrlRequest
    | OnUrlChange Url
    | SearchPageInput String
    | SearchQuerySubmit
    | SearchQueryResponse (R.WebData SearchResult)
    | SearchShowPackageDetails String


decodeResult : D.Decoder SearchResult
decodeResult =
    D.map SearchResult
        (D.field "hits" decodeResultHits)


decodeResultHits : D.Decoder SearchResultHits
decodeResultHits =
    D.map3 SearchResultHits
        (D.field "total" decodeResultHitsTotal)
        (D.field "max_score" (D.nullable D.float))
        (D.field "hits" (D.list decodeResultItem))


decodeResultHitsTotal : D.Decoder SearchResultHitsTotal
decodeResultHitsTotal =
    D.map2 SearchResultHitsTotal
        (D.field "value" D.int)
        (D.field "relation" D.string)


decodeResultItem : D.Decoder SearchResultItem
decodeResultItem =
    D.map4 SearchResultItem
        (D.field "_index" D.string)
        (D.field "_id" D.string)
        (D.field "_score" D.float)
        (D.field "_source" decodeResultItemSource)


decodeResultItemSource : D.Decoder SearchResultItemSource
decodeResultItemSource =
    D.oneOf
        [ D.map Package decodeResultPackage

        --, D.map Option decodeResultOption
        ]


decodeResultPackage : D.Decoder SearchResultPackage
decodeResultPackage =
    D.succeed SearchResultPackage
        |> DP.required "attr_name" D.string
        |> DP.required "name" D.string
        |> DP.required "version" D.string
        |> DP.required "description" (D.nullable D.string)
        |> DP.required "longDescription" (D.nullable D.string)
        |> DP.required "license" (D.list decodeResultPackageLicense)
        |> DP.required "maintainers" (D.list decodeResultPackageMaintainer)
        |> DP.required "platforms" (D.list D.string)
        |> DP.required "position" (D.nullable D.string)
        |> DP.required "homepage" (D.nullable D.string)


decodeResultPackageLicense : D.Decoder SearchResultPackageLicense
decodeResultPackageLicense =
    D.map2 SearchResultPackageLicense
        (D.field "fullName" (D.nullable D.string))
        (D.field "url" (D.nullable D.string))


decodeResultPackageMaintainer : D.Decoder SearchResultPackageMaintainer
decodeResultPackageMaintainer =
    D.map3 SearchResultPackageMaintainer
        (D.field "name" D.string)
        (D.field "email" D.string)
        (D.field "github" D.string)


decodeResultOption : D.Decoder SearchResultOption
decodeResultOption =
    D.map6 SearchResultOption
        (D.field "option_name" D.string)
        (D.field "description" D.string)
        (D.field "type" D.string)
        (D.field "default" D.string)
        (D.field "example" D.string)
        (D.field "source" D.string)


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        OnUrlRequest urlRequest ->
            ( model, handleUrlRequest model.key urlRequest )

        OnUrlChange url ->
            let
                newModel =
                    { model | page = UrlParser.parse urlParser url |> Maybe.withDefault model.page }

                newPage =
                    case newModel.page of
                        SearchPage searchModel ->
                            SearchPage
                                { searchModel
                                    | result =
                                        case searchModel.query of
                                            Just query ->
                                                R.Loading

                                            Nothing ->
                                                R.NotAsked
                                }

                newNewModel =
                    { newModel | page = newPage }
            in
            ( newNewModel
            , initPageCmd newModel newNewModel
            )

        SearchPageInput query ->
            ( { model
                | page =
                    case model.page of
                        SearchPage searchModel ->
                            SearchPage { searchModel | query = Just query }
              }
            , Cmd.none
            )

        SearchQuerySubmit ->
            case model.page of
                SearchPage searchModel ->
                    ( model
                    , Nav.pushUrl model.key <| createSearchUrl searchModel
                    )

        SearchQueryResponse result ->
            case model.page of
                SearchPage searchModel ->
                    let
                        newPage =
                            SearchPage { searchModel | result = result }
                    in
                    ( { model | page = newPage }
                    , Cmd.none
                    )

        SearchShowPackageDetails showDetailsFor ->
            case model.page of
                SearchPage searchModel ->
                    let
                        newSearchModel =
                            { searchModel
                                | showDetailsFor =
                                    if searchModel.showDetailsFor == Just showDetailsFor then
                                        Nothing

                                    else
                                        Just showDetailsFor
                            }
                    in
                    ( model
                    , Nav.pushUrl model.key <| createSearchUrl newSearchModel
                    )


createSearchUrl : SearchModel -> String
createSearchUrl model =
    []
        |> List.append
            (model.query
                |> Maybe.map
                    (\query ->
                        [ UrlBuilder.string "query" query ]
                    )
                |> Maybe.withDefault []
            )
        |> List.append
            (model.showDetailsFor
                |> Maybe.map
                    (\x ->
                        [ UrlBuilder.string "showDetailsFor" x
                        ]
                    )
                |> Maybe.withDefault []
            )
        |> UrlBuilder.absolute [ "search" ]



-- ---------------------------
-- VIEW
-- ---------------------------


view : Model -> Html Msg
view model =
    div []
        [ header []
            [ div [ class "navbar navbar-static-top" ]
                [ div [ class "navbar-inner" ]
                    [ div [ class "container" ]
                        [ a [ class "brand", href "https://search.nixos.org" ]
                            [ img [ src "https://nixos.org/logo/nix-wiki.png", class "logo" ] []
                            ]
                        ]
                    ]
                ]
            ]
        , div [ class "container main" ]
            [ case model.page of
                SearchPage searchModel ->
                    searchPage searchModel
            , footer [] []
            ]
        ]


searchPage : SearchModel -> Html Msg
searchPage model =
    div [ class "search-page" ]
        [ h1 [ class "page-header" ] [ text "Search for packages and options" ]
        , div [ class "search-input" ]
            [ form [ onSubmit SearchQuerySubmit ]
                [ div [ class "input-append" ]
                    [ input
                        [ type_ "text"
                        , onInput SearchPageInput
                        , value <| Maybe.withDefault "" model.query
                        ]
                        []
                    , div [ class "btn-group" ]
                        [ button [ class "btn" ] [ text "Search" ]

                        --TODO: and option to select the right channel+version+evaluation
                        --, button [ class "btn" ] [ text "Loading ..." ]
                        --, div [ class "popover bottom" ]
                        --    [ div [ class "arrow" ] []
                        --    , div [ class "popover-title" ] [ text "Select options" ]
                        --    , div [ class "popover-content" ]
                        --        [ p [] [ text "Sed posuere consectetur est at lobortis. Aenean eu leo quam. Pellentesque ornare sem lacinia quam venenatis vestibulum." ] ]
                        --    ]
                        ]
                    ]
                ]
            ]
        , case model.result of
            R.NotAsked ->
                div [] [ text "NotAsked" ]

            R.Loading ->
                div [] [ text "Loading" ]

            R.Success result ->
                searchPageResult model.showDetailsFor result.hits

            R.Failure error ->
                div []
                    [ text "Error!"

                    --, pre [] [ text (Debug.toString error) ]
                    ]
        ]


searchPageResult : Maybe String -> SearchResultHits -> Html Msg
searchPageResult showDetailsFor result =
    div [ class "search-result" ]
        [ table [ class "table table-hover" ]
            [ thead []
                [ tr []
                    [ th [] [ text "Attribute name" ]
                    , th [] [ text "Name" ]
                    , th [] [ text "Version" ]
                    , th [] [ text "Description" ]
                    ]
                ]
            , tbody [] <| List.concatMap (searchPageResultItem showDetailsFor) result.hits
            ]
        ]


searchPageResultItem : Maybe String -> SearchResultItem -> List (Html Msg)
searchPageResultItem showDetailsFor item =
    case item.source of
        Package package ->
            let
                packageDetails =
                    if Just item.id == showDetailsFor then
                        [ td [ colspan 4 ]
                            []
                        ]

                    else
                        []
            in
            [ tr [ onClick <| SearchShowPackageDetails item.id ]
                [ td [] [ text package.attr_name ]
                , td [] [ text package.name ]
                , td [] [ text package.version ]
                , td [] [ text <| Maybe.withDefault "" package.description ]
                ]
            ]
                ++ packageDetails

        Option option ->
            [ tr
                []
                [--  td [] [ text option.option_name ]
                 --, td [] [ text option.name ]
                 --, td [] [ text option.version ]
                 --, td [] [ text option.description ]
                ]
            ]



-- ---------------------------
-- MAIN
-- ---------------------------


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , view =
            \m ->
                { title = "NixOS Search"
                , body = [ view m ]
                }
        , subscriptions = \_ -> Sub.none
        , onUrlRequest = OnUrlRequest
        , onUrlChange = OnUrlChange
        }
