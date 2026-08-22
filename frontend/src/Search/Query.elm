module Search.Query exposing (optionsBody, packagesBody, platforms)

{-| Single source of truth for the Elasticsearch query the client sends.

Ranking relevant hyperparameters should always be added to this file.

Further consumers may add filtering aspects. Which does not affect ranking quality.

-}

import Json.Encode
import List.Extra
import Search exposing (Sort(..), Terms)


platforms : List String
platforms =
    [ "x86_64-linux"
    , "aarch64-linux"
    , "i686-linux"
    , "x86_64-darwin"
    , "aarch64-darwin"
    ]


{-| One Elasticsearch clause, as the key/value pairs of its object.

Left unwrapped so that a list of them goes straight into
`Json.Encode.list Json.Encode.object`.

-}
type alias Clause =
    List ( String, Json.Encode.Value )


{-| The ranking half of the query: what a track contributes to the `bool`'s
`must` and `should`. The rest of the body - the filters, the aggregations, the
sort - is the same shape for both tracks.
-}
type alias Ranking =
    { must : List Clause
    , should : List Clause
    }


packagesBody :
    String
    -> Int
    -> Int
    -> Sort
    -> List ( String, List String )
    -> Json.Encode.Value
packagesBody query from size sort selectedBuckets =
    let
        terms : List Terms
        terms =
            [ { field = "package_attr_set", size = 20, include = Nothing }
            , { field = "package_license_set", size = 20, include = Nothing }
            , { field = "package_maintainers_set", size = 20, include = Nothing }
            , { field = "package_teams_set", size = 20, include = Nothing }
            , { field = "package_platforms", size = 20, include = Just platforms }
            ]

        selectionFor : String -> List String
        selectionFor field =
            selectedBuckets
                |> List.filter (\( f, _ ) -> f == field)
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault []

        filterByBuckets : List ( String, Json.Encode.Value )
        filterByBuckets =
            [ ( "bool"
              , Json.Encode.object
                    [ ( "must"
                      , Json.Encode.list Json.Encode.object
                            (List.map
                                (\term ->
                                    [ ( "bool"
                                      , Json.Encode.object
                                            [ ( "should"
                                              , Json.Encode.list Json.Encode.object <|
                                                    List.map
                                                        (filterByBucket term.field)
                                                        (selectionFor term.field)
                                              )
                                            ]
                                      )
                                    ]
                                )
                                terms
                            )
                      )
                    ]
              )
            ]
    in
    encodeRequestBody
        { query = String.trim query
        , from = from
        , size = size
        , sort = sort
        , types = [ "package" ]
        , sortField = "package_attr_name"
        , otherSortFields = [ "package_pversion" ]
        , terms = terms
        , filterByBuckets = filterByBuckets
        , negatedFields = [ "package_attr_name" ]
        , ranking = packagesRanking
        , rescore = Just { field = "package_attr_name", weight = 30.3 }
        }


filterByBucket : String -> String -> List ( String, Json.Encode.Value )
filterByBucket field value =
    [ ( "term"
      , Json.Encode.object
            [ ( field
              , Json.Encode.object
                    [ ( "value", Json.Encode.string value )
                    , ( "_name", Json.Encode.string <| "filter_bucket_" ++ field )
                    ]
              )
            ]
      )
    ]


optionsBody :
    List String
    -> String
    -> Int
    -> Int
    -> Sort
    -> Json.Encode.Value
optionsBody types query from size sort =
    encodeRequestBody
        { query = String.trim query
        , from = from
        , size = size
        , sort = sort
        , types = types
        , sortField = "option_name"
        , otherSortFields = []
        , terms = []
        , filterByBuckets = []
        , negatedFields = [ "option_name" ]
        , ranking = optionsRanking
        , rescore = Just { field = "option_name", weight = 22.3 }
        }



-- THE RANKING
--
-- Almost nothing in the two rankings below was chosen by hand. Both are the
-- champion of an evolutionary search over the clause structure, the fields and
-- the boosts, scored against `benchmark/run.mjs` on a held-out 30% of the
-- curated queries. Read them as found artefacts rather than as argued designs:
-- the notes say what the result does, not what anyone intended it to do. The one
-- exception is `fuzzyDescription` in `optionsRanking`, which is marked as such.
--
-- Every number here is a ranking decision, so changing one should come with a
-- benchmark delta.


