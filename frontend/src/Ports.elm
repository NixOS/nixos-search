port module Ports exposing (copyToClipboard)

{-| Ask the JS side to copy the given text to the clipboard.
-}


port copyToClipboard : String -> Cmd msg
