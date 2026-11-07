# Getting Started with HenshinStateSpace

Explore the models that rules reach and check properties of them.

## Overview

This guide explores the state space of a module from a start model, bounds the exploration,
checks properties and exports the result.

## Installation

Add the package dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mipalgu/swift-henshin.git", branch: "main"),
]
```

Then add the `HenshinStateSpace` product, and `Henshin` to load modules, to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Henshin", package: "swift-henshin"),
        .product(name: "HenshinStateSpace", package: "swift-henshin"),
    ]
)
```

## Exploring

Load the metamodel, the rule module and the start model into one resource set, then explore:

```swift
import ECore
import Henshin
import HenshinStateSpace

let resourceSet = ResourceSet()
try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource

let explorer = try StateSpaceExplorer(module: module, rules: ["request", "enter", "leave", "pass"])
let space = try await explorer.explore(from: model)
print(space)  // number of states and transitions, and whether it is complete
```

``StateSpaceExplorer/init(module:rules:units:options:)`` takes the names of the rules to
apply at every match (every active rule if `nil`) and the names of units to apply as atomic
steps. It throws ``StateSpaceError/unknownUnit(_:)`` for a name that the module lacks.
``StateSpaceExplorer/explore(from:)`` returns a ``StateSpace``.

## Bounding the exploration

``ExplorationOptions`` bounds the exploration and supplies parameter values:

```swift
let options = ExplorationOptions(
    maximumStates: 10_000, maximumDepth: 20, maximumObjects: 12,
    equivalence: .isomorphism,
    parameterValues: ["deposit": [["amount": 10], ["amount": 20]]])
let explorer = try StateSpaceExplorer(module: module, rules: ["deposit"], options: options)
```

``ExplorationOptions/parameterValues`` lists, for a rule or unit, every assignment to try.
``ExplorationOptions/engineOptions`` configures the engine that applies the rules, and
``ExplorationOptions/concurrency`` the number of states expanded at once.

## Reading the state space

```swift
print(space.states.count, space.transitions.count, space.isComplete)
for transition in space.outgoing(space.initialState) {
    print(transition.label, "->", transition.target)
}
print(space.deadlocks)     // states that cannot be left
print(space.openStates)    // states cut off by a bound
print(space.statistics.expandedStates, space.statistics.applications)
```

Each ``ExploredState`` has its depth, object count and parent; each ``StateTransition``
names its source, target, label, match and parameters.

## Checking properties

``ModelChecker`` takes the state space and the resource set that holds the metamodel:

```swift
let checker = ModelChecker(stateSpace: space, resourceSet: resourceSet)

let mutex = try await checker.checkInvariant(.forbidden(twoCriticalPattern))
let reachable = try await checker.checkReachable(.aql("self.processes->exists(p | p.state = 'critical')"))
let free = checker.checkDeadlockFreedom()
```

``ModelChecker/checkReachable(_:)`` and ``ModelChecker/checkInvariant(_:)`` evaluate a
``StatePredicate``; ``ModelChecker/states(satisfying:)`` lists the matching states.
A predicate is one of:

- ``StatePredicate/pattern(_:parameters:)``: holds if a rule's left-hand side, with its
  application conditions, has a match;
- ``StatePredicate/forbidden(_:parameters:)``: holds if the pattern has no match;
- ``StatePredicate/aql(_:)``: an expression of the Acceleo Query Language that evaluates to
  a Boolean, with `self` bound to the first root object;
- ``StatePredicate/custom(name:_:)``: a function of the state's model;
- ``StatePredicate/deadlock``: holds if no rule or unit applies;
- ``StatePredicate/not(_:)``, ``StatePredicate/and(_:_:)`` and ``StatePredicate/or(_:_:)``:
  combinations.

```swift
let stuckOrBusy = StatePredicate.or(.deadlock, .aql("self.processes->size() > 3"))
```

Expressions that cannot be evaluated throw ``StateSpaceError/invalidProperty(_:)``.

## Reading a check result

A ``CheckResult`` states whether the property ``CheckResult/holds``, and gives the
``CheckResult/state`` of a witness or counterexample and the shortest ``CheckResult/path``
to it. If ``CheckResult/isConclusive`` is `false`, the state space is incomplete and the
result only says that nothing was found within the bounds.

```swift
let result = try await checker.checkInvariant(.forbidden(twoCriticalPattern))
if !result.holds {
    for step in result.path { print(step) }
} else if !result.isConclusive {
    print("No counterexample within the explored bounds")
}
```

## Exporting the graph

``StateSpace/dot(name:highlighted:stateLabel:)`` writes the state space as a Graphviz DOT
graph. The initial state is drawn with a double circle, open states dashed and deadlocks as
boxes. Highlight the states of a counterexample to see where it leads:

```swift
let highlighted = Set(result.path.flatMap { [$0.source, $0.target] })
try space.dot(highlighted: highlighted).write(
    to: dotURL, atomically: true, encoding: .utf8)
```

## Next steps

<doc:UnderstandingStateSpaces> explains how states are identified, how bounds affect the
conclusions of a check, and how rules with parameters are explored.