{-| How a package query is ranked.

A package can match on its description alone. The `must` is a `dis_max` over a
`constant_score` phrase on the descriptions, a fuzzy `best_fields` on the last
word of the query, and each word as `*word*` against the attribute name. The
shape this replaced reached the descriptions only through `should`, so a query
that named no package matched nothing at all, which is where it was losing.

Two of the `should` clauses look like they should be inert and are not. The
`log` `rank_feature` reads `package_repology_repos`, the same field the
`saturation` below it already reads, and the `bool` carries a `rank_feature` in
its `must` next to a lone scoring `should`. Removing them costs 0.014 and 0.007
nDCG respectively, so they stand because they were measured rather than because
they read well.

-}
packagesRanking : List String -> Ranking
packagesRanking words =
    let
        -- The whole query as a phrase over both description fields.
        descriptionPhrase : List Clause
        descriptionPhrase =
            constantScore 110.0
                (multiMatchClauses
                    { kind = "phrase"
                    , between = []
                    , fields =
                        [ "package_description^7.42"
                        , "package_longDescription^1"
                        ]
                    , boost = Nothing
                    }
                    (multiWordWhole words)
                )

        -- The last word only, spelled approximately: `fierfix` still finds
        -- `firefox`.
        fuzzyLastWord : List Clause
        fuzzyLastWord =
            multiMatchClauses
                { kind = "best_fields"
                , between =
                    [ ( "fuzziness", Json.Encode.string "1" )
                    , ( "prefix_length", Json.Encode.int 1 )
                    , ( "minimum_should_match", Json.Encode.string "20%" )
                    , ( "_name", Json.Encode.string ("fuzzy_" ++ String.join "_" words) )
                    ]
                , fields =
                    [ "package_attr_name^0.378"
                    , "package_programs^0.441"
                    , "package_mainProgram^0.413"
                    , "package_pname^0.30000000000000004"
                    ]
                , boost = Nothing
                }
                (lastWord words)

        -- Each word as a substring of the attribute name. On the plain keyword
        -- rather than its edge-ngrams: the ngram subfield scored a hair better
        -- and cost 34 ms per query.
        attrNameSubstrings : List Clause
        attrNameSubstrings =
            keywordClauses
                { kind = "wildcard"
                , field = "package_attr_name"
                , boost = Nothing
                , caseInsensitive = True
                }
                (perWord { variants = True, surround = True } words)

        -- The words glued back into one attribute name, exactly and as a prefix.
        exactName : List Clause
        exactName =
            keywordClauses
                { kind = "term"
                , field = "package_attr_name"
                , boost = Just 127.0
                , caseInsensitive = False
                }
                (glued "-" words)

        namePrefix : List Clause
        namePrefix =
            keywordClauses
                { kind = "prefix"
                , field = "package_attr_name"
                , boost = Just 16.4
                , caseInsensitive = True
                }
                (glued "" words)

        pnamePrefix : List Clause
        pnamePrefix =
            keywordClauses
                { kind = "prefix"
                , field = "package_pname"
                , boost = Just 10.1
                , caseInsensitive = True
                }
                (glued "" words)

        -- Everything but the last word, which for `python http server` is the
        -- part that qualifies rather than names.
        leadingWords : List Clause
        leadingWords =
            multiMatchClauses
                { kind = "cross_fields"
                , between = [ ( "analyzer", Json.Encode.string "keyword" ) ]
                , fields =
                    [ "package_pname.edge^3.52"
                    , "package_description^1.17"
                    , "package_programs^117"
                    ]
                , boost = Nothing
                }
                (allButLast words)

        -- Popularity, read twice from the same field.
        popularity : List Clause
        popularity =
            [ rankFeature
                { field = "package_repology_repos"
                , boost = Just 328.0
                , name = Nothing
                , fn = logFn 5140.0
                }
            , rankFeature
                { field = "package_repology_repos"
                , boost = Just 5.0
                , name = Just "popularity_package_repology_repos"
                , fn = saturationFn 13.5
                }
            ]

        -- Dependency count beside a weak per-word match on the long description,
        -- the attribute set and the attribute name's edge-ngrams.
        depCountAndText : List Clause
        depCountAndText =
            [ [ ( "bool"
                , Json.Encode.object
                    [ ( "must"
                      , Json.Encode.list Json.Encode.object
                            [ rankFeature
                                { field = "package_dep_count"
                                , boost = Nothing
                                , name = Nothing
                                , fn = sigmoidFn 7580.0 0.434
                                }
                            ]
                      )
                    , ( "should"
                      , Json.Encode.list Json.Encode.object
                            (multiMatchClauses
                                { kind = "best_fields"
                                , between = [ ( "analyzer", Json.Encode.string "lowercase" ) ]
                                , fields =
                                    [ "package_longDescription.edge^12"
                                    , "package_attr_set^2.97"
                                    , "package_attr_name.edge^0.307"
                                    ]
                                , boost = Just 0.128
                                }
                                (perWord { variants = False, surround = False } words)
                            )
                      )
                    , ( "boost", Json.Encode.float 0.364 )
                    ]
                )
              ]
            ]

        -- The query read as a program path: `python.http.server`.
        programPath : List Clause
        programPath =
            keywordClauses
                { kind = "wildcard"
                , field = "package_programs"
                , boost = Just 12.8
                , caseInsensitive = True
                }
                (dotted words)
    in
    { must =
        [ disMax
            { tieBreaker = Just 0.387
            , boost = Nothing
            , queries = descriptionPhrase ++ fuzzyLastWord ++ attrNameSubstrings
            }
        ]
    , should =
        exactName
            ++ namePrefix
            ++ leadingWords
            ++ pnamePrefix
            ++ popularity
            ++ depCountAndText
            ++ programPath
    }


