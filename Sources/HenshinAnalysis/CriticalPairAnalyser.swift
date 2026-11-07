//
//  CriticalPairAnalyser.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin

/// The options of a conflict and dependency analysis.
public struct AnalysisOptions: Sendable, Hashable {
    /// Whether overlap graphs must respect the multiplicities of the metamodel.
    ///
    /// When set (the default), two edges of one reference between the same objects are
    /// identified, an object refers to at most one object through a single-valued reference
    /// or one whose opposite is single-valued, and an object has at most one container, as
    /// in every model of the Eclipse Modeling Framework.
    public var respectsMultiplicities: Bool

    /// Whether overlaps at which a negative application condition is certainly matched are
    /// left out (default `true`).
    public var checksNegativeConditions: Bool

    /// Whether the conclusions of positive application conditions of the second rule count
    /// as elements that it uses (default `true`).
    public var includesPositiveConditions: Bool

    /// Overrides the dangling condition of every rule, if given.
    public var checkDangling: Bool?

    /// The largest number of critical pairs reported for a rule pair, or `nil` for all.
    public var maximumCriticalPairs: Int?

    /// Whether only essential critical pairs are reported.
    public var essentialOnly: Bool

    /// The largest number of overlaps examined for one rule pair before the search stops,
    /// which bounds the time spent on large rules.
    public var searchBudget: Int

    /// Creates options.
    ///
    /// - Parameters:
    ///   - respectsMultiplicities: Whether overlaps respect metamodel multiplicities
    ///     (default `true`).
    ///   - checksNegativeConditions: Whether overlaps that match a negative condition are left
    ///     out (default `true`).
    ///   - includesPositiveConditions: Whether positive conditions of the second rule count as
    ///     used elements (default `true`).
    ///   - checkDangling: Overrides the dangling condition of every rule, if given.
    ///   - maximumCriticalPairs: The largest number of critical pairs per rule pair (default
    ///     1000).
    ///   - essentialOnly: Whether only essential critical pairs are reported (default
    ///     `false`).
    ///   - searchBudget: The largest number of overlaps examined per rule pair (default
    ///     1 000 000).
    public init(
        respectsMultiplicities: Bool = true, checksNegativeConditions: Bool = true,
        includesPositiveConditions: Bool = true, checkDangling: Bool? = nil, maximumCriticalPairs: Int? = 1000,
        essentialOnly: Bool = false, searchBudget: Int = 1_000_000
    ) {
        self.respectsMultiplicities = respectsMultiplicities
        self.checksNegativeConditions = checksNegativeConditions
        self.includesPositiveConditions = includesPositiveConditions
        self.checkDangling = checkDangling
        self.maximumCriticalPairs = maximumCriticalPairs
        self.essentialOnly = essentialOnly
        self.searchBudget = searchBudget
    }
}

/// Finds the conflicts and dependencies of Henshin rules by critical pair analysis.
///
/// The analysis is static: it examines how the graphs of two rules can overlap, without a
/// model. Following Ehrig, Ehrig, Prange and Taentzer, *Fundamentals of Algebraic Graph
/// Transformation* (2006), two rule applications are in conflict if one disables the other,
/// and the second depends on the first if the first enables it. The analysis reports, for an
/// ordered pair of rules:
///
/// - conflicts: *delete-use* (the first rule deletes what the second matches),
///   *produce-forbid* (the first creates what a negative condition of the second forbids),
///   *change-use* (the first changes an attribute that the second reads or changes) and
///   *change-forbid* (the first changes an attribute that a negative condition of the second
///   tests);
/// - dependencies: *produce-use* (the first creates what the second matches),
///   *delete-forbid* (the first deletes what a negative condition of the second forbids),
///   *change-use* and *change-forbid*.
///
/// Dependencies are found as conflicts of the inverse of the first rule, as in Henshin's
/// conflict and dependency analysis. Results come at the granularity levels of Born,
/// Lambers, Strüber and Taentzer (FASE 2017): whether the rules interact, the atoms, the
/// minimal reasons and the critical pairs, each critical pair with its overlap graph and the
/// matches of both rules. A critical pair is marked essential in the sense of Lambers, Ehrig
/// and Orejas (2008) when its overlap consists of the elements that cause the interaction.
///
/// The analysis over-approximates: attribute conditions and the values of non-literal
/// attribute expressions are not evaluated, so it may report interactions that no model
/// exhibits, but it does not miss one that the supported rule features cause.
///
/// ## Example
///
/// ```swift
/// let analyser = CriticalPairAnalyser()
/// let result = analyser.conflicts(first: deleteRule, second: useRule, granularity: .criticalPairs)
/// for pair in result.criticalPairs { print(pair) }
/// ```
public struct CriticalPairAnalyser: Sendable {
    /// The options of the analysis.
    public var options: AnalysisOptions

