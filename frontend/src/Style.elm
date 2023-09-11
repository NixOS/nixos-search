module Style exposing (bucket, layout, loading, pre, withStyled)

import Css
import Css.Animations
import Css.Global
import Html as ElmHtml
import Html.Styled exposing (Html, div, toUnstyled)
import Html.Styled.Attributes exposing (css)


withStyled : List (Html msg) -> List (ElmHtml.Html msg)
withStyled children =
    div [ css [ Css.position Css.relative, Css.minHeight <| Css.vh 100 ] ]
        (Css.Global.global
            [ Css.Global.body
                [ Css.position Css.relative
                , Css.minHeight <| Css.vh 100
                , Css.overflowY Css.auto
                ]
            , Css.Global.footer
                [ Css.position Css.absolute
                , Css.bottom Css.zero
                , Css.width <| Css.pct 100
                , Css.height <| Css.rem 4
                ]

            --- Accessibility overrides, this should be changed once then entire app is using elm-css
            , Css.Global.a [ Css.color <| Css.hex "007dbb" ]
            , Css.Global.class "label-info" [ Css.backgroundColor <| Css.hex "007dbb" ]
            , Css.Global.class "badge" [ Css.backgroundColor <| Css.hex "757575" ]
            , Css.Global.class "pager"
                [ Css.displayFlex
                , Css.justifyContent Css.spaceBetween
                , Css.alignItems Css.center
                , Css.maxWidth <| Css.em 20
                , Css.margin2 Css.zero Css.auto
                , Css.padding2 (Css.px 20) Css.zero
                ]
            ]
            :: children
        )
        |> toUnstyled
        |> List.singleton


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


{-| preformatted CSS Record
properties to be used to style pre and code tags
-}
pre : { base : Css.Style, code : Css.Style, shell : Css.Style }
pre =
    { base =
        Css.batch
            [ Css.backgroundColor Css.transparent
            , Css.margin Css.zero
            , Css.padding Css.zero
            , Css.border Css.zero
            , Css.display Css.inline
            ]
    , code =
        Css.batch
            [ Css.backgroundColor <| Css.hex "333"
            , Css.color <| Css.hex "fff"
            , Css.padding <| Css.em 0.5
            , Css.margin Css.zero
            , Css.display Css.block
            , Css.cursor Css.text_
            ]
    , shell = Css.before [ Css.property "content" "'$ '" ]
    }


{-| bucket CSS Record
properties for side bar buckets
-}
bucket : { container : Css.Style, list : Css.Style, header : Css.Style, listItem : Css.Style, item : Css.Style, selected : Bool -> Css.Style }
bucket =
    { container =
        Css.batch
            [ Css.marginBottom <| Css.em 1
            , Css.padding <| Css.em 1
            , Css.borderRadius <| Css.px 4
            , Css.border3 (Css.px 1) Css.solid (Css.hex "ccc")
            ]
    , list = Css.batch [ Css.listStyle Css.none, Css.margin Css.zero ]
    , header =
        Css.batch
            [ Css.fontSize <| Css.em 1.2
            , Css.fontWeight Css.bold
            , Css.marginBottom <| Css.em 0.5
            ]
    , listItem = Css.marginBottom <| Css.em 0.2
    , item =
        Css.batch
            [ Css.displayFlex
            , Css.justifyContent Css.spaceBetween
            , Css.padding4 (Css.em 0.5) (Css.em 0.5) (Css.em 0.5) (Css.em 1)
            , Css.color <| Css.hex "333"
            , Css.textDecoration Css.none
            , Css.hover
                [ Css.textDecoration Css.none
                , Css.backgroundColor <| Css.hex "eee"
                , Css.color <| Css.hex "333"
                , Css.borderRadius <| Css.px 4
                ]
            ]
    , selected =
        \b ->
            if b then
                let
                    selected =
                        Css.batch
                            [ Css.backgroundColor <| Css.hex "0081c2"
                            , Css.color <| Css.hex "FFF"
                            , Css.textDecoration Css.none
                            ]
                in
                Css.batch
                    [ selected, Css.borderRadius <| Css.px 4, Css.hover [ selected ], Css.focus [ selected ] ]

            else
                Css.batch []
    }


layout : { sidebar : Css.Style }
layout =
    { sidebar =
        Css.batch
            [ Css.width <| Css.em 25
            , Css.listStyle Css.none
            , Css.margin4 Css.zero (Css.em 1) Css.zero Css.zero
            ]
    }
