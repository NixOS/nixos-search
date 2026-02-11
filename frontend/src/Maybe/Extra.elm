module Maybe.Extra exposing (values)


values : List (Maybe b) -> List b
values list =
    List.filterMap identity list
