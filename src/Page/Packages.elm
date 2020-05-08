module Page.Packages exposing
    ( Model
    , Msg
    , decodeResultItemSource
    , init
    , makeRequest
    , update
    , view
    )

import Browser.Navigation
import ElasticSearch
import Html
    exposing
        ( Html
        , div
        , table
        , tbody
        , td
        , text
        , th
        , thead
        , tr
        )
import Html.Attributes
    exposing
        ( class
        , colspan
        )
import Html.Events
    exposing
        ( onClick
        )
import Json.Decode
import Json.Decode.Pipeline



-- MODEL


type alias Model =
    ElasticSearch.Model ResultItemSource


type alias ResultItemSource =
    { attr_name : String
    , name : String
    , version : String
    , description : Maybe String
    , longDescription : Maybe String
    , licenses : List ResultPackageLicense
    , maintainers : List ResultPackageMaintainer
    , platforms : List String
    , position : Maybe String
    , homepage : Maybe String
    }


type alias ResultPackageLicense =
    { fullName : Maybe String
    , url : Maybe String
    }


type alias ResultPackageMaintainer =
    { name : String
    , email : String
    , github : String
    }


init :
    Maybe String
    -> Maybe String
    -> ( Model, Cmd Msg )
init =
    ElasticSearch.init



-- UPDATE


type Msg
    = SearchMsg (ElasticSearch.Msg ResultItemSource)


update : Browser.Navigation.Key -> Msg -> Model -> ( Model, Cmd Msg )
update navKey msg model =
    case msg of
        SearchMsg subMsg ->
            let
                ( newModel, newCmd ) =
                    ElasticSearch.update "packages" navKey subMsg model
            in
            ( newModel, Cmd.map SearchMsg newCmd )



-- VIEW


view : Model -> Html Msg
view model =
    ElasticSearch.view
        { title = "Search NixOS packages" }
        model
        viewSuccess
        SearchMsg


viewSuccess :
    Maybe String
    -> ElasticSearch.Result ResultItemSource
    -> Html Msg
viewSuccess showDetailsFor result =
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
            , tbody
                []
                (List.concatMap
                    (viewResultItem showDetailsFor)
                    result.hits.hits
                )
            ]
        ]


viewResultItem :
    Maybe String
    -> ElasticSearch.ResultItem ResultItemSource
    -> List (Html Msg)
viewResultItem showDetailsFor item =
    let
        packageDetails =
            if Just item.id == showDetailsFor then
                [ td [ colspan 4 ]
                    [ text "This are details!" ]
                ]

            else
                []
    in
    tr [ onClick (SearchMsg (ElasticSearch.ShowDetails item.id)) ]
        [ td [] [ text item.source.attr_name ]
        , td [] [ text item.source.name ]
        , td [] [ text item.source.version ]
        , td [] [ text <| Maybe.withDefault "" item.source.description ]
        ]
        :: packageDetails



-- API


makeRequest :
    ElasticSearch.Options
    -> String
    -> Cmd Msg
makeRequest options query =
    ElasticSearch.makeRequest
        "attr_name"
        "nixos-unstable-packages"
        decodeResultItemSource
        options
        query
        |> Cmd.map SearchMsg



-- JSON


decodeResultItemSource : Json.Decode.Decoder ResultItemSource
decodeResultItemSource =
    Json.Decode.succeed ResultItemSource
        |> Json.Decode.Pipeline.required "attr_name" Json.Decode.string
        |> Json.Decode.Pipeline.required "name" Json.Decode.string
        |> Json.Decode.Pipeline.required "version" Json.Decode.string
        |> Json.Decode.Pipeline.required "description" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "longDescription" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "license" (Json.Decode.list decodeResultPackageLicense)
        |> Json.Decode.Pipeline.required "maintainers" (Json.Decode.list decodeResultPackageMaintainer)
        |> Json.Decode.Pipeline.required "platforms" (Json.Decode.list Json.Decode.string)
        |> Json.Decode.Pipeline.required "position" (Json.Decode.nullable Json.Decode.string)
        |> Json.Decode.Pipeline.required "homepage" (Json.Decode.nullable Json.Decode.string)


decodeResultPackageLicense : Json.Decode.Decoder ResultPackageLicense
decodeResultPackageLicense =
    Json.Decode.map2 ResultPackageLicense
        (Json.Decode.field "fullName" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "url" (Json.Decode.nullable Json.Decode.string))


decodeResultPackageMaintainer : Json.Decode.Decoder ResultPackageMaintainer
decodeResultPackageMaintainer =
    Json.Decode.map3 ResultPackageMaintainer
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "email" Json.Decode.string)
        (Json.Decode.field "github" Json.Decode.string)
