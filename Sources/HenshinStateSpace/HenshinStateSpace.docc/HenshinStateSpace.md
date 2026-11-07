# ``HenshinStateSpace``

Explore the models that Henshin rules reach and check properties of them.

## Overview

``StateSpaceExplorer`` applies rules at every match, and units as atomic steps, to a start
model and to every model it reaches, breadth first. Each model becomes a state of a
``StateSpace`` and each application a ``StateTransition`` that records the rule, the matched
objects and the parameter values. ``ModelChecker`` then checks reachability, invariants and
freedom from deadlocks. The approach follows GROOVE (Rensink, "The GROOVE simulator: a tool
for state space generation", AGTIVE 2003) and Henshin's state-space tools.

```swift
let explorer = try StateSpaceExplorer(module: module, rules: ["request", "enter", "leave", "pass"])
let space = try await explorer.explore(from: model)

let checker = ModelChecker(stateSpace: space, resourceSet: resourceSet)
print(try await checker.checkInvariant(.forbidden(twoCriticalPattern)))
print(try await checker.checkReachable(.aql("self.processes->exists(p | p.state = 'critical')")))
print(checker.checkDeadlockFreedom())
print(space.dot())
```

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
