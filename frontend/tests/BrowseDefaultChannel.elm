module BrowseDefaultChannel exposing (defaultChannel)

import Expect
import Page.Browse
import Search exposing (NixOSChannel, NixOSChannelStatus(..))
import Test exposing (Test)


channel : String -> NixOSChannelStatus -> NixOSChannel
channel id status =
    { id = id, status = status, jobset = "", branch = "" }


defaultChannel : Test
defaultChannel =
    Test.describe "Page.Browse.defaultChannel"
        [ Test.test "prefers the rolling channel to the stable channel" <|
            \_ ->
                Page.Browse.defaultChannel "26.05" [ channel "26.05" Stable, channel "unstable" Rolling ]
                    |> Expect.equal "unstable"
        , Test.test "uses the fallback when there is no rolling channel" <|
            \_ ->
                Page.Browse.defaultChannel "26.05" [ channel "26.05" Stable ]
                    |> Expect.equal "26.05"
        ]
