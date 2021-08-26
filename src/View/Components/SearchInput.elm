module View.Components.SearchInput exposing (..)

import Html exposing (Html, a, button, div, form, h4, input, li, p, span, text, th, ul)
import Html.Attributes exposing (attribute, autofocus, class, classList, href, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Route exposing (SearchType, allTypes, searchTypeToString, searchTypeToTitle)
import Search exposing (Msg(..))


viewSearchInput :
    (Msg a b -> c)
    -> SearchType
    -> Maybe String
    -> Html c
viewSearchInput outMsg category searchQuery =
    let
        searchHint =
            Maybe.withDefault "Packages and Options" <| Maybe.map (\_ -> searchTypeToString category) searchQuery
    in
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
                    , placeholder <| "Search for " ++ searchHint
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
                            [ span [] [ text <| searchTypeToTitle category ]
                            , closeButton
                            ]
                        ]
                )
                allTypes
            )
        ]
    ]


closeButton : Html a
closeButton =
    span [] []


viewBucket :
    String
    -> List Search.AggregationsBucketItem
    -> (String -> a)
    -> List String
    -> List (Html a)
    -> List (Html a)
viewBucket title buckets searchMsgFor selectedBucket sets =
    List.append
        sets
        (if List.isEmpty buckets then
            []

         else
            [ li []
                [ ul []
                    (List.append
                        [ li [ class "header" ] [ text title ] ]
                        (List.map
                            (\bucket ->
                                li []
                                    [ a
                                        [ href "#"
                                        , onClick <| searchMsgFor bucket.key
                                        , classList
                                            [ ( "selected"
                                              , List.member bucket.key selectedBucket
                                              )
                                            ]
                                        ]
                                        [ span [] [ text bucket.key ]
                                        , if List.member bucket.key selectedBucket then
                                            closeButton

                                          else
                                            span [] [ span [ class "badge" ] [ text <| String.fromInt bucket.doc_count ] ]
                                        ]
                                    ]
                            )
                            buckets
                        )
                    )
                ]
            ]
        )
