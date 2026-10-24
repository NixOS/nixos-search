port module Ports exposing (copyToClipboard, setLanguage)

{-| Ask the JS side to copy the given text to the clipboard.
-}


port copyToClipboard : String -> Cmd msg


{-| Remember the language desktop entries should be shown in, so that a return
visit starts in it. The empty string forgets it again.
-}
port setLanguage : String -> Cmd msg
