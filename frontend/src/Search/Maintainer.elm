module Search.Maintainer exposing
    ( Maintainer
    , decode
    , linkAllMaintainers
    , mailtoAllMaintainers
    , showMaintainer
    )

{-| Maintainer rendering shared by package results and modular service results.

Each view passes in its own `copy` message constructor, since the clipboard
message belongs to the page's own `Msg` type.

-}

import Html exposing (Html, a, code, li, text)
import Html.Attributes exposing (class, href)
import Html.Events exposing (onClick)
import Json.Decode


type alias Maintainer =
    { name : Maybe String
    , email : Maybe String
    , github : Maybe String
    }


decode : Json.Decode.Decoder Maintainer
decode =
    Json.Decode.map3 Maintainer
        (Json.Decode.oneOf
            [ Json.Decode.field "name" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.field "email" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.field "github" (Json.Decode.map Just Json.Decode.string)
            , Json.Decode.succeed Nothing
            ]
        )
        (Json.Decode.field "email" (Json.Decode.nullable Json.Decode.string))
        (Json.Decode.field "github" (Json.Decode.nullable Json.Decode.string))


showMaintainer : (String -> msg) -> Maintainer -> Html msg
showMaintainer copy maintainer =
    let
        githubHandle =
            Maybe.map (String.append "@") maintainer.github

        name =
            Maybe.withDefault (Maybe.withDefault "Unknown" maintainer.github) maintainer.name

        nameHtml =
            case maintainer.github of
                Just github ->
                    a [ href ("https://github.com/" ++ github) ] [ text name ]

                Nothing ->
                    text name

        githubHtml =
            case githubHandle of
                Just handle ->
                    [ text " ("
                    , code [] [ text handle ]
                    , text ")"
                    ]

                Nothing ->
                    []

        emailHtml =
            case maintainer.email of
                Just email ->
                    [ text " <"
                    , a [ href ("mailto:" ++ email) ] [ text email ]
                    , text ">"
                    ]

                Nothing ->
                    []

        onClickAttr =
            case githubHandle of
                Just handle ->
                    [ onClick (copy handle) ]

                Nothing ->
                    []
    in
    li (class "maintainer-list-item" :: onClickAttr) (nameHtml :: githubHtml ++ emailHtml)


linkAllMaintainers : (String -> msg) -> List Maintainer -> List (Html msg)
linkAllMaintainers copy maintainers =
    case List.filterMap (\m -> Maybe.map (String.append "@") m.github) maintainers of
        [] ->
            []

        ghHandles ->
            [ li [ class "maintainer-list-item", onClick (copy (String.join " " ghHandles)) ]
                [ text "Copy all maintainers' GitHub handles" ]
            ]


mailtoAllMaintainers : List Maintainer -> List (Html msg)
mailtoAllMaintainers maintainers =
    let
        maintainerMails =
            List.filterMap (\m -> m.email) maintainers
    in
    if List.length maintainerMails > 1 then
        [ a
            [ href ("mailto:" ++ String.join "," maintainerMails) ]
            [ li [ class "maintainer-list-item" ]
                [ text "✉️ Mail to all maintainers" ]
            ]
        ]

    else
        []
