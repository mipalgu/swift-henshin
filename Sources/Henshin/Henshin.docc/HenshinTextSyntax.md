# Henshin Text

Read and write Henshin's textual syntax.

## Overview

Henshin Text is the textual syntax of Henshin, defined by an Xtext grammar in the Eclipse
Henshin project. Documents conventionally have the file extension `.henshin_text`
(``HenshinTextConstants/fileExtension``). A rule is written as a single graph whose nodes,
edges and attributes carry actions, and a unit as calls within control structures:

```
ePackageImport bank

rule deposit(IN id:EInt, IN amount:EInt, VAR x:EInt) {
	conditions [amount > 0]
	graph {
		node target:Account {
			id = id
			balance = x
			set balance = x + amount
		}
	}
}

unit depositTwice(IN id:EInt, IN amount:EInt) {
	for (2) {
		deposit(id, amount)
	}
}
```

``HenshinTextLoader`` reads a document and translates it into the same ``HenshinModule``
that a `.henshin` document gives, so that ``HenshinEngine`` applies it and
``HenshinValidator`` checks it. The metamodel packages that `ePackageImport` names are
looked up among the metamodels of the resource set and, failing that, in the Ecore
documents beside the document:

```swift
let resourceSet = ResourceSet()
let module = try await HenshinTextLoader.load(url: textURL, resourceSet: resourceSet)
let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource
let result = try await HenshinEngine().apply(
    unitNamed: "depositTwice", of: module, to: model, parameters: ["id": 2, "amount": 10])
```

For editors, ``HenshinText/parse(_:)`` returns the syntax errors with their positions, an
outline and the tokens of a document, recovering from errors so that one mistake does not
hide the rest. ``HenshinTextLoader/translate(url:resourceSet:metamodels:)`` and
``HenshinText/translate(_:packages:)`` report the problems of translation, such as unknown
classes, unknown parameters or actions that do not fit together, with their positions
instead of throwing them.

``HenshinText/write(_:packages:)`` writes a module as Henshin Text in a canonical form:
reading the document back gives a module with the same behaviour, and writing that module
again gives the same document. A module read from a `.henshin` document can be written as
well; what Henshin Text cannot express is reported with the code
``HenshinTextDiagnosticCode/notExpressible``, and what the writer changes in order to
express the module, with ``HenshinTextDiagnosticCode/adjusted``. The grammar of Henshin Text
has no element for descriptions: the description of a unit is written as a `//` comment
before the unit, which reading the document does not restore, and the description of the
module is left out with a warning.

### Translation

The translation follows Henshin's own translation of Henshin Text into its module model:

- Nodes without action or marked `preserve` appear on both sides of the rule and are mapped
  by name; `delete` nodes appear on the left, `create` nodes on the right. The sides are
  named after the rule, such as `deposit_LHS`.
- Attributes without action are kept; `delete` and `create` attributes appear on one side;
  `set` changes the value that a kept attribute has on the right-hand side.
- Edges follow their action, and an edge at a created node is created.
- `forbid` elements form a negative application condition named `forbid`, `require`
  elements a positive one named `require`; nodes that they connect to are copied into the
  condition. A `matchingFormula` combines condition graphs with `!`, `AND`, `OR` and `XOR`;
  `reuse` refers to a node of the enclosing graph. All of these are joined by conjunction.
- A multi-rule receives the parameters of its rule, copies of its kernel rule's nodes and
  edges, and multi-mappings from the kernel to these copies; `reuse` adds attributes to the
  copies.
- A unit of calls is a sequential unit; a unit with a single control structure is a
  conditional, priority, independent, iterated or loop unit. Every block that is not a
  single call becomes a unit of its own, named after the enclosing unit as in Henshin (for
  example `buildGridSequence0_1`), with the parameters of the enclosing unit, to which it is
  connected parameter by parameter.
- A call passes its arguments to the parameters of the called rule or unit that are not
  variables, in order, and takes their values back afterwards.
- Expressions become the JavaScript text that Henshin stores: `AND` and `OR` become `&&` and
  `||`, and operators are written without spaces, as in `x+amount`.
- The module is named `HenshinDSL`, as in Henshin.

### Coverage

| Construct | Status |
| :-- | :-- |
| `ePackageImport` with simple or qualified package names | Supported |
| `rule` and `unit` with parameters of kind `IN`, `OUT`, `INOUT`, `VAR` or none, typed by a data type keyword or a class | Supported |
| `checkDangling`, `injectiveMatching` and `conditions` | Supported |
| `graph` with nodes, attributes and edges marked `preserve`, `create`, `delete`, `forbid` or `require`, and `set` attributes | Supported |
| `matchingFormula` with condition graphs, `reuse` and nested formulas | Supported |
| `multiRule` with `reuse`, nested to any depth | Supported |
| Sequences with `strict` and `rollback`, `if`/`then`/`else`, `priority`, `independent`, `for`, `while` and nested blocks | Supported |
| Expressions with `OR`, `AND`, comparisons, arithmetic, `!`, parentheses, parameters, strings, numbers and truth values | Supported |
| `javaImport`, Java calls such as `Math.max(a, b)` and fields such as `Integer.MAX_VALUE` | Partial: read and written; evaluated only within the subset of <doc:JavaScriptToAQL> |
| Checks of Henshin's editor: names, actions, argument counts, abstract classes, repeated options | Supported |
| Type checks of call arguments and checks that Java packages exist | Not supported |
| References to rules or units of other documents | Not supported |

### Differences from Henshin's translation

Where Henshin's translation produces a module that cannot work, the translation here
produces the module that the document describes:

- The units of nested blocks have no random number in their names, and their parameters
  keep the names of the enclosing unit's parameters, so that numbers of iterations keep
  referring to them. Units are listed in document order, followed by the units of nested
  blocks, rather than grouped by kind.
- String literals keep their quotes, so that they stay strings.
- An attribute marked `preserve` on a node without action is kept, and attributes of a
  `reuse` in a multi-rule without action, or with `set`, follow the reused node.
- A nested condition graph maps the nodes it reuses from the condition graph that encloses
  it.
- A minus sign directly before a number starts a negative number only where an operand is
  expected, so that `x-1` is a subtraction.

### Writing

The writer prefers the names that nodes have and otherwise names them after their class,
without taking the name of a parameter, which would bind it. Application conditions are
written as matching formulas over condition graphs named after their conclusions. Untyped
parameters take the data type of the attributes they fill, of the parameters they are
mapped to, or `EInt` if they count iterations, and otherwise `EJavaObject`. Descriptions are
written as comments, which are not read back.

Henshin Text cannot express, and the writer reports: deactivated units, the strictness and
rollback of iterated units, positions of edges, conditions of right-hand sides, `null`,
`%` and `?:` in expressions, several parameters mapped to one parameter of a sub-unit,
mappings to variables of sub-units, parameters of multi-rules beyond their kernel's, and
nodes of conditions that refine the class of the node they reuse. Where a call would not
pass a value to every parameter of the called unit, the writer gives the calling unit a
variable for it.
