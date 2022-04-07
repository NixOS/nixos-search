module Utils exposing (toggleList)


toggleList :
    List a
    -> a
    -> List a
toggleList list item =
    if List.member item list then
        List.filter (\x -> x /= item) list

    else
        List.append list [ item ]
