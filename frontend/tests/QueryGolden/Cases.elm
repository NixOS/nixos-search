module QueryGolden.Cases exposing (cases)

{-| The request bodies that `QueryGolden` compares to `QueryGolden.Expected`.

The cases cover each sort, the bucket filters, negated words, the result cap
and the word shapes that the ranking clauses examine. To write the expected
bodies again after an intended change to the query, run
`npm run build:query-golden`.

-}

import Json.Encode
import Search exposing (Sort(..))
import Search.Query


cases : List ( String, Json.Encode.Value )
cases =
    [ ( "packages, empty query"
      , Search.Query.packagesBody "" 0 50 Relevance []
      )
    , ( "packages, one word"
      , Search.Query.packagesBody "firefox" 0 50 Relevance []
      )
    , ( "packages, words with a negation"
      , Search.Query.packagesBody "  Python3 web -django " 0 50 Relevance []
      )
    , ( "packages, dashes, underscores and dots"
      , Search.Query.packagesBody "python3-requests_oauthlib lib.dot" 0 50 Relevance []
      )
    , ( "packages, ascending with buckets"
      , Search.Query.packagesBody "git" 20 50 AlphabeticallyAsc [ ( "package_license_set", [ "MIT", "GPL" ] ), ( "package_platforms", [ "x86_64-linux" ] ) ]
      )
    , ( "packages, descending near the result cap"
      , Search.Query.packagesBody "gcc" 9980 50 AlphabeticallyDesc []
      )
    , ( "options, empty query"
      , Search.Query.optionsBody [ "option" ] "" 0 50 Relevance
      )
    , ( "options, dotted name"
      , Search.Query.optionsBody [ "option" ] "services.nginx.enable" 0 50 Relevance
      )
    , ( "options, two types, ascending with a negation"
      , Search.Query.optionsBody [ "option", "service" ] "boot loader -grub" 0 50 AlphabeticallyAsc
      )
    , ( "options, descending"
      , Search.Query.optionsBody [ "option" ] "networking firewall" 0 50 AlphabeticallyDesc
      )
    ]
