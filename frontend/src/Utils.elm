module Utils exposing
    ( IconStyle(..)
    , basicTextIcon
    , copyButton
    , copyable
    , iconFile
    , iconStyleFromString
    , iconStyleToString
    , showHtml
    , toggleList
    )

import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes exposing (class, title, type_)
import Html.Events exposing (onClick)
import Html.Parser
import Html.Parser.Util
import Material.Icons.Types as IconsTypes exposing (Coloring(..))


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


textIcon : IconsTypes.Icon msg -> Int -> IconsTypes.Coloring -> String -> Html msg
textIcon icon size style text =
    Html.span [ class "icon-text-wrapper" ] [ icon size style, Html.text text ]


basicTextIcon : IconsTypes.Icon msg -> String -> Html msg
basicTextIcon icon text =
    textIcon icon 16 Inherit text


{-| The order in which to look for the icon of an application. Both styles use
the two sources, and only the priority changes. `PreferPackageIcons` uses the
icon of the package, with the icon of the theme as the fallback.
`PreferThemeIcons` uses the icon of the theme, with the icon of the package as
the fallback.
-}
type IconStyle
    = PreferPackageIcons
    | PreferThemeIcons


iconStyleFromString : String -> IconStyle
iconStyleFromString s =
    if s == "theme" then
        PreferThemeIcons

    else
        PreferPackageIcons


iconStyleToString : IconStyle -> String
iconStyleToString style =
    case style of
        PreferPackageIcons ->
            "package"

        PreferThemeIcons ->
            "theme"


{-| The file under `/icons` for an icon name. `icons` is
`package_desktop_icons`, and `themeIcons` is `package_desktop_theme_icons`.
-}
iconFile : IconStyle -> Dict String String -> Dict String String -> String -> Maybe String
iconFile style icons themeIcons name =
    case ( style, Dict.get name themeIcons ) of
        ( PreferThemeIcons, Just file ) ->
            Just file

        _ ->
            Dict.get name icons