{-| How an option query is ranked.

An option matches on its name, or failing that on a misspelling of its
description. The `must` is one `dis_max` over two readings of the name - the
dash-glued query as a prefix of `attr_path_reverse`, and each word as `*word*`
against the edge-ngrams - plus `fuzzyDescription` behind them at a boost three
orders of magnitude smaller, which is what a query nothing else matched falls
back to.

The three `constant_score` clauses discard the score of what they wrap and return
their own boost, which makes the large inner numbers - `option_name^630`,
`option_name.attr_path_reverse^682` - inert, and the small outer boost the weight
the clause actually carries. They stand as found rather than tidied into
something that would no longer be the shape that was measured.

-}
optionsRanking : List String -> Ranking
optionsRanking words =
    let
        -- The whole query as a prefix of the name read back-to-front, so
        -- `nginx.enable` reaches `services.nginx.enable`.
        reversePathPrefix : List Clause
        reversePathPrefix =
            keywordClauses
                { kind = "prefix"
                , field = "option_name.attr_path_reverse"
                , boost = Just 26.4
                , caseInsensitive = False
                }
                (glued "-" words)

        nameSubstrings : List Clause
        nameSubstrings =
            keywordClauses
                { kind = "wildcard"
                , field = "option_name.edge"
                , boost = Nothing
                , caseInsensitive = False
                }
                (perWord { variants = True, surround = True } words)

        -- The words read as an attribute path, forwards and backwards.
        forwardPath : List Clause
        forwardPath =
            keywordClauses
                { kind = "wildcard"
                , field = "option_name.attr_path"
                , boost = Just 0.546
                , caseInsensitive = False
                }
                (dotted words)

        leadingWords : List Clause
        leadingWords =
            keywordClauses
                { kind = "prefix"
                , field = "option_name.attr_path_reverse"
                , boost = Just 206.0
                , caseInsensitive = True
                }
                (allButLast words)

        -- The module entry point: `postgresql` reaches
        -- `services.postgresql.package`.
        packageLeaf : List Clause
        packageLeaf =
            keywordClauses
                { kind = "wildcard"
                , field = "option_name.attr_path_reverse"
                , boost = Just 0.111
                , caseInsensitive = False
                }
                (dottedPlus ".package" words)

        -- A literal the shape carries rather than one the user typed: options
        -- named `enable` are what most option queries are after.
        enableLeaf : List Clause
        enableLeaf =
            constantScore 0.128
                (multiMatchClauses
                    { kind = "phrase_prefix"
                    , between = [ ( "operator", Json.Encode.string "or" ) ]
                    , fields =
                        [ "service_packages.edge^373"
                        , "option_name.edge^11.6"
                        , "service_packages.edge^0.839"
                        , "option_name.attr_path_reverse^682"
                        ]
                    , boost = Just 5.45
                    }
                    (fixed "enable" words)
                )

        lastWordPhrase : List Clause
        lastWordPhrase =
            constantScore 0.0682
                (multiMatchClauses
                    { kind = "phrase"
                    , between = []
                    , fields =
                        [ "service_packages.edge^206"
                        , "option_description^11.6"
                        , "option_description.*^0.65"
                        , "option_name^630"
                        ]
                    , boost = Just 105.0
                    }
                    (lastWord words)
                )

        -- The one clause here that no search found. It sits at a boost small
        -- enough that it cannot outrank any name match, so it only decides the
        -- order of a page the name clauses left empty - which for a misspelled
        -- query is every page. `ngnix` reaches `services.nginx.enable` through
        -- the word `Nginx` in its description, because no subfield of
        -- `option_name` ever yields that word as a token to be spelled wrong.
        fuzzyDescription : List Clause
        fuzzyDescription =
            multiMatchClauses
                { kind = "best_fields"
                , between =
                    [ ( "fuzziness", Json.Encode.string "1" )
                    , ( "prefix_length", Json.Encode.int 1 )
                    ]
                , fields = [ "option_description^1" ]
                , boost = Just 0.0001
                }
                (whole words)

        lastWordCrossFields : List Clause
        lastWordCrossFields =
            constantScore 0.0975
                (multiMatchClauses
                    { kind = "cross_fields"
                    , between = []
                    , fields =
                        [ "service_packages.edge^384"
                        , "option_name.edge^11.6"
                        , "option_description.*^0.542"
                        , "option_name.attr_path_reverse^746"
                        ]
                    , boost = Just 39.3
                    }
                    (lastWord words)
                )
    in
    { must =
        [ disMax
            { tieBreaker = Just 0.509
            , boost = Just 8.33
            , queries = reversePathPrefix ++ nameSubstrings ++ fuzzyDescription
            }
        ]
    , should =
        forwardPath
            ++ leadingWords
            ++ packageLeaf
            ++ enableLeaf
            ++ lastWordPhrase
            ++ lastWordCrossFields
    }



