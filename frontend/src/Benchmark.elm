port module Benchmark exposing (main)

{-| Headless worker: receives query emits two Elasticsearch
request bodies

  - Packages
  - Options

Used for benchmarking

-}

import Json.Encode
import Platform
import Search
import Search.Query


port sendQuery : ({ query : String, k : Int } -> msg) -> Sub msg


port gotBodies : { packages : String, options : String } -> Cmd msg


main : Program () () { query : String, k : Int }
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \msg _ -> ( (), emit msg )
        , subscriptions = \_ -> sendQuery identity
        }


emit : { query : String, k : Int } -> Cmd msg
emit { query, k } =
    let
        pkgBody =
            Search.Query.packagesBody query 0 k Search.Relevance []

        optBody =
            Search.Query.optionsBody [ "option" ] query 0 k Search.Relevance
    in
    gotBodies
        { packages = Json.Encode.encode 0 pkgBody
        , options = Json.Encode.encode 0 optBody
        }