    /// Creates an analyser.
    ///
    /// - Parameter options: The options of the analysis (default options).
    public init(options: AnalysisOptions = AnalysisOptions()) {
        self.options = options
    }

    /// Finds the conflicts of two rules: how applying the first may disable the second.
    ///
    /// - Parameters:
    ///   - first: The rule applied first.
    ///   - second: The rule whose match the first may destroy.
    ///   - granularity: How finely to describe the conflicts (default
    ///     ``AnalysisGranularity/minimalReasons``).
    /// - Returns: The conflicts of the pair.
    public func conflicts(first: Rule, second: Rule, granularity: AnalysisGranularity = .minimalReasons)
        -> RulePairInteraction
    {
        analyse(first: first, second: second, direction: .conflict, granularity: granularity)
    }

    /// Finds the dependencies of two rules: how applying the first may enable the second.
    ///
    /// - Parameters:
    ///   - first: The rule applied first.
    ///   - second: The rule that may depend on the first.
    ///   - granularity: How finely to describe the dependencies (default
    ///     ``AnalysisGranularity/minimalReasons``).
    /// - Returns: The dependencies of the pair.
    public func dependencies(first: Rule, second: Rule, granularity: AnalysisGranularity = .minimalReasons)
        -> RulePairInteraction
    {
        analyse(first: first, second: second, direction: .dependency, granularity: granularity)
    }

    /// Analyses every ordered pair of a list of rules, each rule paired with itself too.
    ///
    /// - Parameters:
    ///   - rules: The rules.
    ///   - direction: Whether to look for conflicts or dependencies.
    ///   - granularity: How finely to describe the interactions (default
    ///     ``AnalysisGranularity/minimalReasons``).
    /// - Returns: The table of interactions.
    public func analyse(_ rules: [Rule], direction: InteractionDirection, granularity: AnalysisGranularity = .minimalReasons)
        -> InteractionTable
    {
        let prepared = rules.map { AnalysedRule($0, checkDangling: options.checkDangling) }
        let pairs = prepared.map { first in
            prepared.map { second in analyse(first, second, direction: direction, granularity: granularity) }
        }
        return InteractionTable(direction: direction, rules: rules.map(\.name), pairs: pairs)
    }

    /// Analyses one ordered pair of rules in one direction.
    ///
    /// - Parameters:
    ///   - first: The rule applied first.
    ///   - second: The other rule.
    ///   - direction: Whether to look for conflicts or dependencies.
    ///   - granularity: How finely to describe the interactions.
    /// - Returns: The interactions of the pair.
    public func analyse(first: Rule, second: Rule, direction: InteractionDirection, granularity: AnalysisGranularity)
        -> RulePairInteraction
    {
        analyse(
            AnalysedRule(first, checkDangling: options.checkDangling),
            AnalysedRule(second, checkDangling: options.checkDangling), direction: direction, granularity: granularity)
    }

    // MARK: - Problems

