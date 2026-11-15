# ``Henshin``

Apply Henshin graph transformation rules to Ecore models.

## Overview

Henshin is an in-place model transformation language for Ecore models, grounded in
algebraic graph transformation. A rule describes a pattern to find (its left-hand side)
and what the pattern becomes (its right-hand side); units combine rules into sequences,
choices, conditionals and loops.

This module reads Henshin documents (`.henshin` files) through the XMI loader of `ECore`
as instances of the bundled Henshin metamodel, and applies their rules and units to the
models of `ECore` resources with the semantics of Henshin's interpreter. Attribute
expressions, which Henshin writes in JavaScript, are translated into the Acceleo Query
Language and evaluated with `AQL`. Modules can also be read from and written as Henshin
Text, Henshin's textual syntax (`.henshin_text` files); see <doc:HenshinTextSyntax>.

```swift
let resourceSet = ResourceSet()
try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource

let result = try await HenshinEngine().apply(
    unitNamed: "openAndFund", of: module, to: model,
    parameters: ["client": "Alice", "accountId": 4, "amount": 25])
if result.succeeded {
    for application in result.appliedRules { print(application.ruleName) }
}
```

## Related Documentation

### Command Line and Tutorials

- [swift-henshin](https://mipalgu.github.io/swift-modelling/documentation/swift_henshin/index.html) - the command-line tool of swift-modelling
- [Graph Transformation Rules with Henshin](https://mipalgu.github.io/swift-modelling/tutorials/swiftmodelling/henshin-01-graph-rules/index.html)
- [All tutorials](https://mipalgu.github.io/swift-modelling/tutorials/tutorials/index.html)

### Henshin Modules

- [HenshinAnalysis](https://mipalgu.github.io/swift-henshin/documentation/henshinanalysis/) - conflicts and dependencies of rules by critical pair analysis
- [HenshinStateSpace](https://mipalgu.github.io/swift-henshin/documentation/henshinstatespace/) - state-space exploration and model checking

### Related Packages

- [swift-ecore](https://mipalgu.github.io/swift-ecore/documentation/ecore/) - the Ecore metamodels and models that rules transform
- [swift-aql](https://mipalgu.github.io/swift-aql/documentation/aql/) - evaluates the attribute expressions of rules
- [swift-atl](https://mipalgu.github.io/swift-atl/) - ATL model transformations
- [swift-modelling](https://mipalgu.github.io/swift-modelling/) - command-line tools and tutorials for the whole toolkit

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:SupportedFeatures>
- ``HenshinModuleLoader``
- ``HenshinEngine``
- ``EngineOptions``
- ``IndexedModel``

### Henshin Text

- <doc:HenshinTextSyntax>
- ``HenshinTextLoader``
- ``HenshinText``
- ``HenshinTextParseResult``
- ``HenshinTextTranslation``
- ``HenshinTextWriting``
- ``HenshinTextConstants``
- ``HenshinTextOutlineKind``
- ``HenshinTextDiagnosticCode``

### Results

- ``UnitApplication``
- ``RuleApplication``
- ``Match``
- ``MatchStatistics``
- ``ParameterValues``

### Transformation Model

- ``HenshinModule``
- ``TransformationUnit``
- ``UnitKind``
- ``UnitID``
- ``Rule``
- ``RuleGraph``
- ``RuleNode``
- ``RuleEdge``
- ``RuleAttribute``
- ``NodeID``
- ``NodeMapping``
- ``Formula``
- ``NestedCondition``
- ``AttributeCondition``
- ``UnitParameter``
- ``ParameterKind``
- ``ParameterMapping``
- ``ParameterReference``

### Expressions

- <doc:JavaScriptToAQL>
- ``JavaScriptTranslator``
- ``TranslatedExpression``
- ``LiteralValue``

### Metamodel, Validation and Errors

- ``HenshinMetamodel``
- ``HenshinConstants``
- ``HenshinValidator``
- ``HenshinError``
- ``HenshinDiagnosticCode``
