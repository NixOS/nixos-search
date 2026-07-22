module Components.Badge exposing (Variant(..), view)

import Html exposing (Html, span, text)
import Html.Attributes exposing (class)


type Variant
    = Beta
    | Community
    | Deprecated
    | Experimental
    | External


details : Variant -> { class : String, label : String }
details variant =
    case variant of
        Beta ->
            { class = "label-beta", label = "Beta" }

        Community ->
            { class = "label-community", label = "Community" }

        Deprecated ->
            { class = "label-deprecated", label = "Deprecated" }

        Experimental ->
            { class = "label-experimental", label = "Experimental" }

        External ->
            { class = "label-external", label = "External" }


view : Variant -> Html msg
view variant =
    let
        config =
            details variant
    in
    span [ class ("label " ++ config.class) ] [ text config.label ]
