module NoDeepIndentation exposing (rule)

{-|

@docs rule

-}

import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range exposing (Range)
import Review.Rule as Rule exposing (Rule)
import Set exposing (Set)


{-| Reports a top-level function that has a line with more indentation than
the given number of spaces.

When code is deeply indented, a small change to the logic can change the
indentation of many lines, and thus give a large diff. The lines in multi-line
strings and in multi-line comments are not examined.

    config =
        [ NoDeepIndentation.rule 32
        ]

-}
rule : Int -> Rule
rule maxIndentation =
    Rule.newModuleRuleSchemaUsingContextCreator "NoDeepIndentation" initialContext
        |> Rule.withDeclarationEnterVisitor declarationVisitor
        |> Rule.withExpressionEnterVisitor expressionVisitor
        |> Rule.withCommentsVisitor commentsVisitor
        |> Rule.withFinalModuleEvaluation (finalEvaluation maxIndentation)
        |> Rule.fromModuleRuleSchema


type alias Context =
    { extractSourceCode : Range -> String
    , functions : List ( String, Range )
    , skippedRows : Set Int
    }


initialContext : Rule.ContextCreator () Context
initialContext =
    Rule.initContextCreator
        (\extractSourceCode () ->
            { extractSourceCode = extractSourceCode
            , functions = []
            , skippedRows = Set.empty
            }
        )
        |> Rule.withSourceCodeExtractor


declarationVisitor : Node Declaration -> Context -> ( List (Rule.Error {}), Context )
declarationVisitor node context =
    case Node.value node of
        Declaration.FunctionDeclaration function ->
            let
                implementation : Node Expression.FunctionImplementation
                implementation =
                    function.declaration
            in
            ( []
            , { context
                | functions =
                    ( Node.value (Node.value implementation).name, Node.range implementation )
                        :: context.functions
              }
            )

        _ ->
            ( [], context )


expressionVisitor : Node Expression -> Context -> ( List (Rule.Error {}), Context )
expressionVisitor node context =
    case Node.value node of
        Expression.Literal _ ->
            ( [], skipRows (Node.range node) context )

        _ ->
            ( [], context )


commentsVisitor : List (Node String) -> Context -> ( List (Rule.Error {}), Context )
commentsVisitor comments context =
    ( []
    , List.foldl (Node.range >> skipRows) context comments
    )


{-| Skips the rows of a multi-line string or comment, apart from the first row,
which starts with code or with the comment.
-}
skipRows : Range -> Context -> Context
skipRows range context =
    { context
        | skippedRows =
            List.range (range.start.row + 1) range.end.row
                |> Set.fromList
                |> Set.union context.skippedRows
    }


finalEvaluation : Int -> Context -> List (Rule.Error {})
finalEvaluation maxIndentation context =
    List.filterMap
        (\( name, range ) ->
            context.extractSourceCode range
                |> String.lines
                |> List.indexedMap (\index line -> ( range.start.row + index, line ))
                |> List.filter (\( row, _ ) -> not (Set.member row context.skippedRows))
                |> List.filter (\( _, line ) -> indentation line > maxIndentation)
                |> List.head
                |> Maybe.map (deepLineError maxIndentation name)
        )
        context.functions


indentation : String -> Int
indentation line =
    if String.isEmpty (String.trim line) then
        0

    else
        String.length line - String.length (String.trimLeft line)


deepLineError : Int -> String -> ( Int, String ) -> Rule.Error {}
deepLineError maxIndentation name ( row, line ) =
    Rule.error
        { message = "`" ++ name ++ "` is indented more than " ++ String.fromInt maxIndentation ++ " spaces"
        , details =
            [ "When code is deeply indented, a small change to the logic can change the indentation of many lines, and thus give a large diff."
            , "Give the inner values a name in a `let` or in a top-level function, or use a pipeline. See \"Code style\" in `README.md`."
            ]
        }
        { start = { row = row, column = indentation line + 1 }
        , end = { row = row, column = String.length line + 1 }
        }
