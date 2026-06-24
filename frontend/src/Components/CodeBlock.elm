module Components.CodeBlock exposing (copyButton, copyable)

import Html exposing (Html, code, div, pre)
import Html.Attributes exposing (class, title, type_)
import Html.Events exposing (onClick)
import Html.Parser
import Html.Parser.Util

copyButton : (String -> msg) -> String -> String -> String -> Html msg
copyButton copyMsg btnClass btnTitle textToCopy =
    Html.button
        [ type_ "button"
        , class btnClass
        , title btnTitle
        , onClick (copyMsg textToCopy)
        ]
        [ Html.text "Copy" ]


copyable : (String -> msg) -> String -> Html msg -> Html msg
copyable copyMsg textToCopy rendered =
    Html.div [ class "code-block-wrapper" ]
        [ rendered
        , copyButton copyMsg "code-copy-button" "Copy to clipboard" textToCopy
        ]
