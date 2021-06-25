module View.Components.SearchInput exposing (..)

import Html exposing (Html, button, div, form, h4, input, p, text, th)
import Html.Attributes exposing (attribute, autofocus, class, classList, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Encode exposing (bool)
import Search exposing (Msg(..), channelDetailsFromId, channels, flakeFromId, flakes)


viewSearchInput :
    (Msg a b -> c)
    -> String
    -> String
    -> Maybe String
    -> Html c
viewSearchInput outMsg categoryName selectedFlake searchQuery =
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
                    , placeholder <| "Search for " ++ categoryName
                    , onInput (outMsg << QueryInput)
                    , value <| Maybe.withDefault "" searchQuery
                    ]
                    []
                ]
            , button [ class "btn", type_ "submit" ]
                [ text "Search" ]
            ]
        , div [] (viewFlakes outMsg selectedFlake)
        ]


viewFlakes : (Msg a b -> msg) -> String -> List (Html msg)
viewFlakes outMsg selectedFlake =
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
