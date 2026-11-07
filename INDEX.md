# Swift Henshin

The [swift-henshin](https://github.com/mipalgu/swift-henshin) package
provides a pure Swift implementation of
[Eclipse Henshin](https://eclipse.dev/henshin/) graph transformation
for Ecore models, with critical pair analysis and state-space
exploration.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mipalgu/swift-henshin.git", branch: "main"),
]
```

## Requirements

- Swift 6.0 or later
- macOS 15.0+, Linux, or Windows

## References

- [Eclipse Henshin](https://eclipse.dev/henshin/)
- [Eclipse Modeling Framework (EMF)](https://eclipse.dev/emf/)
- [GROOVE](https://groove.cs.utwente.nl/)
- Ehrig, Ehrig, Prange and Taentzer, *Fundamentals of Algebraic Graph Transformation* (2006)

## Related Packages

- [swift-ecore](https://github.com/mipalgu/swift-ecore) - ECore metamodelling
- [swift-aql](https://github.com/mipalgu/swift-aql) - AQL model queries
- [swift-atl](https://github.com/mipalgu/swift-atl) - ATL model transformations
- [swift-mtl](https://github.com/mipalgu/swift-mtl) - MTL code generation
- [swift-modelling](https://github.com/mipalgu/swift-modelling) - Unified MDE toolkit

## Documentation

The package provides the Henshin graph transformation engine, critical
pair analysis and state-space exploration.
For Henshin, see
[Getting Started](documentation/henshin/gettingstarted) and
[Supported Henshin Features](documentation/henshin/supportedfeatures).
For HenshinAnalysis, see
[Getting Started](documentation/henshinanalysis/gettingstarted) and
[Understanding Critical Pair Analysis](documentation/henshinanalysis/understandingcriticalpairanalysis).
For HenshinStateSpace, see
[Getting Started](documentation/henshinstatespace/gettingstarted) and
[Understanding State Spaces](documentation/henshinstatespace/understandingstatespaces).
