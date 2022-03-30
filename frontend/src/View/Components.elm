module View.Components exposing (body)

import Html exposing (Html)
import Route exposing (SearchRoute)
import Search
    exposing
        ( Details
        , Model
        , Msg
        , ResultItem
        , SearchResult
        )
import View.Components.Body


body :
    { toRoute : SearchRoute, categoryName : String }
    -> List (Html c)
    -> Model a b
    ->
        (String
         -> Details
         -> Maybe String
         -> List (ResultItem a)
         -> Html c
        )
    ->
        (Maybe String
         -> SearchResult a b
         -> List (Html c)
        )
    -> (Msg a b -> c)
    -> Html c
body =
    View.Components.Body.view