    /// The overlap problems whose reasons make up the interactions of a pair.
    func problems(_ first: AnalysedRule, _ second: AnalysedRule, direction: InteractionDirection) -> [OverlapProblem] {
        let secondLHS = options.includesPositiveConditions ? second.requiredLHS : second.lhs
        let secondConditions = options.checksNegativeConditions ? second.negativeConditions : []
        let secondSide = OverlapSide(
            graph: secondLHS, role: .leftHandSide, removedNodes: second.deletedNodes, removedEdges: second.deletedEdges,
            enforcesDangling: second.checksDangling, conditions: secondConditions)
        let forward = OverlapSide(
            graph: first.lhs, role: .leftHandSide, removedNodes: first.deletedNodes, removedEdges: first.deletedEdges,
            enforcesDangling: first.checksDangling,
            conditions: options.checksNegativeConditions ? first.negativeConditions : [])
        let inverse = OverlapSide(
            graph: first.rhs, role: .rightHandSide, removedNodes: first.createdNodes, removedEdges: first.createdEdges,
            enforcesDangling: true, conditions: [])
        let use = direction == .conflict ? forward : inverse
        let forbid = direction == .conflict ? inverse : forward
        var result = [
            OverlapProblem(
                first: use, second: secondSide, changed: direction == .conflict ? first.changedLHS : first.changedRHS,
                used: second.usedAttributes, criticalNodes: nil, criticalEdges: nil, protectedNodes: [],
                protectedEdges: [], removalKind: direction == .conflict ? .deleteUse : .produceUse, changeKind: .changeUse,
                respectsMultiplicities: options.respectsMultiplicities)
        ]
        for condition in second.negativeConditions where !condition.isNested {
            let conditionSide = OverlapSide(
                graph: condition.graph, role: condition.role, removedNodes: [], removedEdges: [], enforcesDangling: false,
                conditions: [])
            let allNodes = Set(condition.graph.nodes.indices)
            let allEdges = Set(condition.graph.edges.indices)
            result.append(
                OverlapProblem(
                    first: forbid, second: conditionSide,
                    changed: direction == .conflict ? first.changedRHS : first.changedLHS,
                    used: condition.conditionOnlyAttributes, criticalNodes: condition.conditionOnlyNodes,
                    criticalEdges: condition.conditionOnlyEdges,
                    protectedNodes: allNodes.subtracting(condition.conditionOnlyNodes),
                    protectedEdges: allEdges.subtracting(condition.conditionOnlyEdges),
                    removalKind: direction == .conflict ? .produceForbid : .deleteForbid, changeKind: .changeForbid,
                    respectsMultiplicities: options.respectsMultiplicities))
        }
        return result
    }

    // MARK: - Analysis

    /// Analyses one ordered pair of prepared rules in one direction.
    func analyse(_ first: AnalysedRule, _ second: AnalysedRule, direction: InteractionDirection, granularity: AnalysisGranularity)
        -> RulePairInteraction
    {
        var budget = options.searchBudget
        var kinds = Set<InteractionKind>()
        var atoms: [InteractionAtom] = []
        var reasons: [InteractionReason] = []
        var pairs: [CriticalPair] = []
        var truncated = false
        var notes = first.notes
        for note in second.notes where !notes.contains(note) { notes.append(note) }
        for problem in problems(first, second, direction: direction) {
            let candidates = problem.atomCandidates()
            if granularity == .binary {
                for candidate in candidates
                where problem.closures(of: candidate.span, budget: &budget).contains(where: { isValid($0, problem) }) {
                    return RulePairInteraction(
                        direction: direction, firstRule: first.rule.name, secondRule: second.rule.name,
                        granularity: granularity, interacts: true, kinds: [candidate.element.kind], atoms: [],
                        minimalReasons: [], criticalPairs: [], isTruncated: false, notes: notes)
                }
                continue
            }
            var closed: [Span] = []
            var known = Set<Span>()
            for candidate in candidates {
                for span in problem.closures(of: candidate.span, budget: &budget)
                where isValid(span, problem) && known.insert(span).inserted {
                    closed.append(span)
                }
            }
            let minimal = closed.filter { span in
                !closed.contains { other in other != span && other.isContained(in: span) }
            }.sorted { $0.size < $1.size }
            for candidate in candidates {
                let count = minimal.filter { candidate.span.isContained(in: $0) }.count
                if count > 0 {
                    atoms.append(
                        InteractionAtom(
                            element: candidate.element, span: problem.publicSpan(candidate.span), minimalReasonCount: count))
                    kinds.insert(candidate.element.kind)
                }
            }
            if granularity >= .minimalReasons {
                for span in minimal {
                    let elements = problem.criticalElements(of: span)
                    reasons.append(
                        InteractionReason(
                            kinds: Set(elements.map(\.kind)).sorted(), span: problem.publicSpan(span),
                            criticalElements: elements))
                }
            }
            if granularity >= .criticalPairs {
                let limit = options.maximumCriticalPairs.map { max($0 - pairs.count, 0) }
                let found = criticalPairs(problem, seeds: minimal, limit: limit, budget: &budget)
                pairs += found.pairs
                truncated = truncated || found.truncated
            }
        }
        if budget <= 0 {
            truncated = true
            notes.append("the search budget of \(options.searchBudget) overlaps was exhausted; results may be incomplete")
        }
        return RulePairInteraction(
            direction: direction, firstRule: first.rule.name, secondRule: second.rule.name, granularity: granularity,
            interacts: !kinds.isEmpty, kinds: kinds.sorted(), atoms: atoms, minimalReasons: reasons, criticalPairs: pairs,
            isTruncated: truncated, notes: notes)
    }

