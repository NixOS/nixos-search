module Search.ModularService exposing
    ( Environment
    , PackageService
    , decodeEnvironment
    , decodePackageService
    , environmentLabel
    , environmentUsagePath
    , preferredImport
    , supportedEnvironments
    )

{-| A modular service consists of a portable half, reachable as
`pkgs.<pkg>.services.<svc>`, and one half per environment it is registered for
(today only `system`, reachable as `config.modularServices.<pkg>.<svc>`). Each
half carries its own import expression and its own maintainers.

`service_environments` lists every environment nixpkgs' registry knows about,
not just the ones a given service is registered for; `supported` tells them
apart, so the UI can show which environments a service does _not_ work in.

On nixpkgs revisions that predate the split there is no separate environment
half, and every import expression is the portable one.

-}

import Json.Decode
import Json.Decode.Pipeline
import Search.Maintainer exposing (Maintainer)


type alias Environment =
    { environment : String
    , supported : Bool
    , importExpr : Maybe String
    , maintainers : List Maintainer
    }


type alias PackageService =
    { service : String
    , importExpr : String
    , maintainers : List Maintainer
    , environments : List Environment
    }


{-| The environments a service can actually be used in.
-}
supportedEnvironments : List Environment -> List Environment
supportedEnvironments =
    List.filter .supported


{-| Human-readable name for a registry environment.

These names come from nixpkgs' modular service registry, so they are NixOS's
environments. Modular services are also consumed from service managers outside
nixpkgs (nimi, finix, Home Manager); those bring their own registries, and an
index built from one would need its own qualifier here.

-}
environmentLabel : String -> String
environmentLabel environment =
    case environment of
        "system" ->
            "NixOS system"

        "user" ->
            "NixOS user"

        other ->
            other


{-| The configuration path an environment exposes its services under, used to
wrap a usage snippet in the block a user would actually write.

Only environments whose shape we know get one; the rest show their import
expression on its own rather than a snippet that guesses.

-}
environmentUsagePath : String -> Maybe String
environmentUsagePath environment =
    case environment of
        "system" ->
            Just "system.services.<name>"

        _ ->
            Nothing


{-| The import expression to show by default: `system` when the service is
registered for it, otherwise whichever supported environment comes first, and
finally the portable half when there is no environment data at all (index 50,
or a flake).
-}
preferredImport : String -> List Environment -> String
preferredImport fallback environments =
    let
        supported =
            supportedEnvironments environments

        system =
            List.filter (\env -> env.environment == "system") supported
    in
    case List.filterMap .importExpr (system ++ supported) of
        expr :: _ ->
            expr

        [] ->
            fallback


decodeEnvironment : Json.Decode.Decoder Environment
decodeEnvironment =
    Json.Decode.succeed Environment
        |> Json.Decode.Pipeline.required "environment" Json.Decode.string
        -- Indices written before unsupported environments were listed only ever
        -- carried supported ones.
        |> Json.Decode.Pipeline.optional "supported" Json.Decode.bool True
        |> Json.Decode.Pipeline.optional "import"
            (Json.Decode.map Just Json.Decode.string)
            Nothing
        |> Json.Decode.Pipeline.optional "maintainers"
            (Json.Decode.list Search.Maintainer.decode)
            []


decodePackageService : Json.Decode.Decoder PackageService
decodePackageService =
    Json.Decode.succeed PackageService
        |> Json.Decode.Pipeline.required "service" Json.Decode.string
        |> Json.Decode.Pipeline.required "import" Json.Decode.string
        |> Json.Decode.Pipeline.optional "maintainers"
            (Json.Decode.list Search.Maintainer.decode)
            []
        |> Json.Decode.Pipeline.optional "environments"
            (Json.Decode.list decodeEnvironment)
            []
