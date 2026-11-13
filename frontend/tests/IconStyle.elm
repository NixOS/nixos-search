module IconStyle exposing (iconFile)

import Dict
import Expect
import Test exposing (Test)
import Utils exposing (IconStyle(..))


icons : Dict.Dict String String
icons =
    Dict.fromList [ ( "own", "own.png" ), ( "gap", "gap.svg" ), ( "only-own", "only-own.png" ) ]


themeIcons : Dict.Dict String String
themeIcons =
    Dict.fromList [ ( "own", "theme.svg" ) ]


iconFile : Test
iconFile =
    Test.describe "Utils.iconFile"
        [ Test.test "the package style keeps the icon of the package" <|
            \_ ->
                Utils.iconFile PreferPackageIcons icons themeIcons "own"
                    |> Expect.equal (Just "own.png")
        , Test.test "the package style falls back to the icon of the theme" <|
            \_ ->
                Utils.iconFile PreferPackageIcons icons themeIcons "gap"
                    |> Expect.equal (Just "gap.svg")
        , Test.test "the theme style prefers the icon of the theme" <|
            \_ ->
                Utils.iconFile PreferThemeIcons icons themeIcons "own"
                    |> Expect.equal (Just "theme.svg")
        , Test.test "the theme style uses the icon of the theme that fills a gap" <|
            \_ ->
                Utils.iconFile PreferThemeIcons icons themeIcons "gap"
                    |> Expect.equal (Just "gap.svg")
        , Test.test "the theme style falls back to the icon of the package" <|
            \_ ->
                Utils.iconFile PreferThemeIcons icons themeIcons "only-own"
                    |> Expect.equal (Just "only-own.png")
        , Test.test "an unknown name has no icon in the theme style" <|
            \_ ->
                Utils.iconFile PreferThemeIcons icons themeIcons "unknown"
                    |> Expect.equal Nothing
        ]
