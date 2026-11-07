# Swift Henshin - Henshin Graph Transformation Library

[![CI](https://github.com/mipalgu/swift-henshin/actions/workflows/ci.yml/badge.svg)](https://github.com/mipalgu/swift-henshin/actions/workflows/ci.yml)
[![Documentation](https://github.com/mipalgu/swift-henshin/actions/workflows/documentation.yml/badge.svg)](https://github.com/mipalgu/swift-henshin/actions/workflows/documentation.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmipalgu%2Fswift-henshin%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mipalgu/swift-henshin)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmipalgu%2Fswift-henshin%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mipalgu/swift-henshin)

A pure Swift implementation of [Eclipse Henshin](https://eclipse.dev/henshin/) graph
transformation for [swift-ecore](https://github.com/mipalgu/swift-ecore) models, with
critical pair analysis and state-space exploration.

## Features

- **Pure Swift**: no Java or EMF runtime, with strict concurrency checking
- **Henshin rules and units**: reads `.henshin` documents and applies rules with application
  conditions, multi-rules, and sequential, conditional, priority, independent, loop and
  iterated units
- **Henshin Text**: reads and writes Henshin's textual syntax
- **Validation**: Henshin's well-definedness checks and clean-up checks before rules run
- **Critical pair analysis**: conflicts and dependencies of rules at four levels of
  granularity
- **State spaces**: exploration up to isomorphism, with reachability, invariant and
  deadlock checks that come with counterexample paths

## Requirements

- Swift 6.0 or later
- macOS 15.0 or later, Linux or Windows

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mipalgu/swift-henshin.git", branch: "main")
]
```

And add the products you need to your target's dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Henshin", package: "swift-henshin"),
        .product(name: "HenshinAnalysis", package: "swift-henshin"),
        .product(name: "HenshinStateSpace", package: "swift-henshin"),
    ]
)
```

- `Henshin`: the graph transformation engine, validation and Henshin Text
- `HenshinAnalysis`: critical pair analysis (conflicts and dependencies)
- `HenshinStateSpace`: state-space exploration and model checking

## Building

```bash
# Build the library
swift build

# Run tests
swift test
```

Opt-in tests that compare against reference material read the environment variables
`HENSHIN_REFERENCE_DIR`, `HENSHIN_TEXT_REFERENCE_DIR`, `HENSHIN_REFERENCE_EXAMPLES` and
`HENSHIN_BENCHMARK`.

## Usage

Load a rule module with its metamodel, apply a unit to a model, and analyse the rules:

```swift
import ECore
import Henshin
import HenshinAnalysis

let resourceSet = ResourceSet()
try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource

let result = try await HenshinEngine().apply(
    unitNamed: "createAccount", of: module, to: model,
    parameters: ["client": "Alice", "accountId": 4])
print(result.succeeded, result.appliedRules.map(\.ruleName))

let conflicts = CriticalPairAnalyser().analyse(module.rules, direction: .conflict)
print(conflicts)
```

## Documentation

The DocC documentation covers each module:

- [Henshin](https://mipalgu.github.io/swift-henshin/documentation/henshin/):
  [Getting Started](https://mipalgu.github.io/swift-henshin/documentation/henshin/gettingstarted),
  [Supported Henshin Features](https://mipalgu.github.io/swift-henshin/documentation/henshin/supportedfeatures)
  and [Henshin Text syntax](https://mipalgu.github.io/swift-henshin/documentation/henshin/henshintextsyntax)
- [HenshinAnalysis](https://mipalgu.github.io/swift-henshin/documentation/henshinanalysis/):
  [Getting Started](https://mipalgu.github.io/swift-henshin/documentation/henshinanalysis/gettingstarted)
  and [Understanding Critical Pair Analysis](https://mipalgu.github.io/swift-henshin/documentation/henshinanalysis/understandingcriticalpairanalysis)
- [HenshinStateSpace](https://mipalgu.github.io/swift-henshin/documentation/henshinstatespace/):
  [Getting Started](https://mipalgu.github.io/swift-henshin/documentation/henshinstatespace/gettingstarted)
  and [Understanding State Spaces](https://mipalgu.github.io/swift-henshin/documentation/henshinstatespace/understandingstatespaces)

## Licence

See the details in the LICENCE file.

The bundled Henshin metamodel `Sources/Henshin/Resources/henshin.ecore` is an unchanged
copy from Eclipse Henshin, published under the Eclipse Public License v1.0; see
[NOTICE](NOTICE).

## References

- [Eclipse Henshin](https://eclipse.dev/henshin/) - The reference graph transformation tool for EMF
- Born, Lambers, Strüber and Taentzer, "Granularity of conflicts and dependencies in graph
  transformation systems" (FASE 2017) - The granularity levels of the analysis
- Ehrig, Ehrig, Prange and Taentzer, *Fundamentals of Algebraic Graph Transformation*
  (Springer, 2006) - The theory of graph transformation and critical pairs
- [GROOVE](https://groove.cs.utwente.nl/) - Graph-based state-space exploration and model checking
- [Eclipse Modeling Framework (EMF)](https://eclipse.dev/emf/) - The metamodelling foundation
- [swift-ecore](https://github.com/mipalgu/swift-ecore) - The Swift Ecore metamodelling framework
- [swift-aql](https://github.com/mipalgu/swift-aql) - The Swift Acceleo Query Language implementation
