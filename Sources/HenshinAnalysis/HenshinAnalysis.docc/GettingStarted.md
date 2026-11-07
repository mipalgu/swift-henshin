# Getting Started with HenshinAnalysis

Find which Henshin rules conflict with, or depend on, one another.

## Overview

This guide loads a rule module, analyses pairs of its rules for conflicts and dependencies,
reads the results and tunes the analysis.

## Installation

Add the package dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mipalgu/swift-henshin.git", branch: "main"),
]
```

Then add the `HenshinAnalysis` product, and `Henshin` to load modules, to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Henshin", package: "swift-henshin"),
        .product(name: "HenshinAnalysis", package: "swift-henshin"),
    ]
)
```

## Loading the rules

The analysis works on the rules of a `HenshinModule`, which the `Henshin` module
loads together with its metamodel:

```swift
import ECore
import Henshin
import HenshinAnalysis

let resourceSet = ResourceSet()
try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
guard let firstRule = module.unit(named: "deleteNext")?.rule,
      let secondRule = module.unit(named: "useNext")?.rule
else { return }
```

## Analysing a pair of rules

``CriticalPairAnalyser/conflicts(first:second:granularity:)`` asks whether applying the first
rule may disable the second; ``CriticalPairAnalyser/dependencies(first:second:granularity:)``
asks whether it may enable it. Both return a ``RulePairInteraction``.

```swift
let analyser = CriticalPairAnalyser()
let result = analyser.conflicts(first: firstRule, second: secondRule, granularity: .criticalPairs)

if result.interacts {
    print(result.kinds)  // for example [deleteUse]
}
```

Without a granularity the result holds the minimal reasons.

## Analysing a set of rules

``CriticalPairAnalyser/analyse(_:direction:granularity:)`` analyses every ordered pair of a
list of rules, each rule paired with itself too, and returns an ``InteractionTable``:

```swift
let table = analyser.analyse(module.rules, direction: .conflict, granularity: .atoms)
print(table)

for interaction in table.interactingPairs {
    print(interaction.firstRule, "->", interaction.secondRule, interaction.kinds)
}

if let one = table.interaction(first: "deleteNext", second: "useNext") {
    print(one.interacts)
}
```

## Reading a result

A ``RulePairInteraction`` names the two rules and the ``InteractionDirection`` and
``AnalysisGranularity`` of the analysis. Its details depend on the granularity:

- ``RulePairInteraction/interacts`` and ``RulePairInteraction/kinds``: always;
- ``RulePairInteraction/atoms``: from ``AnalysisGranularity/atoms`` on;
- ``RulePairInteraction/minimalReasons``: from ``AnalysisGranularity/minimalReasons`` on;
- ``RulePairInteraction/criticalPairs``: at ``AnalysisGranularity/criticalPairs``.

```swift
for reason in result.minimalReasons {
    print(reason.kinds, reason.span.nodes.count, reason.span.edges.count)
}
for pair in result.criticalPairs {
    print(pair.isEssential, pair.graph.nodes.count, pair.graph.edges.count)
}
for note in result.notes { print("approximated:", note) }
```

Each ``CriticalPair`` carries its ``OverlapGraph``, the matches of both rules into it and
its ``CriticalElement`` values. Print a result or table for a readable summary.

## Tuning the analysis

``AnalysisOptions`` is passed to the analyser:

```swift
let options = AnalysisOptions(
    respectsMultiplicities: true, checkDangling: false,
    maximumCriticalPairs: 100, essentialOnly: true)
let analyser = CriticalPairAnalyser(options: options)
```

- ``AnalysisOptions/respectsMultiplicities``: whether overlap graphs obey the multiplicities
  of the metamodel (default `true`).
- ``AnalysisOptions/checksNegativeConditions``: whether overlaps that certainly match a
  negative application condition are left out (default `true`).
- ``AnalysisOptions/includesPositiveConditions``: whether positive application conditions of
  the second rule count as elements it uses (default `true`).
- ``AnalysisOptions/checkDangling``: overrides the dangling condition of every rule.
- ``AnalysisOptions/maximumCriticalPairs``: the largest number of critical pairs reported
  for a pair of rules (default 1000).
- ``AnalysisOptions/essentialOnly``: report only essential critical pairs.
- ``AnalysisOptions/searchBudget``: the largest number of overlaps examined for a pair of
  rules.

## Next steps

<doc:UnderstandingCriticalPairAnalysis> explains the kinds of interaction, the granularity
levels and what the analysis approximates.
