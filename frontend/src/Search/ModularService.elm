module Search.ModularService exposing
    ( Environment
    , PackageService
    , decodeEnvironment
    , decodePackageService
    , preferredImport
    )

{-| A modular service consists of a portable half, reachable as
`pkgs.<pkg>.services.<svc>`, and one half per environment it is registered for
(today only `system`, reachable as `config.modularServices.<pkg>.<svc>`). Each
half carries its own import expression and its own maintainers.

On nixpkgs revisions that predate the split there is no separate environment
half, and every import expression is the portable one.

-}

import Json.Decode
import Json.Decode.Pipeline
import Search.Maintainer exposing (Maintainer)


type alias Environment =
    { environment : String
    , importExpr : String
    , maintainers : List Maintainer
    }


type alias PackageService =
    { service : String
    , importExpr : String
    , environments : List Environment
    }


{-| The import expression to show by default: `system` when the service is
registered for it, otherwise whichever environment comes first, and finally the
portable half when there is no environment data at all (index 50, or a flake).
-}
preferredImport : String -> List Environment -> String
preferredImport fallback environments =
    let
        system =
            List.filter (\env -> env.environment == "system") environments
    in
    case system ++ environments of
        env :: _ ->
            env.importExpr

        [] ->
            fallback


decodeEnvironment : Json.Decode.Decoder Environment
decodeEnvironment =
    Json.Decode.succeed Environment
        |> Json.Decode.Pipeline.required "environment" Json.Decode.string
        |> Json.Decode.Pipeline.required "import" Json.Decode.string
        |> Json.Decode.Pipeline.optional "maintainers"
            (Json.Decode.list Search.Maintainer.decode)
            []


decodePackageService : Json.Decode.Decoder PackageService
decodePackageService =
    Json.Decode.succeed PackageService
        |> Json.Decode.Pipeline.required "service" Json.Decode.string
        |> Json.Decode.Pipeline.required "import" Json.Decode.string
        |> Json.Decode.Pipeline.optional "environments"
            (Json.Decode.list decodeEnvironment)
            []
