//
//  OverlapProblem.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin

/// A partial, injective identification of the nodes and edges of two graphs.
///
/// The arrays hold, for each node or edge of either graph, the position of the element of
/// the other graph that it is identified with, if any.
struct Span: Sendable, Hashable {
    /// The node of the second graph that each node of the first graph is identified with.
    var firstNodes: [Int?]

    /// The node of the first graph that each node of the second graph is identified with.
    var secondNodes: [Int?]

    /// The edge of the second graph that each edge of the first graph is identified with.
    var firstEdges: [Int?]

    /// The edge of the first graph that each edge of the second graph is identified with.
    var secondEdges: [Int?]

    /// Creates an empty span between graphs of the given sizes.
    init(firstNodes: Int, secondNodes: Int, firstEdges: Int, secondEdges: Int) {
        self.firstNodes = Array(repeating: nil, count: firstNodes)
        self.secondNodes = Array(repeating: nil, count: secondNodes)
        self.firstEdges = Array(repeating: nil, count: firstEdges)
        self.secondEdges = Array(repeating: nil, count: secondEdges)
    }

    /// Identifies two nodes.
    mutating func pair(node first: Int, with second: Int) {
        firstNodes[first] = second
        secondNodes[second] = first
    }

    /// Identifies two edges.
    mutating func pair(edge first: Int, with second: Int) {
        firstEdges[first] = second
        secondEdges[second] = first
    }

    /// The number of identified nodes and edges.
    var size: Int { firstNodes.lazy.compactMap { $0 }.count + firstEdges.lazy.compactMap { $0 }.count }

    /// Whether every identification of this span is also one of another span.
    ///
    /// - Parameter other: The other span.
    /// - Returns: `true` if this span is contained in the other.
    func isContained(in other: Span) -> Bool {
        for (position, image) in firstNodes.enumerated() where image != nil && other.firstNodes[position] != image {
            return false
        }
        for (position, image) in firstEdges.enumerated() where image != nil && other.firstEdges[position] != image {
            return false
        }
        return true
    }
}

/// What has to happen next to turn a span into a closed one.
enum Obligation: Sendable {
    /// The span is closed.
    case none
    /// The span cannot be closed.
    case fail
    /// The span is closed only if it is extended in one of these ways.
    case choices([Span])
}

/// The rule whose application an overlap problem examines, seen from the graph it overlaps.
struct OverlapSide: Sendable {
    /// The graph that is overlapped.
    let graph: AnalysisGraph

    /// The role of the graph in its rule.
    let role: RuleGraphRole

    /// The nodes of the graph that the rule removes.
    let removedNodes: Set<Int>

    /// The edges of the graph that the rule removes.
    let removedEdges: Set<Int>

    /// Whether removing a node requires every edge at the node to be removed too.
    let enforcesDangling: Bool

    /// The negative application conditions of the rule, over this graph, that must hold at
    /// the match in the overlap graph.
    let conditions: [AnalysedCondition]
}

/// An overlap problem: which identifications of two graphs show an interaction of two rules.
///
/// The first side is the graph of the first rule (its left-hand side for conflicts and the
/// deletion of a node that a condition forbids, its right-hand side otherwise) and the
/// elements that the first rule's step removes from it. The second side is the left-hand side
/// of the second rule or a negative condition of it. A span is a reason if it identifies at
/// least one critical element, every node that a step removes keeps no dangling edge in the
/// overlap graph, the overlap graph respects the multiplicities of the metamodel, and no
/// negative condition is matched in the overlap graph.
struct OverlapProblem: Sendable {
    /// The first side.
    let first: OverlapSide

    /// The second side.
    let second: OverlapSide

    /// The attributes that the first rule changes, by node of the first graph.
    let changed: [Int: Set<String>]

    /// The attributes of second-graph nodes whose change causes an interaction.
    let used: [Int: Set<String>]

