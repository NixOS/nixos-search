module Style exposing (loading)

import Css
import Css.Animations


{-| Loading CSS Record
wrapper property to be used as wrapper of both loader and headline
-}
loading : { wrapper : Css.Style, loader : Css.Style, headline : Css.Style }
loading =
    { wrapper =
        Css.batch
            [ Css.height <| Css.px 200
            , Css.overflow Css.hidden
            , Css.position Css.relative
            ]
    , loader =
        let
            frameSolid =
                [ Css.Animations.property "box-shadow" "0 0", Css.Animations.property "height" "4em" ]

            frameFade =
                [ Css.Animations.property "box-shadow" "0 -2em", Css.Animations.property "height" "5em" ]

            load =
                Css.batch
                    [ Css.backgroundColor Css.transparent
                    , Css.width <| Css.em 1
                    , Css.animationDuration <| Css.sec 1
                    , Css.animationIterationCount Css.infinite
                    , Css.animationName
                        (Css.Animations.keyframes
                            [ ( 0, frameSolid ), ( 40, frameFade ), ( 80, frameSolid ), ( 100, frameSolid ) ]
                        )
                    ]
        in
        Css.batch
            [ load
            , Css.color <| Css.hex "000000"
            , Css.textIndent <| Css.em -9999
            , Css.margin2 (Css.px 88) Css.auto
            , Css.position Css.relative
            , Css.fontSize <| Css.px 11
            , Css.animationDelay <| Css.sec -0.16
            , Css.before
                [ load
                , Css.position Css.absolute
                , Css.property "content" "''"
                , Css.left <| Css.em -1.5
                , Css.animationDelay <| Css.sec -0.32
                ]
            , Css.after
                [ load
                , Css.position Css.absolute
                , Css.property "content" "''"
                , Css.left <| Css.em 1.5
                ]
            ]
    , headline =
        Css.batch
            [ Css.position Css.absolute
            , Css.top <| Css.em 3
            , Css.width <| Css.pct 100
            , Css.textAlign Css.center
            ]
    }