-- THE QUERY TEXT
--
-- A clause does not take the query verbatim, it takes one derivation of it, and
-- a derivation can yield several spellings or none at all. `postgresql enable`
-- is `postgresql-enable` glued, `postgresql.enable` dotted, `enable` as its last
-- word, and `*postgresql*` and `*enable*` per word.


{-| Did the user type anything?

An empty search box splits into one empty word rather than into no words, so this
is a question about the words' contents and not about how many there are.

-}
typed : List String -> Bool
typed words =
    List.any (String.isEmpty >> not) words


{-| Derivations that only make sense against text the user typed. `Glued` is the
exception: an empty attribute name is still a name to ask about.
-}
whenTyped : List String -> List String -> List String
whenTyped words derived =
    if typed words then
        derived

    else
        []


{-| The words joined by spaces, however many there are.
-}
whole : List String -> List String
whole words =
    [ String.join " " words ]


{-| The words joined by spaces, but only where there is more than one. A phrase
over a single word is that word, which the clauses that name it already cover.
-}
multiWordWhole : List String -> List String
multiWordWhole words =
    if List.length words > 1 then
        [ String.join " " words ]

    else
        []


{-| The words joined with no separator, a `-` or a `_`. A keyword field holds a
name as one token, so a multi-word query only reaches one glued back together.
-}
glued : String -> List String -> List String
glued separator words =
    [ String.join separator words ]


{-| The words as an attribute path.
-}
dotted : List String -> List String
dotted words =
    whenTyped words [ String.join "." words ]


{-| The words as an attribute path with a literal leaf appended, which turns
`postgresql` into `postgresql.package`.
-}
dottedPlus : String -> List String -> List String
dottedPlus suffix words =
    whenTyped words [ String.join "." words ++ suffix ]


{-| The last word of `nginx virtual hosts`, which is the one that names.
-}
lastWord : List String -> List String
lastWord words =
    whenTyped words
        (List.Extra.last words
            |> Maybe.map List.singleton
            |> Maybe.withDefault []
        )


