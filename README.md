# search.nixos.org

This repository contains the scripts and the web application for
`search.nixos.org`. 


## How this project came to be

Initial idea was to replace NixOS packages and options search which was
fetching one JSON file which contained all packages (or options). This approach
is good for its simple setup, but started to show its problems when packages
number was getting bigger and bigger. I'm sure we could optimize it further,
but ideas what all could we do if there would be some database in the back were
too tempting not to try.

For backend we are using Elasticsearch instance which is kindly sponsored by
[bonsai.io](https://bonsai.io). On the frontend we are using
[Elm](https://elm-lang.org).


## How search works?

The use case we want to solve is that a visitor wants to see if a package
exists or to look up certain package's details.

A user wants to converge to a single result if possible. The more characters
are added to a search query the more narrow is search is and we should show
less results.

Very important is also ranking of search results. This will bring more relevant
search results to the top, since a lot of times it is hard to produce search
query that will output only one result item.

A less important, but providing better user experience, are suggestions for
writing better search query. Suggesting feature should guide the user to write
better queries which in turn will produce better results.


## Development

To start developing open a terminal and run:

```
env --chdir=frontend nix develop -c yarn dev
```

You can point your browser to `http://localhost:3000` and start developing.
Any changes to source files (`./frontend/src`) will trigger a hot reload of the
application.


## Deploying

- On each commit to `main` branch a GitHub Action is triggered.
- GitHub Action then builds production version of the web application using
  `yarn prod` command.
- The built web application (in `./dist`) is then deployed to Netlify.
- GitHub Action can also be triggered via Pull Request, which if Pull Request
  was created from a non-forked repo's branch, will provide a preview url in a
  comment.

## Adding flakes

To add your own flakes to the search index edit [./flakes/manual.toml](./flakes/manual.toml).

Possible types are `github`, `gitlab`, `sourcehut`, and `git` (which is the fallback for any kind of git repository but requires to set a revision key manually as of now).

To test whether your flake is compatible with nix flake-info you can try running `flake-info` against it:

```
$ nix run github:nixos/nixos-search#flake-info -- flake <your flake handle>
```
