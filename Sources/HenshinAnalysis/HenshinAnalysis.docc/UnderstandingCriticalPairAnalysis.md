# Understanding Critical Pair Analysis

Learn what the analysis reports, at which levels of detail and what it takes into account.

## Overview

The analysis is static: it examines how the graphs of two rules can overlap, without a
model. Whenever the rules can be applied to some graph in which the overlap occurs, the
interaction is reported, whether or not any particular model exhibits it.

### Kinds of interaction

For an ordered pair of rules, where the first is applied first, the analysis reports:

| Kind | Direction | The first rule ... |
| :-- | :-- | :-- |
| ``InteractionKind/deleteUse`` | conflict | deletes a node or edge that the second matches |
| ``InteractionKind/produceForbid`` | conflict | creates what a negative application condition of the second forbids |
| ``InteractionKind/changeUse`` | both | changes an attribute that the second reads or changes |
| ``InteractionKind/changeForbid`` | both | changes an attribute that a negative condition of the second tests |
| ``InteractionKind/produceUse`` | dependency | creates a node or edge that the second matches |
| ``InteractionKind/deleteForbid`` | dependency | deletes what a negative condition of the second forbids |

As in Henshin's conflict and dependency analysis, a dependency of the second rule on the
first is found as a conflict of the inverse of the first rule with the second. The
direction to look in is an ``InteractionDirection``.

### Granularity

Results come at the levels of Born, Lambers, Strüber and Taentzer, "Granularity of conflicts
and dependencies in graph transformation systems" (FASE 2017). Each level includes the
results of the coarser levels (see ``AnalysisGranularity``):

- ``AnalysisGranularity/binary``: whether the rules interact at all;
- ``AnalysisGranularity/atoms``: the conflict or dependency atoms (``InteractionAtom``),
  single overlapped elements that cause an interaction and lie in a minimal reason;
- ``AnalysisGranularity/minimalReasons``: the minimal overlaps (``InteractionReason``) that
  cause an interaction;
- ``AnalysisGranularity/criticalPairs``: every critical pair (``CriticalPair``), with its
  overlap graph (the minimal context) and the matches of both rules. A pair whose overlap
  consists of the elements that cause the interaction is marked essential, after Lambers,
  Ehrig and Orejas, "Efficient conflict detection in graph transformation systems by
  essential critical pairs" (2008).

Finer levels cost more. Use ``AnalysisGranularity/binary`` to find which pairs of a large
rule set need attention, and ``AnalysisGranularity/criticalPairs`` to study them.

### What the analysis takes into account

An overlap counts only if both rules are applicable to its overlap graph: a node that a rule
deletes keeps no edge that the rule does not delete (when the rule checks the dangling
condition), and no negative application condition of either rule is certainly matched. By
default overlap graphs also respect the multiplicities of the metamodel: edges of one
reference between the same objects are one link, a reference and its opposite are the same
link, single-valued references and containment allow one partner, and an object has one
container. Positive application conditions of the second rule add to the elements it uses.
``AnalysisOptions`` switches each of these on or off.

### Approximation

The analysis over-approximates where it cannot decide: attribute conditions and non-literal
attribute expressions are taken to be satisfiable, so two attribute values conflict unless
both are different literals. It may therefore report an interaction that no model exhibits,
but it does not miss one that the supported rule features cause.

Each result lists in ``RulePairInteraction/notes`` what it approximated, such as
multi-rules (the kernel rule is analysed), disjunctive or nested application conditions,
and non-injective matching. ``RulePairInteraction/isTruncated`` is `true` when a limit of
the options cut the list of critical pairs short.
