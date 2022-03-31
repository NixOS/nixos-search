module View.Components.SearchInput exposing
    ( closeButton
    , viewFlakes
    )

import Html
    exposing
        ( Html
        , a
        , li
        , span
        , text
        , ul
        )
import Html.Attributes
    exposing
        ( 
         classList
        , href
        )
import Html.Events
    exposing
        ( onClick
        )
import Route
    exposing
        ( SearchType
        , allTypes
        , searchTypeToTitle
        )
import Search exposing (Msg(..))


viewFlakes : (Msg a b -> msg) -> String -> SearchType -> List (Html msg)
viewFlakes outMsg _ selectedCategory =
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
