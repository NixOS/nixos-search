module Main exposing (main)

import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav exposing (Key)
import Html
    exposing
        ( Html
        , button
        , div
        , h1
        , header
        , input
        , li
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( class
        , type_
        , value
        )
import Html.Events
    exposing
        ( onClick
        , onInput
        )
import Http exposing (Error(..))
import Url exposing (Url)
import Url.Parser as UrlParser
    exposing
        ( (<?>)
        , Parser
        )
import Url.Parser.Query as UrlParserQuery



-- ---------------------------
-- MODEL
-- ---------------------------


type alias Model =
    { key : Key
    , page : Page
    }


type alias SearchModel =
    { query : String
    , results : List SearchResult
    }


type Page
    = Search SearchModel


type SearchResult
    = Package SearchResultPackage
    | Option SearchResultOption


type alias SearchResultPackage =
    { attribute_name : String
    , name : String
    , version : String
    , description : String
    , longDescription : String
    , license : List SearchResultPackageLicense
    , position : String
    , homepage : String
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
    { fullName : String
    , url : String
    }


type alias SearchResultPackageMaintainer =
    { name : String
    , email : String
    , github : String
    }


emptySearch : Page
emptySearch =
    Search { query = "", results = [] }


init : Int -> Url -> Key -> ( Model, Cmd Msg )
init _ url key =
    ( { key = key
      , page = UrlParser.parse urlParser url |> Maybe.withDefault emptySearch
      }
    , Cmd.none
    )



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
            (\q ->
                Search
                    { query = q |> Maybe.withDefault ""
                    , results = []
                    }
            )
            (UrlParser.s "search" <?> UrlParserQuery.string "query")
        ]



-- ---------------------------
-- UPDATE
-- ---------------------------


type Msg
    = OnUrlRequest UrlRequest
    | OnUrlChange Url
    | SearchPageInput String
    | SearchQuerySubmit


initPage : Page -> Cmd Msg
initPage page =
    case page of
        Search _ ->
            Cmd.none


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        OnUrlRequest urlRequest ->
            ( model, handleUrlRequest model.key urlRequest )

        OnUrlChange url ->
            let
                newModel =
                    { model | page = UrlParser.parse urlParser url |> Maybe.withDefault model.page }

                packages =
                    [ Package
                        { attribute_name = "firefox"
                        , name = "firefox"
                        , version = "74.0"
                        , description = "A web browser built from Firefox source tree (with plugins: )"
                        , longDescription = ""
                        , license = [ { fullName = "Mozilla Public License 2.0", url = "http://spdx.org/licenses/MPL-2.0.html" } ]
                        , position = ""
                        , homepage = "http://www.mozilla.com/en-US/firefox/"
                        }
                    ]

                newPage =
                    case newModel.page of
                        Search searchModel ->
                            Search
                                { searchModel
                                    | results =
                                        if searchModel.query == "" then
                                            []

                                        else
                                            packages
                                }
            in
            ( { newModel | page = newPage }
            , initPage newPage
            )

        SearchPageInput query ->
            ( { model
                | page =
                    case model.page of
                        Search searchModel ->
                            Search { searchModel | query = query }
              }
            , Cmd.none
            )

        SearchQuerySubmit ->
            case model.page of
                Search searchModel ->
                    ( model
                    , Nav.pushUrl model.key <| "/search?query=" ++ searchModel.query
                    )



-- ---------------------------
-- VIEW
-- ---------------------------


view : Model -> Html Msg
view model =
    div [ class "container" ]
        [ header []
            [ h1 [] [ text "NixOS Search" ]
            ]
        , case model.page of
            Search searchModel ->
                searchPage searchModel
        ]


searchPage : SearchModel -> Html Msg
searchPage model =
    div []
        [ div []
            [ input
                [ type_ "text"
                , onInput SearchPageInput
                , value model.query
                ]
                []
            , button [ onClick SearchQuerySubmit ] [ text "Search" ]
            ]
        , ul [] (List.map searchPageResult model.results)
        ]


searchPageResult : SearchResult -> Html Msg
searchPageResult result =
    case result of
        Package package ->
            li [] [ text package.attribute_name ]

        Option option ->
            li [] [ text option.option_name ]



-- ---------------------------
-- MAIN
-- ---------------------------


main : Program Int Model Msg
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
