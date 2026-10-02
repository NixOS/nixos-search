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
        (String.trim query)
        from
        size
        sort
        [ "package" ]
        "package_attr_name"
        [ "package_pversion" ]
        terms
        filterByBuckets
        [ "package_attr_name" ]
        [ ( "package_attr_name", 9.0 )
        , ( "package_programs", 8.0 )
        , ( "package_mainProgram", 8.0 )
        , ( "package_pname", 6.0 )
        , ( "package_description", 1.3 )
        , ( "package_longDescription", 1.0 )
        , ( "flake_name", 0.5 )
        ]
        [ "package_attr_name", "package_pname", "package_programs", "package_mainProgram" ]
        [ "package_description^3", "package_longDescription^1" ]
        Nothing
        [ { field = "package_repology_repos", pivot = 20.0 }
        , { field = "package_dep_count", pivot = 1000.0 }
        ]
        (Just "package_attr_name")


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
        (String.trim query)
        from
        size
        sort
        types
        "option_name"
        []
        []
        []
        [ "option_name", "option_name_query" ]
        [ ( "option_name", 6.0 )
        , ( "option_name_query", 6.0 )
        , ( "option_description", 1.0 )
        , ( "flake_name", 0.5 )
        , ( "service_package", 3.0 )
        , ( "service_packages", 3.0 )
        ]
        [ "option_name", "service_package", "service_packages" ]
        [ "option_description^3" ]
        (Just "option_name.attr_path_reverse")
        []
        Nothing


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


{-| Scales the field weights of the fuzzy clause down to a fallback.
-}
fuzzyFallbackWeight : Float
fuzzyFallbackWeight =
    0.05


searchFields :
    List String
    -> List String
    -> List ( String, Float )
    -> List String
    -> List (List ( String, Json.Encode.Value ))
searchFields positiveWords mainFields fields fuzzyFieldNames =
    let
        allFields : List String
        allFields =
            fields
                |> List.concatMap
                    (\( field, score ) ->
                        [ field ++ "^" ++ String.fromFloat score
                        , field ++ ".*^" ++ String.fromFloat (score * 0.6)
                        ]
                    )

        queryWordsWildCard : List String
        queryWordsWildCard =
            positiveWords
                |> List.concatMap dashUnderscoreVariants
                |> List.Extra.unique

        multiMatch : List ( String, Json.Encode.Value )
        multiMatch =
            [ ( "multi_match"
              , Json.Encode.object
                    [ ( "type", Json.Encode.string "cross_fields" )
                    , ( "query", Json.Encode.string (String.join " " positiveWords) )
                    , ( "analyzer", Json.Encode.string "whitespace" )
                    , ( "auto_generate_synonyms_phrase_query", Json.Encode.bool False )
                    , ( "operator", Json.Encode.string "and" )
                    , ( "_name", Json.Encode.string <| "multi_match_" ++ String.join "_" positiveWords )
                    , ( "fields", Json.Encode.list Json.Encode.string allFields )
                    ]
              )
            ]

        fuzzyFields : List String
        fuzzyFields =
            fields
                |> List.filter (\( field, _ ) -> List.member field fuzzyFieldNames)
                |> List.map
                    (\( field, score ) ->
                        field ++ "^" ++ String.fromFloat (score * fuzzyFallbackWeight)
                    )

        fuzzyMatch : List (List ( String, Json.Encode.Value ))
        fuzzyMatch =
            if List.isEmpty fuzzyFields then
                []

            else
                [ [ ( "multi_match"
                    , Json.Encode.object
                        [ ( "type", Json.Encode.string "best_fields" )
                        , ( "query", Json.Encode.string (String.join " " positiveWords) )
                        , ( "fuzziness", Json.Encode.string "1" )
                        , ( "prefix_length", Json.Encode.int 1 )
                        , ( "operator", Json.Encode.string "and" )
                        , ( "_name", Json.Encode.string <| "fuzzy_" ++ String.join "_" positiveWords )
                        , ( "fields", Json.Encode.list Json.Encode.string fuzzyFields )
                        ]
                    )
                  ]
                ]
    in
    multiMatch
        :: fuzzyMatch
        ++ List.concatMap (\mf -> List.map (toWildcardQuery mf) queryWordsWildCard) mainFields