{-| Everything before the last word, which is the part that qualifies.
-}
allButLast : List String -> List String
allButLast words =
    whenTyped words
        (case List.Extra.init words of
            Just [] ->
                []

            Just leading ->
                [ String.join " " leading ]

            Nothing ->
                []
        )


{-| A literal the ranking carries rather than one the user typed. It fires only
next to a derived clause, never on an empty search box of its own.
-}
fixed : String -> List String -> List String
fixed value words =
    whenTyped words [ value ]


{-| One spelling per word: optionally per dash/underscore spelling of each word,
optionally wrapped in `*` for a substring match.
-}
perWord : { variants : Bool, surround : Bool } -> List String -> List String
perWord spec words =
    words
        |> (if spec.variants then
                List.concatMap dashUnderscoreVariants

            else
                identity
           )
        |> List.Extra.unique
        |> List.map
            (if spec.surround then
                \word -> "*" ++ word ++ "*"

             else
                identity
            )


dashUnderscoreVariants : String -> List String
dashUnderscoreVariants word =
    [ String.replace "_" "-" word
    , String.replace "-" "_" word
    , word
    ]



-- THE CLAUSES
--
-- One builder per Elasticsearch clause the rankings use. Each takes the
-- spellings a derivation produced and returns one clause per spelling, so a
-- derivation that produced nothing contributes nothing.


{-| A `term`, `prefix` or `wildcard` against a single keyword field.
-}
keywordClauses :
    { kind : String
    , field : String
    , boost : Maybe Float
    , caseInsensitive : Bool
    }
    -> List String
    -> List Clause
keywordClauses spec texts =
    texts
        |> List.map
            (\text ->
                [ ( spec.kind
                  , Json.Encode.object
                        [ ( spec.field
                          , Json.Encode.object
                                (( "value", Json.Encode.string text )
                                    :: optionalFloat "boost" spec.boost
                                    ++ (if spec.caseInsensitive then
                                            [ ( "case_insensitive", Json.Encode.bool True ) ]

                                        else
                                            []
                                       )
                                )
                          )
                        ]
                  )
                ]
            )


{-| A `multi_match` over weighted fields. `between` carries whatever the clause
sets between the query and the fields - an analyzer, a fuzziness, a name.
-}
multiMatchClauses :
    { kind : String
    , between : List ( String, Json.Encode.Value )
    , fields : List String
    , boost : Maybe Float
    }
    -> List String
    -> List Clause
multiMatchClauses spec texts =
    texts
        |> List.map
            (\text ->
                [ ( "multi_match"
                  , Json.Encode.object
                        ([ ( "type", Json.Encode.string spec.kind )
                         , ( "query", Json.Encode.string text )
                         ]
                            ++ spec.between
                            ++ [ ( "fields", Json.Encode.list Json.Encode.string spec.fields ) ]
                            ++ optionalFloat "boost" spec.boost
                        )
                  )
                ]
            )


{-| The best of several readings rather than the sum of them, so a document that
matches two of them is not thereby twice as good a hit.
-}
disMax :
    { tieBreaker : Maybe Float
    , boost : Maybe Float
    , queries : List Clause
    }
    -> Clause
disMax spec =
    [ ( "dis_max"
      , Json.Encode.object
            (optionalFloat "tie_breaker" spec.tieBreaker
                ++ [ ( "queries", Json.Encode.list Json.Encode.object spec.queries ) ]
                ++ optionalFloat "boost" spec.boost
            )
      )
    ]


{-| Discard the score of what is wrapped and return a fixed boost instead, which
makes the clause a yes/no rather than a how-well.
-}
constantScore : Float -> List Clause -> List Clause
constantScore boost inner =
    inner
        |> List.map
            (\one ->
                [ ( "constant_score"
                  , Json.Encode.object
                        [ ( "filter", Json.Encode.object one )
                        , ( "boost", Json.Encode.float boost )
                        ]
                  )
                ]
            )


{-| A numeric signal the index carries as a `rank_feature`, read through one of
the saturating functions Elasticsearch offers.
-}
rankFeature :
    { field : String
    , boost : Maybe Float
    , name : Maybe String
    , fn : ( String, Json.Encode.Value )
    }
    -> Clause
