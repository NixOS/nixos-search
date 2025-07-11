module List.Extra exposing (find)


find : (a -> Bool) -> List a -> Maybe a
find p list =
    case list of
        [] ->
            Nothing

        h :: t ->
            if p h then
                Just h

            else
                find p t
