# Flake Info

A tool that fetches packages and apps from nix flakes.

## Usage

```
flake-info 0.3.0
Extracts various information from a given flake

USAGE:
    flake-info [FLAGS] [OPTIONS] [extra]... <SUBCOMMAND>

FLAGS:
        --push       Push to Elasticsearch (Configure using FI_ES_* environment variables)
    -h, --help       Prints help information
        --json       Print ElasticSeach Compatible JSON output
    -V, --version    Prints version information

OPTIONS:
        --elastic-exists <elastic-exists>
            How to react to existing indices [env: FI_ES_EXISTS_STRATEGY=]  [default: abort]  [possible values: Abort,
            Ignore, Recreate]
        --elastic-index-name <elastic-index-name>            Name of the index to store results to [env: FI_ES_INDEX=]
    -p, --elastic-pw <elastic-pw>
            Elasticsearch password (unimplemented) [env: FI_ES_PASSWORD=]

        --elastic-schema-version <elastic-schema-version>
            Which schema version to associate with the operation [env: FI_ES_VERSION=]

        --elastic-url <elastic-url>
            Elasticsearch instance url [env: FI_ES_URL=]  [default: http://localhost:9200]

    -u, --elastic-user <elastic-user>                        Elasticsearch username (unimplemented) [env: FI_ES_USER=]
    -k, --kind <kind>
            Kind of data to extract (packages|options|apps|all) [default: all]


ARGS:
    <extra>...    Extra arguments that are passed to nix as it

SUBCOMMANDS:
    flake
    group
    help       Prints this message or the help of the given subcommand(s)
    nixpkgs
```

### flake

Flakes can be imported using the flake subcommand

```
USAGE:
    flake-info flake [FLAGS] <flake>

FLAGS:
        --gc            Whether to gc the store after info or not
    -h, --help          Prints help information
        --temp-store    Whether to use a temporary store or not. Located at /tmp/flake-info-store
    -V, --version       Prints version information

ARGS:
    <flake>    Flake identifier passed to nix to gather information about
```

The `<flake>` argument should contain a valid reference to a flake. It accepts all formats nix accepts:

> use git+<url> to checkout a git repository at <url>
> use /local/absolute/path or ./relative/path to load a local source
> use gitlab:<user>/<repo>/github:<user>/<repo>/sourcehut:<user>/<repo> to
> shortcut gitlab, github or sourcehut repositories


Optionally, analyzing can be done in a temporary store enabled by the `--temp-store` option.

#### Example

```
$ flake-info flake github:ngi-nix/offen
```

### nixpkgs

nixpkgs currently have to be imported in a different way. This is what the `nixpkgs` subcommand exists for.

It takes any valid git reference to the upstream [`nixos/nixpkgs`](https://github.com/nixos/nixpkgs/) repo as an argument and produces a complete output.

**This operation may take a short while and produces lots of output**

#### Example

```
$ flake-info nixpkgs nixos-21.05
```

### group

to perform a bulk import grouping multiple inputs under the same name/index use the group command.

It expects a JSON file as input that contains references to flakes or nixpkgs. If those resources are on GitHub, GitLab or SourceHut they can be extended with more meta information including pinning the commit hash/ref.

The second argument is the group name that is used to provide the index name.

#### Example

An example `targets.json` file can look like the following

```json
[
    {
        "type": "git",
        "url": "./."
    },
    {
        "type": "git",
        "url": "github:fluffynukeit/adaspark"
    },
    {
        "type": "github",
        "owner": "ngi-nix",
        "repo": "offen",
        "hash": "4052febf151d60aa4352fa1960cf3ae088f600aa",
        "description": "Hier könnte Ihre Werbung stehen"
    }
]
```

```
$ flake-info --json group ./targets.json small-group
```

### Elasticsearch

A number of flags is dedicated to pushing to elasticsearch.

```
    --elastic-exists <elastic-exists>
        How to react to existing indices [env: FI_ES_EXISTS_STRATEGY=]  [default: abort]
                                            [possible values: Abort, Ignore, Recreate]
    --elastic-index-name <elastic-index-name>
        Name of the index to store results to [env: FI_ES_INDEX=]
-p, --elastic-pw <elastic-pw>
        Elasticsearch password (unimplemented) [env: FI_ES_PASSWORD=]

    --elastic-schema-version <elastic-schema-version>
        Which schema version to associate with the operation [env: FI_ES_VERSION=]

    --elastic-url <elastic-url>
        Elasticsearch instance url [env: FI_ES_URL=]  [default: http://localhost:9200]

-u, --elastic-user <elastic-user>                        Elasticsearch username (unimplemented) [env: FI_ES_USER=]
```


#### Example

```
$ flake-info --push \
             --elastic-url http://localhost:5555 \
             --elastic-index-name latest-21-21.05
             --elastic-schema-version 21 group ./examples/ngi-nix.json ngi-nix
```


## Installation

### Preparations

This tool requires your system to have Nix installed!

You can install nix using this installer: https://nixos.org/guides/install-nix.html
Also, see https://wiki.nixos.org/wiki/Nix_Installation_Guide if your system is ✨special✨.

### Preparations (Docker)

If you do not want to install nix on your system, using Docker is an alternative.

Enter the [nixos/nix](https://hub.docker.com/u/nixos/) docker image and proceed

### Setup nix flakes

Note that you also need to have nix flakes support.

Once you have nix installed run the following commands:

1. ```
   $ nix-shell -I nixpkgs=channel:nixos-21.05 -p nixFlakes
   ```
   to enter a shell with the preview version of nix flakes installed.
2. ```
   $ mkdir -p ~/.config/nix
   $ echo "experimental-features = nix-command flakes" > .config/nix/nix.conf
   ```
   to enable flake support

### Installation, finally

This project is defined as a flake therefore you can build the tool using

```
$ nix build <project root>
or
$ nix build github:miszkur/github-search
```

Replace `build` with run if you want to run the tool directly.
