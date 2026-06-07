module Utils exposing
    ( copyButton
    , copyable
    , showHtml
    , toggleList
    )

import Html exposing (Html)
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


toggleList :
    List a
    -> a
    -> List a
toggleList list item =
    if List.member item list then
        List.filter (\x -> x /= item) list

    else
        list ++ [ item ]


showHtml : String -> Maybe (List (Html msg))
showHtml value =
    case Html.Parser.run <| String.trim value of
        Ok [ Html.Parser.Element "rendered-html" _ nodes ] ->
            Just <| Html.Parser.Util.toVirtualDom nodes

        _ ->
            Nothing
