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
        , a
        , code
        , dd
        , div
        , dl
        , dt
        , li
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
                [ td [ colspan 4 ] [ viewResultItemDetails item ]
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


viewResultItemDetails :
    ElasticSearch.ResultItem ResultItemSource
    -> Html Msg
viewResultItemDetails item =
    let
        default =
            "Not specified"

        asText =
            text

        asLink value =
            a [ href value ] [ text value ]

        -- TODO: this should take channel into account as well
        githubUrlPrefix =
            "https://github.com/NixOS/nixpkgs-channels/blob/nixos-unstable/"

        cleanPosition value =
            if String.startsWith "source/" value then
                String.dropLeft 7 value

            else
                value

        asGithubLink value =
            a
                [ href <| githubUrlPrefix ++ (value |> String.replace ":" "#L" |> cleanPosition) ]
                [ text <| cleanPosition value ]

        withDefault wrapWith maybe =
            case maybe of
                Nothing ->
                    text default

                Just "" ->
                    text default

                Just value ->
                    wrapWith value

        convertToGithubUrl value =
            if String.startsWith "source/" value then
                githubUrlPrefix ++ String.dropLeft 7 value

            else
                githubUrlPrefix ++ value

        -- TODO: add links to hydra for hydra_platforms
        -- example: https://hydra.nixos.org/job/nixos/release-20.03/nixpkgs.gnome3.accerciser.i686-linux
        showPlatform platform =
            li [] [ text platform ]

        showLicence license =
            li []
                [ case ( license.fullName, license.url ) of
                    ( Nothing, Nothing ) ->
                        text default

                    ( Just fullName, Nothing ) ->
                        text fullName

                    ( Nothing, Just url ) ->
                        a [ href url ] [ text default ]

                    ( Just fullName, Just url ) ->
                        a [ href url ] [ text fullName ]
                ]

        showMaintainer maintainer =
            li []
                [ a
                    [ href <| "https://github.com/" ++ maintainer.github ]
                    [ text <| maintainer.name ++ " <" ++ maintainer.email ++ ">" ]
                ]
    in
    dl [ class "dl-horizontal" ]
        [ dt [] [ text "Install command" ]
        , dd [] [ code [] [ text <| "nix-env -iA nixos." ++ item.source.attr_name ] ]
        , dt [] [ text <| "Nix expression" ]

        -- TODO: point to correct branch/channel
        , dd [] [ withDefault asGithubLink item.source.position ]
        , dt [] [ text "Platforms" ]
        , dd [] [ ul [ class "inline" ] <| List.map showPlatform item.source.platforms ]
        , dt [] [ text "Homepage" ]
        , dd [] [ withDefault asLink item.source.homepage ]
        , dt [] [ text "Licenses" ]
        , dd [] [ ul [ class "inline" ] <| List.map showLicence item.source.licenses ]
        , dt [] [ text "Maintainers" ]
        , dd [] [ ul [ class "inline" ] <| List.map showMaintainer item.source.maintainers ]
        , dt [] [ text "Long description" ]
        , dd [] [ withDefault asText item.source.longDescription ]
        ]



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
