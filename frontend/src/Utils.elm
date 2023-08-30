module Utils exposing
    ( showHtml
    , toggleList
    )

import Html.Parser
import Html.Parser.Util
import Html.Styled exposing (Html, fromUnstyled)


toggleList :
    List a
    -> a
    -> List a
toggleList list item =
    if List.member item list then
        List.filter (\x -> x /= item) list

    else
        List.append list [ item ]


showHtml : String -> Maybe (List (Html msg))
showHtml value =
    case Html.Parser.run <| String.trim value of
        Ok [ Html.Parser.Element "rendered-html" _ nodes ] ->
            Just <| (Html.Parser.Util.toVirtualDom nodes |> List.map fromUnstyled)

        _ ->
            Nothing