    /// The second-graph nodes at which a removal causes an interaction, or `nil` for all.
    let criticalNodes: Set<Int>?

    /// The second-graph edges at which a removal causes an interaction, or `nil` for all.
    let criticalEdges: Set<Int>?

    /// The second-graph nodes that must exist before the first step and so cannot be
    /// identified with a node that the step removes.
    let protectedNodes: Set<Int>

    /// The second-graph edges that cannot be identified with an edge that the step removes.
    let protectedEdges: Set<Int>

    /// The kind of interaction that a removed element causes.
    let removalKind: InteractionKind

    /// The kind of interaction that a changed attribute causes.
    let changeKind: InteractionKind

    /// Whether the overlap graph must respect single-valued references, opposites and
    /// containment.
    let respectsMultiplicities: Bool

    /// The empty span of the problem.
    var emptySpan: Span {
        Span(
            firstNodes: first.graph.nodeCount, secondNodes: second.graph.nodeCount,
            firstEdges: first.graph.edgeCount, secondEdges: second.graph.edgeCount)
    }

    // MARK: - Identifications

    /// Whether two nodes may be identified in a span.
    func canPair(node a: Int, with b: Int, in span: Span) -> Bool {
        guard span.firstNodes[a] == nil, span.secondNodes[b] == nil else { return false }
        let left = first.graph.nodes[a]
        let right = second.graph.nodes[b]
        guard TypeConformance.compatible(left.type, right.type) else { return false }
        for (feature, term) in left.attributes {
            if let other = right.attributes[feature], !term.isCompatible(with: other) { return false }
        }
        if first.removedNodes.contains(a) && protectedNodes.contains(b) { return false }
        return true
    }

    /// Identifies two edges, and their end nodes as needed.
    ///
    /// - Returns: The extended span, or `nil` if the edges or their end nodes cannot be
    ///   identified.
    func pairing(edge a: Int, with b: Int, in span: Span) -> Span? {
        guard span.firstEdges[a] == nil, span.secondEdges[b] == nil else { return nil }
        let left = first.graph.edges[a]
        let right = second.graph.edges[b]
        guard left.type == right.type else { return nil }
        if first.removedEdges.contains(a) && protectedEdges.contains(b) { return nil }
        guard (left.source == left.target) == (right.source == right.target) else { return nil }
        var result = span
        for (x, y) in [(left.source, right.source), (left.target, right.target)] {
            if result.firstNodes[x] == y { continue }
            guard canPair(node: x, with: y, in: result) else { return nil }
            result.pair(node: x, with: y)
        }
        result.pair(edge: a, with: b)
        return result
    }

    // MARK: - Closure

    /// The first obligation that a span does not meet.
    func obligation(of span: Span) -> Obligation {
        for (a, image) in span.firstNodes.enumerated() {
            guard let b = image else { continue }
            if first.enforcesDangling && first.removedNodes.contains(a) {
                for edge in second.graph.incident(b) where span.secondEdges[edge] == nil {
                    let options = first.graph.incident(a).filter { first.removedEdges.contains($0) }.compactMap {
                        pairing(edge: $0, with: edge, in: span)
                    }
                    return options.isEmpty ? .fail : .choices(options)
                }
            }
            if second.enforcesDangling && second.removedNodes.contains(b) {
                for edge in first.graph.incident(a) where span.firstEdges[edge] == nil {
                    let options = second.graph.incident(b).filter { second.removedEdges.contains($0) }.compactMap {
                        pairing(edge: edge, with: $0, in: span)
                    }
                    return options.isEmpty ? .fail : .choices(options)
                }
            }
        }
        if respectsMultiplicities {
            let multiplicity = multiplicityObligation(of: span)
            if case .none = multiplicity {} else { return multiplicity }
        }
        return .none
    }

