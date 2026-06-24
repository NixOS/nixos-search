module Components.Badge exposing (Variant(..), view)

import Html exposing (Html, span, text)
import Html.Attributes exposing (class)


type Variant
    = Beta
    | Deprecated
    | Experimental


details : Variant -> { class : String, label : String }
details variant =
    case variant of
        Beta ->
            { class = "label-beta", label = "Beta" }

        Deprecated ->
            { class = "label-deprecated", label = "Deprecated" }

        Experimental ->
            { class = "label-experimental", label = "Experimental" }


view : Variant -> Html msg
view variant =
    let
        config =
            details variant
    in
    span [ class ("label " ++ config.class) ] [ text config.label ]
