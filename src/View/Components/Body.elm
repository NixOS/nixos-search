module View.Components.Body exposing (view)

import Html
    exposing
        ( Html
        , div
        , h1
        )
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import RemoteData exposing (RemoteData(..))
import Route
import Search
    exposing
        ( Details
        , Model
        , Msg(..)
        , ResultItem
        , SearchResult
        , viewResult
        )
import View.Components.SearchInput
    exposing
        ( viewFlakes
        , viewSearchInput
        )


view :
    { toRoute : Route.SearchRoute
    , categoryName : String
    }
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
view { toRoute, categoryName } title model viewSuccess viewBuckets outMsg =
    let
        resultStatus =
            case model.result of
                RemoteData.NotAsked ->
                    "not-asked"

                RemoteData.Loading ->
                    "loading"

                RemoteData.Success _ ->
                    "success"

                RemoteData.Failure _ ->
                    "failure"
    in
    div
        (List.append
            [ class <| "search-page " ++ resultStatus ]
            (if model.showSort then
                [ onClick (outMsg ToggleSort) ]

             else
                []
            )
        )
        [ h1 [] title
        , viewSearchInput outMsg model.searchType model.query
        , viewResult outMsg toRoute categoryName model viewSuccess viewBuckets <| viewFlakes outMsg model.channel model.searchType
        ]
