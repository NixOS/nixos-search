# search.nixos.org

This repository contains the scripts and the web application for
`search.nixos.org`.

## How this project came to be

Initial idea was to replace NixOS packages and options search which was
fetching one JSON file which contained all packages (or options). This approach
is good for its simple setup, but started to show its problems when packages
number was getting bigger and bigger. I'm sure we could optimize it further,
but ideas what all could we do if there would be some database in the back were
to tempting not to try.

For backend we are using Elasticsearch instance which is kindly sponsored by
[bonsai.io](https://bonsai.io). On the frontend we are using
[Elm](https://elm-lang.org).

## How search works?

The use case we want to solve is that a visitor want to see if a package
exists or to look up certain package's details.

A user wants to converge to a single result if possible. The more characters
are added to a search query the more narrow is search is and we should show
less results.

Very important is also ranking of search results. This will bring more relevant
search results to the top, since a lot of times it is hard to produce search
query that will output only one result item.

A less important, but providing better user experience. are suggestions for
writing better search query. Suggesting feature should guide user to write
better queries which in turn will produce better results.

## Development

To start developing open a terminal and run:

```
env --chdir=frontend nix develop -c yarn install
```

... and then:

```
env --chdir=frontend nix develop -c yarn dev
```

You can point your browser to `http://localhost:3000` and start developing.
Any changes to source files (`./frontend/src`) will trigger a hot reload of an
application.

This allows testing the frontend against the 'production' package index.

### elm-review

This project uses `elm-review` to enforce standard rules over Elm code. To use it you can run:

```
env --chdir=frontend nix develop -c yarn elm-review
```

to check the code. You can add `--fix` for automatic fixes, and `--watch` to run it in watch mode during development.

### End-to-end testing

If you want to do a full round-trip test of importing information with
`flake-info` and then viewing it in the frontend, you can run an ephemeral
OpenSearch instance locally using `nixosConfigurations.opensearch-vm`. The VM
can easily be run using `nix run .#opensearch-vm`.

Then you can upload information with something like:

```
flake-info --elastic-schema-version 43 --elastic-index-name=nixos-unstable --push --elastic-exists recreate nixpkgs unstable
```

To point the frontend to the local index, `export ELASTICSEARCH_URL=http://localhost:9200` before running the frontend.
You may need to manually edit `frontend/src/Search.elm` to use the right index.

## Deploying

- On each commit to `main` branch a GitHub Action is triggered.
- GitHub Action then builds production version of the web application using
  `yarn prod` command.
- The built web application (in `./dist`) is then deployed to Netlify.
- GitHub Action can also be triggered via Pull Request, which if Pull Request
  was created from a non-forked repo's branch, will provide a preview url in a
  comment.

## Adding flakes

To add your own flakes to the search index edit [./flakes/manual.toml](./flakes/manual.toml), keeping the alphabetical ordering.

Possible types are `github`, `gitlab`, `sourcehut`, and `git` (which is the fallback for any kind of git repository but requires to set a revision key manually as of now).

To test whether your flake is compatible with nix flake-info you can try running `flake-info` against it

```
$ nix run github:nixos/nixos-search#flake-info -- --json flake <your flake handle>
```

E.g.

```
$ nix run github:nixos/nixos-search#flake-info -- --json flake git+https://codeberg.org/wolfangaukang/python-trovo?ref=main
$ nix run github:nixos/nixos-search#flake-info -- --json flake github:CertainLach/fleet
$ nix run github:nixos/nixos-search#flake-info -- --json flake gitlab:pi-lar/neuropil
$ nix run github:nixos/nixos-search#flake-info -- --json flake sourcehut:~munksgaard/geomyidae-flake
```

### Criteria for inclusion

Inclusion in the search does not imply endorsement by the Nix project or anyone else.

We generally try to include a wide range of flakes that could be of interest to Nix users, but reserve the right to refuse or remove flakes for reasons such as:

- Flakes that do not actually work
- Malicious packages
- Flakes with incorrect or incomplete license metadata
- Lack of relevance
- Programs that are already part of nixpkgs (we prefer you help maintain them there)
- Outdated package or packaging
- Flakes that require `allow-import-from-derivation`

## Contributing patches

- Patches are very welcome!
- You can send a PRs without opening an issue first, but if you're planning significant work it might be good to discuss your ideas beforehand to avoid disappointment later.
- Reviews by people without write access are welcome.
- Every PR requires at least one approval by someone (other than the author) with write access. They can either:
  - approve and merge immediately;
  - approve and leave feedback - the author can merge after considering the feedback;
  - add comments without approving.
