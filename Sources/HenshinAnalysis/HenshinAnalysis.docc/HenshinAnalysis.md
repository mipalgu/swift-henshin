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
