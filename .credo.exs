%{
  configs: [
    %{
      name: "default",
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.RedundantWithClauseResult, false},
        {Credo.Check.Readability.PredicateFunctionNames, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.FilterFilter, false},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Readability.LargeNumbers, false}
      ]
    }
  ]
}
