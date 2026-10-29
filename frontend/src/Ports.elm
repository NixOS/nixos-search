port module Ports exposing (copyToClipboard, scrollRow, showModal)

{-| Ask the JS side to copy the given text to the clipboard.
-}


port copyToClipboard : String -> Cmd msg


{-| `scrollRow { id, direction }` scrolls the element `id` horizontally by most
of its width, backward when `direction` is negative. `Browser.Dom.setViewportOf`
cannot do this: it sets `scrollTop` after `scrollLeft`, which stops a smooth
scroll before it starts.
-}
port scrollRow : { id : String, direction : Float } -> Cmd msg


{-| Ask the JS side to show the `<dialog>` with the given id as a modal. Elm
cannot call `showModal`, and only a modal dialog keeps the page behind it
inert. Removing the element from the page closes it.
-}
port showModal : String -> Cmd msg
