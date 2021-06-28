module View.Components.SearchInput exposing (..)

import Html exposing (Html, button, div, form, h4, input, p, text, th)
import Html.Attributes exposing (attribute, autofocus, class, classList, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Encode exposing (bool)
import Route exposing (SearchType, allTypes, searchTypeToString)
import Search exposing (Msg(..), channelDetailsFromId, channels, flakeFromId, flakes)


viewSearchInput :
    (Msg a b -> c)
    -> SearchType
    -> String
    -> Maybe String
    -> Html c
viewSearchInput outMsg category selectedFlake searchQuery =
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
        , div [] (viewFlakes outMsg selectedFlake category)
        ]


viewFlakes : (Msg a b -> msg) -> String -> SearchType -> List (Html msg)
viewFlakes outMsg selectedFlake selectedCategory =
    List.append
        [ div []
            [ h4 [] [ text "Channel: " ]
            , div
                [ class "btn-group"
                , attribute "data-toggle" "buttons-radio"
                ]
                (List.map
                    (\flake ->
                        button
                            [ type_ "button"
                            , classList
                                [ ( "btn", True )
                                , ( "active", flake.id == selectedFlake )
                                ]
                            , onClick <| outMsg (FlakeChange flake.id)
                            ]
                            [ text flake.title ]
                    )
                    flakes
                )
            ]
        , div []
            [ h4 [] [ text "Subject: " ]
            , div
                [ class "btn-group"
                , attribute "data-toggle" "buttons-radio"
                ]
                (List.map
                    (\category ->
                        button
                            [ type_ "button"
                            , classList
                                [ ( "btn", True )
                                , ( "active", category == selectedCategory )
                                ]
                            , onClick <| outMsg (SubjectChange category)
                            ]
                            [ text <| searchTypeToString category ]
                    )
                    allTypes
                )
            ]
        ]
    <|
        Maybe.withDefault
            [ p [ class "alert alert-error" ]
                [ h4 [] [ text "Wrong channel selected!" ]
                , text <| "Please select one of the channels above!"
                ]
            ]
        <|
            Maybe.map (\_ -> []) <|
                flakeFromId selectedFlake
