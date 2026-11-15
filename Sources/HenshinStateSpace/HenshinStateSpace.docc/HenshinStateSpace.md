# ``HenshinStateSpace``

Explore the models that Henshin rules reach and check properties of them.

## Overview

``StateSpaceExplorer`` applies rules at every match, and units as atomic steps, to a start
model and to every model it reaches, breadth first. Each model becomes a state of a
``StateSpace`` and each application a ``StateTransition`` that records the rule, the matched
objects and the parameter values. ``ModelChecker`` then checks reachability, invariants and
freedom from deadlocks. The approach follows GROOVE (Rensink, "[The GROOVE simulator: a tool
for state space generation](https://doi.org/10.1007/978-3-540-25959-6_40)", AGTIVE 2003) and
Henshin's state-space tools.

```swift
let explorer = try StateSpaceExplorer(module: module, rules: ["request", "enter", "leave", "pass"])
let space = try await explorer.explore(from: model)

let checker = ModelChecker(stateSpace: space, resourceSet: resourceSet)
print(try await checker.checkInvariant(.forbidden(twoCriticalPattern)))
print(try await checker.checkReachable(.aql("self.processes->exists(p | p.state = 'critical')")))
print(checker.checkDeadlockFreedom())
print(space.dot())
```

## Related Documentation

### Command Line and Tutorials

- [swift-henshin](https://mipalgu.github.io/swift-modelling/documentation/swift_henshin/index.html) - the command-line tool of swift-modelling
- [Analysing and Exploring Graph Transformations](https://mipalgu.github.io/swift-modelling/tutorials/swiftmodelling/henshin-02-analysis-exploration/index.html)
- [All tutorials](https://mipalgu.github.io/swift-modelling/tutorials/tutorials/index.html)

### Henshin Modules

- [Henshin](https://mipalgu.github.io/swift-henshin/documentation/henshin/) - applying rules and units to Ecore models
- [HenshinAnalysis](https://mipalgu.github.io/swift-henshin/documentation/henshinanalysis/) - conflicts and dependencies of rules by critical pair analysis

### Related Packages

- [swift-ecore](https://mipalgu.github.io/swift-ecore/documentation/ecore/) - the Ecore metamodels and models that rules transform
- [swift-aql](https://mipalgu.github.io/swift-aql/documentation/aql/) - evaluates the attribute expressions of rules
- [swift-atl](https://mipalgu.github.io/swift-atl/) - ATL model transformations
- [swift-modelling](https://mipalgu.github.io/swift-modelling/) - command-line tools and tutorials for the whole toolkit

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:UnderstandingStateSpaces>

### Exploring

- ``StateSpaceExplorer``
- ``ExplorationOptions``
- ``StateEquivalence``
- ``StateSpaceError``

### State spaces

- ``StateSpace``
- ``ExploredState``
- ``StateTransition``
- ``ExplorationStatistics``

### Checking

- ``ModelChecker``
- ``StatePredicate``
- ``CheckResult``
