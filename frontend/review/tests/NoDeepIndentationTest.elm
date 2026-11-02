module NoDeepIndentationTest exposing (all)

import NoDeepIndentation exposing (rule)
import Review.Test
import Test exposing (Test)


all : Test
all =
    Test.describe "NoDeepIndentation"
        [ Test.test "does not report a function at the maximum indentation" <|
            \_ ->
                """module A exposing (a)
a =
    [ 1
    ]
"""
                    |> Review.Test.run (rule 4)
                    |> Review.Test.expectNoErrors
        , Test.test "reports the first line over the maximum indentation, once per function" <|
            \_ ->
                """module A exposing (a)
a =
    [ [ 1
      ]
    , [ 2
      ]
    ]
"""
                    |> Review.Test.run (rule 4)
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = "`a` is indented more than 4 spaces"
                            , details =
                                [ "When code is deeply indented, a small change to the logic can change the indentation of many lines, and thus give a large diff."
                                , "Give the inner values a name in a `let` or in a top-level function, or use a pipeline. See \"Code style\" in `README.md`."
                                ]
                            , under = "]"
                            }
                            |> Review.Test.atExactly { start = { row = 4, column = 7 }, end = { row = 4, column = 8 } }
                        ]
        , Test.test "does not examine multi-line strings and comments" <|
            \_ ->
                """module A exposing (a)
a =
    {- a
            comment
    -}
    \"\"\"a
            string
    \"\"\"
"""
                    |> Review.Test.run (rule 4)
                    |> Review.Test.expectNoErrors
        , Test.test "does not examine documentation" <|
            \_ ->
                """module A exposing (a)
{-| a

            example

-}
a =
    1
"""
                    |> Review.Test.run (rule 4)
                    |> Review.Test.expectNoErrors
        ]