    /// The first multiplicity constraint of the metamodel that a span does not meet.
    ///
    /// Edges of one reference between the same objects are one link; a single-valued
    /// reference, or one whose opposite is single-valued, links an object to at most one
    /// other; and an object has at most one container.
    func multiplicityObligation(of span: Span) -> Obligation {
        for (a, left) in first.graph.edges.enumerated() {
            guard let source = span.firstNodes[left.source] else {
                if let target = span.firstNodes[left.target] {
                    if let result = uniqueness(of: a, atTarget: target, in: span) { return result }
                }
                continue
            }
            for b in second.graph.outgoing[source] {
                let right = second.graph.edges[b]
                if right.type != left.type {
                    continue
                }
                let target = span.firstNodes[left.target]
                if target == right.target {
                    if span.firstEdges[a] == b { continue }
                    if span.firstEdges[a] == nil && span.secondEdges[b] == nil {
                        if let extended = pairing(edge: a, with: b, in: span) { return .choices([extended]) }
                    }
                    return .fail
                }
                if left.type.sourceUnique {
                    if target == nil && span.secondNodes[right.target] == nil
                        && canPair(node: left.target, with: right.target, in: span)
                    {
                        var extended = span
                        extended.pair(node: left.target, with: right.target)
                        return .choices([extended])
                    }
                    return .fail
                }
            }
            if let target = span.firstNodes[left.target] {
                if let result = uniqueness(of: a, atTarget: target, in: span) { return result }
            }
        }
        return .none
    }

    /// The obligation that an edge of the first graph imposes at an identified target node.
    private func uniqueness(of a: Int, atTarget target: Int, in span: Span) -> Obligation? {
        let left = first.graph.edges[a]
        for b in second.graph.incoming[target] {
            let right = second.graph.edges[b]
            if left.type.isContainment && right.type.isContainment && left.type != right.type { return .fail }
            guard right.type == left.type, left.type.targetUnique else { continue }
            let source = span.firstNodes[left.source]
            if source == right.source { continue }
            if source == nil && span.secondNodes[right.source] == nil
                && canPair(node: left.source, with: right.source, in: span)
            {
                var extended = span
                extended.pair(node: left.source, with: right.source)
                return .choices([extended])
            }
            return .fail
        }
        return nil
    }

