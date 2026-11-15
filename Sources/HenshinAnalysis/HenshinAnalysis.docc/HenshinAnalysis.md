# ``HenshinAnalysis``

Find the conflicts and dependencies of Henshin rules by critical pair analysis.

## Overview

Two rule applications are in *conflict* if applying one disables the other, and the second
*depends* on the first if applying the first enables it. ``CriticalPairAnalyser`` decides
this statically, from the rules alone, by examining how the graphs of two rules can overlap,
as described by Ehrig, Ehrig, Prange and Taentzer in
*[Fundamentals of Algebraic Graph Transformation](https://doi.org/10.1007/3-540-31188-2)*
(Springer, 2006). Results are available at the granularity levels of Lambers, Born, Kosiol,
Strüber and Taentzer
([JLAMP 2019](https://www.sciencedirect.com/science/article/pii/S235222081830004X)), from
whether two rules interact at all to every critical pair.

```swift
let analyser = CriticalPairAnalyser()
let conflicts = analyser.conflicts(first: deleteRule, second: useRule, granularity: .criticalPairs)
print(conflicts)

let table = analyser.analyse(module.rules, direction: .dependency)
print(table)
```

## Related Documentation

### Command Line and Tutorials

- [swift-henshin](https://mipalgu.github.io/swift-modelling/documentation/swift_henshin/index.html) - the command-line tool of swift-modelling
- [Analysing and Exploring Graph Transformations](https://mipalgu.github.io/swift-modelling/tutorials/swiftmodelling/henshin-02-analysis-exploration/index.html)
- [All tutorials](https://mipalgu.github.io/swift-modelling/tutorials/tutorials/index.html)

### Henshin Modules

- [Henshin](https://mipalgu.github.io/swift-henshin/documentation/henshin/) - applying rules and units to Ecore models
- [HenshinStateSpace](https://mipalgu.github.io/swift-henshin/documentation/henshinstatespace/) - state-space exploration and model checking

### Related Packages

- [swift-ecore](https://mipalgu.github.io/swift-ecore/documentation/ecore/) - the Ecore metamodels and models that rules transform
- [swift-aql](https://mipalgu.github.io/swift-aql/documentation/aql/) - evaluates the attribute expressions of rules
- [swift-atl](https://mipalgu.github.io/swift-atl/) - ATL model transformations
- [swift-modelling](https://mipalgu.github.io/swift-modelling/) - command-line tools and tutorials for the whole toolkit

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:UnderstandingCriticalPairAnalysis>
- ``CriticalPairAnalyser``
- ``AnalysisOptions``

### Analysing rules

- ``AnalysisGranularity``
- ``InteractionDirection``
- ``InteractionKind``

### Results

- ``RulePairInteraction``
- ``InteractionTable``
- ``InteractionAtom``
- ``InteractionReason``
- ``CriticalPair``
- ``CriticalElement``

### Overlaps

- ``OverlapSpan``
- ``ElementOverlap``
- ``RuleElement``
- ``RuleGraphRole``
- ``OverlapGraph``
- ``OverlapNode``
- ``OverlapEdge``