rankFeature spec =
    [ ( "rank_feature"
      , Json.Encode.object
            (( "field", Json.Encode.string spec.field )
                :: optionalFloat "boost" spec.boost
                ++ (case spec.name of
                        Just name ->
                            [ ( "_name", Json.Encode.string name ) ]

                        Nothing ->
                            []
                   )
                ++ [ spec.fn ]
            )
      )
    ]


saturationFn : Float -> ( String, Json.Encode.Value )
saturationFn pivot =
    ( "saturation"
    , Json.Encode.object [ ( "pivot", Json.Encode.float pivot ) ]
    )


logFn : Float -> ( String, Json.Encode.Value )
logFn scalingFactor =
    ( "log"
    , Json.Encode.object [ ( "scaling_factor", Json.Encode.float scalingFactor ) ]
    )


sigmoidFn : Float -> Float -> ( String, Json.Encode.Value )
sigmoidFn pivot exponent =
    ( "sigmoid"
    , Json.Encode.object
        [ ( "pivot", Json.Encode.float pivot )
        , ( "exponent", Json.Encode.float exponent )
        ]
    )


optionalFloat : String -> Maybe Float -> List ( String, Json.Encode.Value )
optionalFloat key value =
    case value of
        Just float ->
            [ ( key, Json.Encode.float float ) ]

        Nothing ->
            []



-- THE ENVELOPE
--
-- Which documents are eligible, how they are paged and sorted, and what is
-- counted alongside them. None of this is ranking, and none of it differs
-- between the two tracks except in the values the callers above pass in.


toAggregations :
    List Terms
    -> ( String, Json.Encode.Value )
toAggregations terms =
    let
        aggs =
            List.map
                (\term ->
                    ( term.field
                    , Json.Encode.object
                        [ ( "terms"
                          , Json.Encode.object
                                ([ ( "field"
                                   , Json.Encode.string term.field
                                   )
                                 , ( "size"
                                   , Json.Encode.int term.size
                                   )
                                 ]
                                    ++ (case term.include of
                                            Just include ->
                                                [ ( "include"
                                                  , Json.Encode.list Json.Encode.string include
                                                  )
                                                ]

                                            Nothing ->
                                                []
                                       )
                                )
                          )
                        ]
                    )
                )
                terms

        allAggs =
            [ ( "all"
              , Json.Encode.object
                    [ ( "global"
                      , Json.Encode.object []
                      )
                    , ( "aggregations"
                      , Json.Encode.object aggs
                      )
                    ]
              )
            ]
    in
    ( "aggs"
    , Json.Encode.object <| aggs ++ allAggs
    )


toSortQuery :
    Sort
    -> String
    -> List String
    -> ( String, Json.Encode.Value )
toSortQuery sort field fields =
    ( "sort"
    , case sort of
        AlphabeticallyAsc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "asc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "asc" ))
                        fields
                ]

        AlphabeticallyDesc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "desc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "desc" ))
                        fields
                ]

        Relevance ->
            Json.Encode.list Json.Encode.object
                [ ( "_score", Json.Encode.string "desc" )
                    :: ( field, Json.Encode.string "asc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "asc" ))
                        fields
                ]
    )


filterByType :
    List String
    -> List ( String, Json.Encode.Value )
filterByType types =
    case types of
        [ type_ ] ->
            [ ( "term"
              , Json.Encode.object
                    [ ( "type"
                      , Json.Encode.object
                            [ ( "value", Json.Encode.string type_ )
                            , ( "_name", Json.Encode.string <| "filter_" ++ type_ ++ "s" )
                            ]
                      )
                    ]
              )
            ]

        _ ->
            [ ( "terms"
              , Json.Encode.object
                    [ ( "type", Json.Encode.list Json.Encode.string types )
                    , ( "_name", Json.Encode.string <| "filter_" ++ String.join "_" types )
                    ]
              )
            ]


