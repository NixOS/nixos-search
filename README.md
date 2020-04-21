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


## Ideas we want to explore

Apart from searching packages and options we would like to:

- Not only search for latest channels, but be enable to search in any
  evaluation. We need to explore how much in the past we can go, I'm sure we
  will have to make some compromises.
- Provide each maintainer with a page that lists packages that they
  maintain. A page - later - could also show his ticket and opened Pull
  Requests.
- Each package should have a page which would show versions in different
  evaluations/channels. It could also show - at one point - ticket that this
  package
- With all this information in the database it would be very useful to show
  some sort of reports. Few examples that come to my mind:
   - What packages and options were added/removed/changed between to evaluations?
     This could be useful for Release Manager when making release notes or just
     in general to see difference what has changed since last time.
   - How are we doing with tickets/pull requests? Burn-down chart maybe. The
     idea behind is to have a nicer view over current status of tickets/pull
     requests.

Probably there are more ideas I just need to remind myself to write them down.


## Development

To start developing open a terminal and run:

```
$ nix-shell --run "yarn dev"
```

You can point your browser to `http://localhost:3000` and start developing.
Any changes to source files (`./src`) will trigger a hot reload of an
application.


## Deploying

- On each commit to `master` branch a GitHub Action is trigger.
- GitHub Action then builds production version of the web application using
  `yarn prod` command.
- The built web application (in `./dist`) is then deployed to Netlify.
- GitHub Action can also be triggered via Pull Request, which if Pull Request
  was created from a non-forked repo's branch, will provide a preview url in a
  comment.