shouldClauses :
    String
    -> List String
    -> List String
    -> List (List ( String, Json.Encode.Value ))
shouldClauses primaryField positiveWords phraseFields =
    if List.isEmpty positiveWords then
        []

    else
        let
            -- `primaryField` is a keyword, so a multi-word query only reaches an
            -- attribute name once the words are glued back together. Package names
            -- separate words with `-` or `_` as often as they concatenate, and no
            -- analysed field splits those apart, so try all three spellings.
            joinedVariants : List String
            joinedVariants =
                [ String.concat positiveWords
                , String.join "-" positiveWords
                , String.join "_" positiveWords
                ]
                    |> List.Extra.unique

            termClauses : List (List ( String, Json.Encode.Value ))
            termClauses =
                joinedVariants
                    |> List.map
                        (\joined ->
                            [ ( "term"
                              , Json.Encode.object
                                    [ ( primaryField
                                      , Json.Encode.object
                                            [ ( "value", Json.Encode.string joined )
                                            , ( "boost", Json.Encode.float 100.0 )
                                            ]
                                      )
                                    ]
                              )
                            ]
                        )

            prefixClauses : List (List ( String, Json.Encode.Value ))
            prefixClauses =
                joinedVariants
                    |> List.map
                        (\joined ->
                            [ ( "prefix"
                              , Json.Encode.object
                                    [ ( primaryField
                                      , Json.Encode.object
                                            [ ( "value", Json.Encode.string joined )
                                            , ( "boost", Json.Encode.float 20.0 )
                                            , ( "case_insensitive", Json.Encode.bool True )
                                            ]
                                      )
                                    ]
                              )
                            ]
                        )

            phraseClause : List (List ( String, Json.Encode.Value ))
            phraseClause =
                if List.length positiveWords > 1 then
                    [ [ ( "constant_score"
                        , Json.Encode.object
                            [ ( "filter"
                              , Json.Encode.object
                                    [ ( "multi_match"
                                      , Json.Encode.object
                                            [ ( "type", Json.Encode.string "phrase" )
                                            , ( "query", Json.Encode.string (String.join " " positiveWords) )
                                            , ( "fields", Json.Encode.list Json.Encode.string phraseFields )
                                            ]
                                      )
                                    ]
                              )
                            , ( "boost", Json.Encode.float 80.0 )
                            ]
                        )
                      ]
                    ]

                else
                    []
        in
        termClauses ++ prefixClauses ++ phraseClause


moduleEntryPoint : String -> List String -> List (List ( String, Json.Encode.Value ))
moduleEntryPoint field positiveWords =
    let
        path : String
        path =
            String.join "." positiveWords
    in
    if String.isEmpty path then
        []

    else
        [ leafTerm field (path ++ ".enable") 100.0 "module_entry_point"
        , leafTerm field "enable" 10.0 "module_enable_leaf"
        ]


leafTerm : String -> String -> Float -> String -> List ( String, Json.Encode.Value )
leafTerm field value boost name =
    [ ( "term"
      , Json.Encode.object
            [ ( field
              , Json.Encode.object
                    [ ( "value", Json.Encode.string value )
                    , ( "boost", Json.Encode.float boost )
                    , ( "_name", Json.Encode.string name )
                    ]
              )
            ]
      )
    ]


type alias PopularitySignal =
    { field : String, pivot : Float }


popularityClauses : List PopularitySignal -> List (List ( String, Json.Encode.Value ))
popularityClauses signals =
    List.map
        (\{ field, pivot } ->
            [ ( "rank_feature"
              , Json.Encode.object
                    [ ( "field", Json.Encode.string field )
                    , ( "boost", Json.Encode.float 5.0 )
                    , ( "_name", Json.Encode.string ("popularity_" ++ field) )
                    , ( "saturation"
                      , Json.Encode.object
                            [ ( "pivot", Json.Encode.float pivot ) ]
                      )
                    ]
              )
            ]
        )
        signals


