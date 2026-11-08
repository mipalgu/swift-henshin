# Supported Henshin Features

Learn which parts of Henshin the engine interprets and how it applies them.

## Overview

The engine follows the semantics of Henshin's interpreter, which rests on algebraic graph
transformation in the double-pushout approach with application conditions.

### Rules

- Nodes and edges of the left-hand side without an image in the right-hand side are
  deleted; those of the right-hand side without an origin are created; mapped ones are
  preserved. A node matches objects of its class and of its subclasses.
- Attributes of the left-hand side constrain values: a literal must be equal, a parameter
  is bound by the first attribute it appears in and must be equal in the others, and any
  other expression is evaluated as soon as the parameters it refers to have values.
  Attributes of the right-hand side assign values where they differ from the left-hand side.
- Attribute conditions are evaluated as soon as their parameters have values.
- Injective matching, the default, maps different nodes to different objects.
- The dangling condition, checked by default, makes a rule inapplicable if deleting its
  objects would leave a reference dangling: every reference at a deleted object, including
  containment and the opposite of a deleted reference, must be deleted by the rule. Without
  it, the references to deleted objects are removed, and deleted objects take their
  contents with them.
- Application conditions are formulas of nested conditions with `Not`, `And`, `Or`, `Xor`
  and `True`, nested to any depth. A negated nested condition is a negative application
  condition; a nested condition on its own is a positive one.
- Multi-rules are applied at every match that extends the match of their kernel rule
  (amalgamation), recursively, and the dangling condition is checked for the amalgamated
  rule.
- Parameters of kind `IN` and `INOUT` must be given; `OUT` and `VAR` cannot be. A parameter
  named like a node passes the node's object in or out. The values of `VAR` parameters are
  hidden from the caller: ``UnitApplication/parameters`` leaves them out, while the rule
  applications in ``UnitApplication/appliedRules`` still record them.
- A value given for a parameter whose declared type is one of Ecore's text, Boolean, integer
  or real data types must suit that type, such as an integer for an `EInt` parameter;
  otherwise the application is refused with
  ``HenshinError/parameterTypeMismatch(unit:parameter:expected:)`` before anything changes.
  Accepted values are converted to the declared type.

### Units

| Unit | Behaviour |
| :-- | :-- |
| `SequentialUnit` | Applies its sub-units in order. A strict unit fails when a sub-unit fails and, with rollback, undoes its changes. A lenient unit succeeds if any sub-unit does. |
| `ConditionalUnit` | Applies the then-unit if the condition unit succeeds, else the else-unit; if the branch fails, everything is undone. |
| `PriorityUnit` | Applies the first sub-unit that succeeds. |
| `IndependentUnit` | Applies one sub-unit that succeeds, tried in order when matching deterministically and in random order otherwise. |
| `LoopUnit` | Applies its sub-unit for as long as it succeeds, and always succeeds. |
| `IteratedUnit` | Applies its sub-unit a number of times given by a constant, a parameter or an expression; strictness and rollback as for sequential units. |

Parameter mappings pass values to sub-units before they are applied and back afterwards.

### Static checks

``HenshinValidator`` reports, besides what the engine cannot interpret, Henshin's checks of
well-definedness and consistency:

| Finding | Severity |
| :-- | :-- |
| Two rules or units with the same name and parameter list | Error |
| A `VAR` parameter that occurs in no left-hand side (node name, attribute value or edge position, including nested conditions and multi-rules) | Error |
| A unit that passes no value to an `IN` or `INOUT` parameter of a sub-unit | Error |
| A rule that checks the dangling condition and deletes a node without its containment edge | Warning |
| A rule graph with a cycle of containment edges | Warning |

It also reports, as warnings, what Henshin's clean-up operation ([Strüber et al., ICGT 2017](https://doi.org/10.1007/978-3-319-61470-0_12))
would remove or repair:

| Finding | Code |
| :-- | :-- |
| A rule parameter that names no node and occurs in no attribute value, edge position or attribute condition of the rule or its multi-rules; a unit parameter in no parameter mapping or number of iterations | `henshin.unused-parameter` |
| A node with two images in one graph, or two nodes with the same image | `henshin.ambiguous-mapping` |
| A rule mapping or multi-mapping between different classes, or a condition mapping between unrelated classes | `henshin.mapping-type-mismatch` |
| A multi-mapping that does not lead from a side of the kernel rule to the same side of the multi-rule, or multi-mappings of a rule that is not a multi-rule | `henshin.invalid-multi-mapping` |
| A condition mapping that does not lead from the graph holding the condition to its conclusion | `henshin.invalid-condition-mapping` |
| An application condition of a right-hand side | `henshin.rhs-formula` |
| A nested condition that always holds or can never hold | `henshin.trivial-condition` |
| A multi-rule that only repeats its kernel rule | `henshin.redundant-multi-rule` |
| A multi-rule that preserves, deletes or creates a copy of a kernel edge differently from its kernel | `henshin.multi-rule-edge-mismatch` |
| A multi-rule parameter with another kind or type than the kernel's parameter of the same name | `henshin.multi-rule-parameter-mismatch` |
| An iterated unit without a number of iterations | `henshin.empty-iterations` |
| A parameter mapping to a unit that is not the unit itself or a direct sub-unit, or to an undeclared parameter | `henshin.invalid-parameter-mapping` |
| An imported package that no node uses, or a node class whose package is not imported, when the metamodels are given | `henshin.unused-import`, `henshin.missing-import` |

Henshin's clean-up counts a parameter as used only if it is a node name or a whole attribute
value; parameters that expressions use are counted as used here. Multi-rules that lack
parameters of their kernel are not reported, since the engine passes the kernel's
parameters to them.

### Matching

Matches are found by a backtracking search over a search plan. Nodes bound by parameters
come first; then the engine repeatedly takes the node with the fewest expected candidates,
preferring nodes it can reach through a reference from a node already bound (in either
direction, using an index of incoming references) over enumerating all objects of a type.
Edges, attributes, injectivity and the dangling condition are checked as soon as they can
be. Matching is deterministic by default; ``EngineOptions/randomSeed`` makes
non-deterministic matching reproducible.

### Differences from Henshin

- Expressions are JavaScript translated into AQL (see <doc:JavaScriptToAQL>); Java calls
  and Henshin's aggregation helpers are not supported. Java imports are kept with their
  rules but not interpreted.
- Rolling back restores the model to its state before the unit started, including the
  effects of nested units that failed without rolling back themselves.
- Edge positions (`index`) are read but not interpreted.
- Only dynamic objects take part in matching.
