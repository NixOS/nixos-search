module Components.Button exposing (..)

import Html exposing (Attribute, Html, button)
import Html.Attributes exposing (attribute, class, type_)


viewButton : List (Attribute msg) -> List (Html msg) -> Html msg
viewButton attributes content =
    button
        (class "btn" :: type_ "button" :: attributes)
        content
