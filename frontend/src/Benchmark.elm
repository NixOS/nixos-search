port module Benchmark exposing (main)

{-| Headless worker: receives query emits two Elasticsearch
request bodies

  - Packages
  - Options

Used for benchmarking

-}

import Json.Encode
import Page.Options
import Page.Packages
import Platform
import Search


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
            Page.Packages.encodeRequestBody query 0 k Nothing Search.Relevance

        optBody =
            Page.Options.encodeRequestBody [ "option" ] query 0 k Search.Relevance
    in
    gotBodies
        { packages = Json.Encode.encode 0 pkgBody
        , options = Json.Encode.encode 0 optBody
        }
