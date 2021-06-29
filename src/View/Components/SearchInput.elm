module View.Components.SearchInput exposing (..)

import Html exposing (Html, a, button, div, form, h4, input, li, p, span, text, th, ul)
import Html.Attributes exposing (attribute, autofocus, class, classList, href, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Encode exposing (bool)
import Page.Packages exposing (viewBucket)
import Route exposing (SearchType, allTypes, searchTypeToString)
import Search exposing (Msg(..), channelDetailsFromId, channels, flakeFromId, flakes)


viewSearchInput :
    (Msg a b -> c)
    -> SearchType
    -> Maybe String
    -> Html c
viewSearchInput outMsg category searchQuery =
    form
        [ onSubmit (outMsg QueryInputSubmit)
        , class "search-input"
        ]
        [ div []
            [ div []
                [ input
                    [ type_ "text"
                    , id "search-query-input"
                    , autofocus True
                    , placeholder <| "Search for " ++ searchTypeToString category
                    , onInput (outMsg << QueryInput)
                    , value <| Maybe.withDefault "" searchQuery
                    ]
                    []
                ]
            , button [ class "btn", type_ "submit" ]
                [ text "Search" ]
            ]
        ]


viewFlakes : (Msg a b -> msg) -> String -> SearchType -> List (Html msg)
viewFlakes outMsg selectedFlake selectedCategory =
    [ li []
        [ ul []
            (List.append
                [ li [ class "header" ] [ text "Group" ] ]
                (List.map
                    (\flake ->
                        li []
                            [ a
                                [ href "#"
                                , onClick <| outMsg (FlakeChange flake.id)
                                , classList
                                    [ ( "selected"
                                      , flake.id == selectedFlake
                                      )
                                    ]
                                ]
                                [ span [] [ text flake.title ]
                                , span [] [] -- css ignores the last element (a badge in other buckets)
                                ]
                            ]
                    )
                    flakes
                )
            )
        , ul []
            (List.append
                [ li [ class "header" ] [ text "Group" ] ]
                (List.map
                    (\category ->
                        li []
                            [ a
                                [ href "#"
                                , onClick <| outMsg (SubjectChange category)
                                , classList
                                    [ ( "selected"
                                      , category == selectedCategory
                                      )
                                    ]
                                ]
                                [ span [] [ text <| searchTypeToString category ]
                                , span [] [] -- css ignores the last element (a badge in other buckets)
                                ]
                            ]
                    )
                    allTypes
                )
            )
        ]
    ]
