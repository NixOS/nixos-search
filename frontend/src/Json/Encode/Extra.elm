module Json.Encode.Extra exposing (optional, wrap)

{-| Helpers to encode nested JSON without deep indentation.

@docs optional, wrap

-}

import Json.Encode


{-| Puts a value in an object as its only field. Thus a pipeline can make a
nested object from the inside out:

    Json.Encode.list identity clauses
        |> wrap "must"
        |> wrap "bool"

gives `{"bool": {"must": [...]}}`.

-}
wrap : String -> Json.Encode.Value -> Json.Encode.Value
wrap key value =
    Json.Encode.object [ ( key, value ) ]


{-| The field for `Json.Encode.object` if there is a value, and no field if
there is no value.
-}
optional : String -> (a -> Json.Encode.Value) -> Maybe a -> List ( String, Json.Encode.Value )
optional key encode value =
    case value of
        Just a ->
            [ ( key, encode a ) ]

        Nothing ->
            []
