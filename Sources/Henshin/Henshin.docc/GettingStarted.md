# Getting Started with Henshin

Load Henshin rules, apply them to an Ecore model and check them before use.

## Overview

This guide adds the package to a project, loads a Henshin module together with its
metamodel, applies a unit or rule to a model and reads the outcome. It also shows how to
validate a module and how to read and write Henshin Text.

## Installation

Add the package dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mipalgu/swift-henshin.git", branch: "main"),
]
```

Then add the `Henshin` product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Henshin", package: "swift-henshin"),
    ]
)
```

## Loading a module

Rules refer to the classes of a metamodel, so register the metamodel with a `ResourceSet`
before loading the module. Use the same resource set for the models you transform, so that
rule types and model classes are the same.

```swift
import ECore
import Henshin

let resourceSet = ResourceSet()
try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource
```

``HenshinModuleLoader/load(url:resourceSet:metamodels:)`` also accepts the locations of
metamodel documents to register first, so the metamodel can be passed in one call:

```swift
let module = try await HenshinModuleLoader.load(
    url: rulesURL, resourceSet: resourceSet, metamodels: [metamodelURL])
```

A ``HenshinModule`` holds its ``HenshinModule/units``; ``HenshinModule/rules`` lists those
that are single rules, and ``HenshinModule/unit(named:)`` finds a unit by name.

## Applying a unit or rule

``HenshinEngine`` applies a unit of the module to a resource. Parameters are given by name;
objects may be passed as their identities or as themselves.

```swift
let engine = HenshinEngine()
let result = try await engine.apply(
    unitNamed: "openAndFund", of: module, to: model,
    parameters: ["client": "Alice", "accountId": 4, "amount": 25])
```

To apply a rule on its own, pass the ``Rule`` itself:

```swift
if let rule = module.unit(named: "deposit")?.rule {
    let outcome = try await engine.apply(rule, to: model, parameters: ["accountId": 4])
}
```

``HenshinEngine/findMatches(of:in:parameters:limit:)`` finds the matches of a rule without
changing the model. ``EngineOptions`` controls matching, such as deterministic order,
overriding injectivity or the dangling condition, and whether an error restores the model.

```swift
let engine = HenshinEngine(options: EngineOptions(checkDangling: false))
let matches = try await engine.findMatches(of: rule, in: model, limit: 10)
```

## Inspecting the outcome

``HenshinEngine/apply(unitNamed:of:to:parameters:)`` returns a ``UnitApplication``. A unit
that does not succeed is not an error: ``UnitApplication/succeeded`` is then `false`.
Errors, such as a missing parameter or an expression that cannot be evaluated, are thrown
as ``HenshinError``, and the model is restored unless ``EngineOptions/restoresOnError`` is
turned off.

```swift
if result.succeeded {
    for application in result.appliedRules {
        print(application.ruleName, application.createdObjects.count, application.deletedObjects.count)
    }
}
print(result.parameters)  // output and input-output parameters
```

Each ``RuleApplication`` records its ``Match``, the objects it created and deleted and the
changes it made; ``MatchStatistics`` counts the work of the search.

## Validating a module

``HenshinValidator`` reports problems without applying anything: what the engine would
reject, Henshin's well-definedness checks and what Henshin's clean-up operation would
repair. Pass the metamodel packages to also check the imports of the module.

```swift
let packages = try await ModelIO.registerMetamodels(at: [metamodelURL], in: resourceSet)
for finding in HenshinValidator.validate(module, metamodels: packages) {
    print(finding.severity, finding.code, finding.message)
}
```

The finding codes are those of ``HenshinDiagnosticCode``.

## Henshin Text

``HenshinTextLoader`` reads a Henshin Text document (`.henshin_text`) as a module. It
finds the metamodels of the document's imports in the resource set, or beside the
document.

```swift
let module = try await HenshinTextLoader.load(url: textURL, resourceSet: resourceSet)
```

``HenshinTextLoader/translate(url:resourceSet:metamodels:)`` reports problems as
diagnostics instead of throwing them, which suits editors and checks.
``HenshinText/write(_:resourceSet:)`` writes a module back as a document in canonical form:

```swift
let writing = await HenshinText.write(module, resourceSet: resourceSet)
print(writing.text)
if !writing.isFaithful {
    for note in writing.diagnostics { print(note.message) }
}
```

``HenshinTextWriting/isFaithful`` is `true` when nothing that changes the meaning of the
module was lost. See <doc:HenshinTextSyntax> for the syntax.

## Next steps

- <doc:SupportedFeatures> lists the parts of Henshin that the engine interprets.
- <doc:JavaScriptToAQL> describes how attribute expressions are evaluated.
- The `HenshinAnalysis` and `HenshinStateSpace` modules analyse rules and explore the
  models that they reach.
