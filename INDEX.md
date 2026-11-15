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
- Ehrig, Ehrig, Prange and Taentzer, [*Fundamentals of Algebraic Graph Transformation*](https://doi.org/10.1007/3-540-31188-2) (2006)

## Related Packages

- [swift-ecore](https://mipalgu.github.io/swift-ecore/) - EMF/Ecore metamodelling, OCL, generator models and multi-level modelling ([GitHub](https://github.com/mipalgu/swift-ecore))
- [swift-aql](https://mipalgu.github.io/swift-aql/) - AQL model queries ([GitHub](https://github.com/mipalgu/swift-aql))
- [swift-mtl](https://mipalgu.github.io/swift-mtl/) - MTL model-to-text generation ([GitHub](https://github.com/mipalgu/swift-mtl))
- [swift-atl](https://mipalgu.github.io/swift-atl/) - ATL model transformations ([GitHub](https://github.com/mipalgu/swift-atl))
- [swift-epsilon](https://mipalgu.github.io/swift-epsilon/) - Epsilon model management languages (EOL, EVL, ETL and EGL) ([GitHub](https://github.com/mipalgu/swift-epsilon))
- [swift-xtend](https://mipalgu.github.io/swift-xtend/) - Xtend generators and transformations ([GitHub](https://github.com/mipalgu/swift-xtend))
- [swift-modelling](https://mipalgu.github.io/swift-modelling/) - Command-line tools, code generators and tutorials for the whole toolkit ([GitHub](https://github.com/mipalgu/swift-modelling))

## Documentation

The package provides the Henshin graph transformation engine, critical
pair analysis and state-space exploration.
For [Henshin](documentation/henshin/), see
[Getting Started](documentation/henshin/gettingstarted) and
[Supported Henshin Features](documentation/henshin/supportedfeatures).
For [HenshinAnalysis](documentation/henshinanalysis/), see
[Getting Started](documentation/henshinanalysis/gettingstarted) and
[Understanding Critical Pair Analysis](documentation/henshinanalysis/understandingcriticalpairanalysis).
For [HenshinStateSpace](documentation/henshinstatespace/), see
[Getting Started](documentation/henshinstatespace/gettingstarted) and
[Understanding State Spaces](documentation/henshinstatespace/understandingstatespaces).

The `swift-henshin` command-line tool of [swift-modelling](https://mipalgu.github.io/swift-modelling/) is described in
[swift-henshin](https://mipalgu.github.io/swift-modelling/documentation/swift_henshin/index.html),
and the Henshin tutorials [Graph Transformation Rules with Henshin](https://mipalgu.github.io/swift-modelling/tutorials/swiftmodelling/henshin-01-graph-rules/index.html) and
[Analysing and Exploring Graph Transformations](https://mipalgu.github.io/swift-modelling/tutorials/swiftmodelling/henshin-02-analysis-exploration/index.html)
introduce it step by step (see all [tutorials](https://mipalgu.github.io/swift-modelling/tutorials/tutorials/index.html)).
