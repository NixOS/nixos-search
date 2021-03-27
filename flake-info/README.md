# Flake Info

A tool that fetches packages and apps from nix flakes.

## Usage

```
flake-info 0.2.0
Extracts various information from a given flake

USAGE:
    flake-info [FLAGS] [OPTIONS] [extra]...

FLAGS:
        --elastic-recreate-index    Elasticsearch instance url
        --push                      Push to Elasticsearch (Configure using FI_ES_* environment variables)
        --gc                        Whether to use a temporary store or not. Located at /tmp/flake-info-store
    -h, --help                      Prints help information
        --temp-store                Whether to use a temporary store or not. Located at /tmp/flake-info-store
    -V, --version                   Prints version information

OPTIONS:
        --elastic-index-name <elastic-index-name>
            Name of the index to store results to [env: FI_ES_INDEX=]  [default: flakes_index]

    -p, --elastic-pw <elastic-pw>                    Elasticsearch password (unimplemented) [env: FI_ES_PASSWORD=]
        --elastic-url <elastic-url>
            Elasticsearch instance url [env: FI_ES_URL=]  [default: http://localhost:9200]

    -u, --elastic-user <elastic-user>                Elasticsearch username (unimplemented) [env: FI_ES_USER=]
    -f, --flake <flake>                              Flake identifier passed to nix to gather information about
    -k, --kind <kind>                                Kind of data to extract (packages|options|apps|all) [default: all]
    -t, --targets <targets>                          Points to a JSON file containing info targets

ARGS:
    <extra>...    Extra arguments that are passed to nix as it
```

### flake/targets

Use either of these options to define which flake you want to query.

`--flake | -f`: takes a flake reference in the same format as nix

> use git+<url> to checkout a git repository at <url>
> use /local/absolute/path or ./relative/path to load a local source
> use gitlab:<user>/<repo>/github:<user>/<repo> to shortcut gitlab or github repositories

`--targets | -t`: refers to a json file that contains a list of queried repositories:

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

Currently `github` and `gitlab` can be used as source repos with hash. the `hash` attribute defines the fetched git reference (branch, commit, tag, etc).

## Installation

### Preparations

This tool requires your system to have Nix installed!

You can install nix using this installer: https://nixos.org/guides/install-nix.html
Also, see https://nixos.wiki/wiki/Nix_Installation_Guide if your system is ✨special✨.

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