    /// Whether no negative condition of either rule is certainly matched at a closed span.
    func isValid(_ span: Span, _ problem: OverlapProblem) -> Bool {
        guard !problem.first.conditions.isEmpty || !problem.second.conditions.isEmpty else { return true }
        let glued = GluedGraph(problem, span)
        for condition in problem.first.conditions where glued.matches(condition, hostImage: glued.firstImage, fromFirst: true) {
            return false
        }
        for condition in problem.second.conditions
        where glued.matches(condition, hostImage: glued.secondImage, fromFirst: false) {
            return false
        }
        return true
    }

    /// The critical pairs of a problem: all valid closed spans that extend a minimal reason.
    ///
    /// - Parameters:
    ///   - problem: The overlap problem.
    ///   - seeds: The minimal reasons of the problem.
    ///   - limit: The largest number of pairs to return, or `nil` for all.
    ///   - budget: The number of spans that may still be examined; it is decreased.
    /// - Returns: The critical pairs and whether the limit or the budget cut them short.
    func criticalPairs(_ problem: OverlapProblem, seeds: [Span], limit: Int?, budget: inout Int)
        -> (pairs: [CriticalPair], truncated: Bool)
    {
        var found = Set<Span>()
        var ordered: [Span] = []
        var truncated = false
        let first = problem.first.graph
        let second = problem.second.graph
        func extend(_ span: Span, from position: Int) {
            guard !truncated else { return }
            guard budget > 0 else {
                truncated = true
                return
            }
            if position == first.nodeCount {
                let variants = options.respectsMultiplicities ? [span] : optionalEdges(of: span, problem)
                for closed in variants.flatMap({ problem.closures(of: $0, budget: &budget) }) where !found.contains(closed) {
                    guard isValid(closed, problem) else { continue }
                    if options.essentialOnly && !problem.isEssential(closed) { continue }
                    found.insert(closed)
                    ordered.append(closed)
                    if let limit, ordered.count >= limit {
                        truncated = true
                        return
                    }
                }
                return
            }
            budget -= 1
            extend(span, from: position + 1)
            guard span.firstNodes[position] == nil else { return }
            for b in second.nodes.indices where problem.canPair(node: position, with: b, in: span) {
                var extended = span
                extended.pair(node: position, with: b)
                extend(extended, from: position + 1)
                guard !truncated else { return }
            }
        }
        for seed in seeds {
            extend(seed, from: 0)
            if truncated { break }
        }
        let pairs = ordered.sorted { $0.size < $1.size }.map { span -> CriticalPair in
            let glued = GluedGraph(problem, span)
            let elements = problem.criticalElements(of: span)
            var firstMatch: [NodeID: Int] = [:]
            for (a, node) in first.nodes.enumerated() { firstMatch[node.id] = glued.firstImage[a] }
            var secondMatch: [NodeID: Int] = [:]
            for (b, node) in second.nodes.enumerated() { secondMatch[node.id] = glued.secondImage[b] }
            return CriticalPair(
                kinds: Set(elements.map(\.kind)).sorted(), span: problem.publicSpan(span), graph: glued.overlapGraph(of: problem),
                firstMatch: firstMatch, secondMatch: secondMatch, criticalElements: elements,
                isEssential: problem.isEssential(span))
        }
        return (pairs, truncated)
    }

    /// The spans that identify, in addition, any subset of the parallel edges of the same
    /// type that a span leaves apart, for analyses that ignore multiplicities.
    func optionalEdges(of span: Span, _ problem: OverlapProblem) -> [Span] {
        var spans = [span]
        for (a, edge) in problem.first.graph.edges.enumerated() where span.firstEdges[a] == nil {
            guard let source = span.firstNodes[edge.source], let target = span.firstNodes[edge.target] else { continue }
            for b in problem.second.graph.outgoing[source] where span.secondEdges[b] == nil {
                let other = problem.second.graph.edges[b]
                guard other.target == target, other.type == edge.type else { continue }
                spans += spans.compactMap { problem.pairing(edge: a, with: b, in: $0) }
                break
            }
        }
        return spans
    }
}
