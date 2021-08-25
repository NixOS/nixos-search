module View.Components exposing (..)

import Html exposing (Html)
import Route exposing (SearchRoute)
import Search exposing (Model, Msg, ResultItem, SearchResult)
import View.Components.Body
import Search exposing (Details)


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