    /// The closed spans that extend a span by what its obligations force.
    ///
    /// - Parameters:
    ///   - span: The span to close.
    ///   - budget: The number of spans that may still be examined; it is decreased.
    /// - Returns: The closed extensions, each of which adds only what some obligation forced.
    func closures(of span: Span, budget: inout Int) -> [Span] {
        var results: [Span] = []
        var found = Set<Span>()
        var seen = Set<Span>()
        var stack = [span]
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            guard budget > 0 else { break }
            budget -= 1
            switch obligation(of: current) {
            case .none:
                if found.insert(current).inserted { results.append(current) }
            case .fail:
                continue
            case .choices(let options):
                stack.append(contentsOf: options.reversed())
            }
        }
        return results
    }

    // MARK: - Critical elements

    /// The elements of a span that cause an interaction.
    func criticalElements(of span: Span) -> [CriticalElement] {
        var result: [CriticalElement] = []
        for (a, image) in span.firstNodes.enumerated() {
            guard let b = image else { continue }
            let left = first.graph.nodes[a]
            let right = second.graph.nodes[b]
            if first.removedNodes.contains(a) && (criticalNodes?.contains(b) ?? true) {
                result.append(
                    CriticalElement(kind: removalKind, overlap: ElementOverlap(first: .node(left.id), second: .node(right.id))))
            }
            for feature in (changed[a] ?? []).intersection(used[b] ?? []).sorted() {
                result.append(
                    CriticalElement(
                        kind: changeKind,
                        overlap: ElementOverlap(
                            first: .attribute(node: left.id, feature: feature),
                            second: .attribute(node: right.id, feature: feature))))
            }
        }
        for (a, image) in span.firstEdges.enumerated() {
            guard let b = image, first.removedEdges.contains(a), criticalEdges?.contains(b) ?? true else { continue }
            result.append(
                CriticalElement(
                    kind: removalKind,
                    overlap: ElementOverlap(first: first.graph.edges[a].element, second: second.graph.edges[b].element)))
        }
        return result
    }

    /// The candidate atoms of the problem: single critical elements with the end nodes of
    /// edges.
    func atomCandidates() -> [(span: Span, element: CriticalElement)] {
        var result: [(Span, CriticalElement)] = []
        let empty = emptySpan
        for a in first.removedNodes.sorted() {
            for b in second.graph.nodes.indices where criticalNodes?.contains(b) ?? true {
                guard canPair(node: a, with: b, in: empty) else { continue }
                var span = empty
                span.pair(node: a, with: b)
                let overlap = ElementOverlap(first: .node(first.graph.nodes[a].id), second: .node(second.graph.nodes[b].id))
                result.append((span, CriticalElement(kind: removalKind, overlap: overlap)))
            }
        }
        for a in first.removedEdges.sorted() {
            let edge = first.graph.edges[a]
            guard !first.removedNodes.contains(edge.source), !first.removedNodes.contains(edge.target) else { continue }
            for b in second.graph.edges.indices where criticalEdges?.contains(b) ?? true {
                guard let span = pairing(edge: a, with: b, in: empty) else { continue }
                let overlap = ElementOverlap(first: edge.element, second: second.graph.edges[b].element)
                result.append((span, CriticalElement(kind: removalKind, overlap: overlap)))
            }
        }
        for a in changed.keys.sorted() {
            for b in second.graph.nodes.indices {
                let features = (changed[a] ?? []).intersection(used[b] ?? [])
                guard !features.isEmpty, canPair(node: a, with: b, in: empty) else { continue }
                var span = empty
                span.pair(node: a, with: b)
                for feature in features.sorted() {
                    let overlap = ElementOverlap(
                        first: .attribute(node: first.graph.nodes[a].id, feature: feature),
                        second: .attribute(node: second.graph.nodes[b].id, feature: feature))
                    result.append((span, CriticalElement(kind: changeKind, overlap: overlap)))
                }
            }
        }
        return result
    }

    // MARK: - Reporting

    /// The public form of a span.
    func publicSpan(_ span: Span) -> OverlapSpan {
        var nodes: [ElementOverlap] = []
        var edges: [ElementOverlap] = []
        for (a, image) in span.firstNodes.enumerated() {
            if let b = image { nodes.append(ElementOverlap(first: .node(first.graph.nodes[a].id), second: .node(second.graph.nodes[b].id))) }
        }
        for (a, image) in span.firstEdges.enumerated() {
            if let b = image { edges.append(ElementOverlap(first: first.graph.edges[a].element, second: second.graph.edges[b].element)) }
        }
        return OverlapSpan(firstGraph: first.role, secondGraph: second.role, nodes: nodes, edges: edges)
    }

    /// Whether every identification of a span causes the interaction or is an end node of an
    /// edge that does.
    func isEssential(_ span: Span) -> Bool {
        var essentialNodes = Set<Int>()
        for (a, image) in span.firstNodes.enumerated() {
            guard let b = image else { continue }
            let removed = first.removedNodes.contains(a) && (criticalNodes?.contains(b) ?? true)
            let changes = !(changed[a] ?? []).isDisjoint(with: used[b] ?? [])
            if removed || changes { essentialNodes.insert(a) }
        }
        for (a, image) in span.firstEdges.enumerated() {
            guard let b = image else { continue }
            guard first.removedEdges.contains(a), criticalEdges?.contains(b) ?? true else { return false }
            essentialNodes.insert(first.graph.edges[a].source)
            essentialNodes.insert(first.graph.edges[a].target)
        }
        return span.firstNodes.enumerated().allSatisfy { $0.element == nil || essentialNodes.contains($0.offset) }
    }
}