{-| Nudge shorter names up, once the ranking has settled on a page of them.

A rescore only reorders the window it is given, so it is a tie-break among hits
the query already liked rather than a scoring signal of its own. Documents
without the field score 0 instead of dividing by nothing.

-}
rescoreQuery : { field : String, weight : Float } -> ( String, Json.Encode.Value )
rescoreQuery { field, weight } =
    ( "rescore"
    , Json.Encode.object
        [ ( "window_size", Json.Encode.int 100 )
        , ( "query"
          , Json.Encode.object
                [ ( "rescore_query"
                  , Json.Encode.object
                        [ ( "function_score"
                          , Json.Encode.object
                                [ ( "script_score"
                                  , Json.Encode.object
                                        [ ( "script"
                                          , Json.Encode.object
                                                [ ( "source"
                                                  , Json.Encode.string
                                                        ("doc['"
                                                            ++ field
                                                            ++ "'].size() == 0 ? 0 : 1.0 / doc['"
                                                            ++ field
                                                            ++ "'].value.length()"
                                                        )
                                                  )
                                                ]
                                          )
                                        ]
                                  )
                                ]
                          )
                        ]
                  )
                , ( "rescore_query_weight", Json.Encode.float weight )
                ]
          )
        ]
    )


encodeRequestBody :
    { query : String
    , from : Int
    , size : Int
    , sort : Sort
    , types : List String
    , sortField : String
    , otherSortFields : List String
    , terms : List Terms
    , filterByBuckets : List ( String, Json.Encode.Value )
    , negatedFields : List String
    , ranking : List String -> Ranking
    , rescore : Maybe { field : String, weight : Float }
    }
    -> Json.Encode.Value
encodeRequestBody request =
    let
        -- you can not request more then 10000 results otherwise it will return 404
        size =
            if request.from + request.size > 10000 then
                10000 - request.from

            else
                request.size

        ( negativeWords, positiveWords ) =
            String.toLower request.query
                |> String.words
                |> List.partition (String.startsWith "-")
                |> Tuple.mapFirst (List.map (String.dropLeft 1))

        ranking : Ranking
        ranking =
            request.ranking positiveWords

        -- only emit `rescore` for the `Relevance` sort.
        rescoreActive : Bool
        rescoreActive =
            case ( request.sort, request.rescore ) of
                ( Relevance, Just _ ) ->
                    True

                _ ->
                    False

        sortQuery : ( String, Json.Encode.Value )
        sortQuery =
            if rescoreActive then
                ( "sort"
                , Json.Encode.list Json.Encode.object
                    [ [ ( "_score", Json.Encode.string "desc" ) ] ]
                )

            else
                toSortQuery request.sort request.sortField request.otherSortFields
    in
    Json.Encode.object
        ([ ( "from"
           , Json.Encode.int request.from
           )
         , ( "size"
           , Json.Encode.int size
           )
         , sortQuery
         , toAggregations request.terms
         , ( "query"
           , Json.Encode.object
                [ ( "bool"
                  , Json.Encode.object
                        [ ( "filter"
                          , Json.Encode.list Json.Encode.object
                                (List.append
                                    [ filterByType request.types ]
                                    (if List.isEmpty request.filterByBuckets then
                                        []

                                     else
                                        [ request.filterByBuckets ]
                                    )
                                )
                          )
                        , ( "must_not"
                          , Json.Encode.list Json.Encode.object
                                (negativeWords
                                    |> List.concatMap dashUnderscoreVariants
                                    |> List.Extra.unique
                                    |> List.concatMap
                                        (\word ->
                                            List.map
                                                (\field -> toWildcardQuery field word)
                                                request.negatedFields
                                        )
                                )
                          )
                        , ( "must", Json.Encode.list Json.Encode.object ranking.must )
                        , ( "should", Json.Encode.list Json.Encode.object ranking.should )
                        ]
                  )
                ]
           )
         ]
            ++ (case ( rescoreActive, request.rescore ) of
                    ( True, Just rescore ) ->
                        [ rescoreQuery rescore ]

                    _ ->
                        []
               )
        )


toWildcardQuery : String -> String -> List ( String, Json.Encode.Value )
toWildcardQuery field queryWord =
    [ ( "wildcard"
      , Json.Encode.object
            [ ( field
              , Json.Encode.object
                    [ ( "value", Json.Encode.string ("*" ++ queryWord ++ "*") )
                    , ( "case_insensitive", Json.Encode.bool True )
                    ]
              )
            ]
      )
    ]
