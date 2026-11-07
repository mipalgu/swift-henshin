# Understanding State Spaces

Learn how states are identified, how exploration is bounded and what the checks conclude.

## Overview

A state space is a graph. Its nodes are the models that the rules can reach from a start
model, and its edges are the rule and unit applications that lead from one to another. The
start model is state 0 (``StateSpace/initialState``). The model that you give to the
explorer is not changed.

### Identifying states

Models that differ only in the identities and order of their objects are the same state
(``StateEquivalence/isomorphism``). Each model is reduced to a graph whose nodes are labelled
with the class and attribute values of the objects and whose edges are labelled with
reference names. Colour refinement in the style of Weisfeiler and Leman yields a certificate
that isomorphic graphs share; states with equal certificates are compared by an exact
isomorphism search that the refined colours prune. ``StateEquivalence/identity`` instead
keeps states apart unless they have the same objects.

### Bounds

``ExplorationOptions`` limit the number of states, the depth and the number of objects of
explored states. A state that a limit cuts off stays open (``ExploredState/isOpen``), the
state space is then incomplete (``StateSpace/isComplete`` is `false`), and checks that find
no witness or counterexample say that they are inconclusive. Models whose rules create
objects without end have infinite state spaces, so always set a bound for them.

### Rules with parameters

A rule's parameters are bound by matching where its left-hand side determines them. Values
for other parameters are given per rule or unit in ``ExplorationOptions/parameterValues``;
the explorer reports a required parameter that has neither.

### Units

A unit is applied as one atomic step, with the deterministic semantics of the engine, so it
contributes at most one successor per parameter assignment. Rules are applied at every match.

### Checking properties

``ModelChecker`` checks reachability of a state, invariants over all states and freedom from
deadlocks. Predicates (``StatePredicate``) are patterns given as rules with their
application conditions, forbidden patterns, expressions of the Acceleo Query Language with
`self` bound to the first root object, functions of the model, and their combinations.

A witness or counterexample comes with a shortest path from the initial state, each step
naming the rule and its match, which replays on the start model.

### Conclusive results

A ``CheckResult`` is conclusive when its answer holds for every model that the rules can
reach. A witness or counterexample is always conclusive. The absence of one is conclusive
only if the state space is complete; otherwise ``CheckResult/isConclusive`` is `false`, and
the result says only that nothing was found within the bounds.
