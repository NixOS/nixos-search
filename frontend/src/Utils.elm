module Utils exposing
    ( showHtml
    , toggleList
    )

import Html.Parser
import Html.Parser.Util


toggleList :
    List a
    -> a
    -> List a
toggleList list item =
    if List.member item list then
        List.filter (\x -> x /= item) list

    else
        List.append list [ item ]


showHtml value =
    case Html.Parser.run <| String.trim value of
        Ok [ Html.Parser.Element "rendered-html" _ nodes ] ->
            Just <| Html.Parser.Util.toVirtualDom nodes

        _ ->
            Nothing