rescoreQuery : String -> ( String, Json.Encode.Value )
rescoreQuery field =
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
                                                  , Json.Encode.string ("1.0 / doc['" ++ field ++ "'].value.length()")
                                                  )
                                                ]
                                          )
                                        ]
                                  )
                                ]
                          )
                        ]
                  )
                , ( "rescore_query_weight", Json.Encode.float 20.0 )
                ]
          )
        ]
    )


encodeRequestBody :
    String
    -> Int
    -> Int
    -> Sort
    -> List String
    -> String
    -> List String
    -> List Terms
    -> List ( String, Json.Encode.Value )
    -> List String
    -> List ( String, Float )
    -> List String
    -> List String
    -> Maybe String
    -> List PopularitySignal
    -> Maybe String
    -> Json.Encode.Value
encodeRequestBody query from sizeRaw sort types sortField otherSortFields terms filterByBuckets mainFields fields fuzzyFieldNames phraseFields entryPointField popularitySignals rescoreField =
    let
        -- you can not request more then 10000 results otherwise it will return 404
        size =
            if from + sizeRaw > 10000 then
                10000 - from

            else
                sizeRaw

        ( negativeWords, positiveWords ) =
            String.toLower query
                |> String.words
                |> List.partition (String.startsWith "-")
                |> Tuple.mapFirst (List.map (String.dropLeft 1))

        primaryField : String
        primaryField =
            List.head mainFields |> Maybe.withDefault ""

        -- only emit `rescore` for the `Relevance` sort.
        rescoreActive : Bool
        rescoreActive =
            case ( sort, rescoreField ) of
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
                toSortQuery sort sortField otherSortFields

        entryPointClauses : List (List ( String, Json.Encode.Value ))
        entryPointClauses =
            case entryPointField of
                Just field ->
                    moduleEntryPoint field positiveWords

                Nothing ->
                    []
    in
    Json.Encode.object
        ([ ( "from"
           , Json.Encode.int from
           )
         , ( "size"
           , Json.Encode.int size
           )
         , sortQuery
         , toAggregations terms
         , ( "query"
           , Json.Encode.object
                [ ( "bool"
                  , Json.Encode.object
                        [ ( "filter"
                          , Json.Encode.list Json.Encode.object
                                (List.append
                                    [ filterByType types ]
                                    (if List.isEmpty filterByBuckets then
                                        []

                                     else
                                        [ filterByBuckets ]
                                    )
                                )
                          )
                        , ( "must_not"
                          , Json.Encode.list Json.Encode.object
                                (negativeWords
                                    |> List.concatMap dashUnderscoreVariants
                                    |> List.Extra.unique
                                    |> List.concatMap (\w -> List.map (\mf -> toWildcardQuery mf w) mainFields)
                                )
                          )
                        , ( "must"
                          , Json.Encode.list Json.Encode.object
                                [ [ ( "dis_max"
                                    , Json.Encode.object
                                        [ ( "tie_breaker", Json.Encode.float 0.7 )
                                        , ( "queries"
                                          , Json.Encode.list Json.Encode.object
                                                (searchFields positiveWords mainFields fields fuzzyFieldNames)
                                          )
                                        ]
                                    )
                                  ]
                                ]
                          )
                        , ( "should"
                          , Json.Encode.list Json.Encode.object
                                (shouldClauses primaryField positiveWords phraseFields
                                    ++ entryPointClauses
                                    ++ popularityClauses popularitySignals
                                )
                          )
                        ]
                  )
                ]
           )
         ]
            ++ (case ( rescoreActive, rescoreField ) of
                    ( True, Just field ) ->
                        [ rescoreQuery field ]

                    _ ->
                        []
               )
        )


dashUnderscoreVariants : String -> List String
dashUnderscoreVariants word =
    [ String.replace "_" "-" word
    , String.replace "-" "_" word
    , word
    ]


toWildcardQuery : String -> String -> List ( String, Json.Encode.Value )
toWildcardQuery mainField queryWord =
    [ ( "wildcard"
      , Json.Encode.object
            [ ( mainField
              , Json.Encode.object
                    [ ( "value", Json.Encode.string ("*" ++ queryWord ++ "*") )
                    , ( "case_insensitive", Json.Encode.bool True )
                    ]
              )
            ]
      )
    ]
