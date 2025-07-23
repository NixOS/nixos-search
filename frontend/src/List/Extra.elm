module List.Extra exposing (find, unique)

import Set


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


unique : List comparable -> List comparable
unique list =
    list
        |> Set.fromList
        |> Set.toList
