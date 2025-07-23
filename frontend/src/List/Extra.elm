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
        |> List.foldl
            (\e ( lst, set ) ->
                if Set.member e set then
                    ( lst, set )

                else
                    ( e :: lst, Set.insert e set )
            )
            ( [], Set.empty )
        |> Tuple.first
        |> List.reverse
