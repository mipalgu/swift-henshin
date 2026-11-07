//
//  GluedGraph.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin

/// The graph obtained by gluing two graphs along a span: the pushout of the span.
///
/// Each node remembers the attribute terms of the graphs it comes from, so that a condition
/// of either rule can be checked against it.
struct GluedGraph: Sendable {
    /// A node of the glued graph.
    struct Node: Sendable {
        /// The class of the node: the more specific class of the glued nodes.
        let type: EClass
        /// The node of the first graph, if any.
        let first: Int?
        /// The node of the second graph, if any.
        let second: Int?
        /// The attribute terms of the first graph's node.
        let firstAttributes: [String: AttributeTerm]
        /// The attribute terms of the second graph's node.
        let secondAttributes: [String: AttributeTerm]
    }

    /// A link of the glued graph.
    struct Link: Sendable, Hashable {
        /// The position of the source node.
        let source: Int
        /// The key of the canonical edge type.
        let type: String
        /// The position of the target node.
        let target: Int
    }

    /// The nodes.
    private(set) var nodes: [Node] = []

    /// The links, in canonical orientation.
    private(set) var links: Set<Link> = []

    /// The public edges, in order.
    private(set) var edges: [OverlapEdge] = []

    /// The node of the glued graph that each first-graph node becomes.
    private(set) var firstImage: [Int] = []

    /// The node of the glued graph that each second-graph node becomes.
    private(set) var secondImage: [Int] = []

    /// Glues the graphs of a problem along a span.
    ///
    /// - Parameters:
    ///   - problem: The overlap problem.
    ///   - span: The span.
    init(_ problem: OverlapProblem, _ span: Span) {
        let first = problem.first.graph
        let second = problem.second.graph
        secondImage = Array(repeating: -1, count: second.nodeCount)
        for (a, node) in first.nodes.enumerated() {
            let b = span.firstNodes[a]
            let type = b.map { TypeConformance.meet(node.type, second.nodes[$0].type) } ?? node.type
            nodes.append(
                Node(
                    type: type, first: a, second: b, firstAttributes: node.attributes,
                    secondAttributes: b.map { second.nodes[$0].attributes } ?? [:]))
            firstImage.append(a)
            if let b { secondImage[b] = a }
        }
        for (b, node) in second.nodes.enumerated() where span.secondNodes[b] == nil {
            secondImage[b] = nodes.count
            nodes.append(Node(type: node.type, first: nil, second: b, firstAttributes: [:], secondAttributes: node.attributes))
        }
        for (a, edge) in first.edges.enumerated() {
            links.insert(Link(source: firstImage[edge.source], type: edge.type.key, target: firstImage[edge.target]))
            edges.append(
                OverlapEdge(
                    source: firstImage[edge.source], reference: edge.type.name, target: firstImage[edge.target],
                    fromFirst: true, fromSecond: span.firstEdges[a] != nil))
        }
        for (b, edge) in second.edges.enumerated() where span.secondEdges[b] == nil {
            let link = Link(source: secondImage[edge.source], type: edge.type.key, target: secondImage[edge.target])
            links.insert(link)
            edges.append(
                OverlapEdge(
                    source: link.source, reference: edge.type.name, target: link.target, fromFirst: false, fromSecond: true))
        }
    }

    /// The public overlap graph, naming the rule nodes that each node stands for.
    ///
    /// - Parameter problem: The problem whose graphs were glued.
    /// - Returns: The overlap graph.
    func overlapGraph(of problem: OverlapProblem) -> OverlapGraph {
        OverlapGraph(
            nodes: nodes.map { node in
                OverlapNode(
                    typeName: node.type.name, first: node.first.map { problem.first.graph.nodes[$0].id },
                    second: node.second.map { problem.second.graph.nodes[$0].id })
            }, edges: edges)
    }

    /// Whether a negative condition is matched in the glued graph at the image of its host
    /// graph.
    ///
    /// The search is conservative: a condition node with an attribute counts as matched
    /// only where the glued node is known to have the value, because the rule of the
    /// condition tests the same expression or both are equal literals. A condition that
    /// cannot be shown to match is taken not to match.
    ///
    /// - Parameters:
    ///   - condition: The condition.
    ///   - hostImage: The glued node of each node of the condition's host graph.
    ///   - fromFirst: Whether the condition belongs to the rule of the first graph.
    /// - Returns: `true` if the condition is certainly matched.
    func matches(_ condition: AnalysedCondition, hostImage: [Int], fromFirst: Bool) -> Bool {
        guard !condition.isNested else { return false }
        let graph = condition.graph
        var assignment = Array<Int?>(repeating: nil, count: graph.nodeCount)
        var used = Set<Int>(hostImage)
        for (host, image) in condition.hostMapping {
            assignment[image] = hostImage[host]
        }
        for (position, image) in assignment.enumerated() {
            guard let image else { continue }
            guard entails(nodes[image], graph.nodes[position], fromFirst: fromFirst) else { return false }
        }
        let open = graph.nodes.indices.filter { assignment[$0] == nil }
        func edgesHold(_ assignment: [Int?]) -> Bool {
            for edge in graph.edges {
                guard let source = assignment[edge.source], let target = assignment[edge.target] else { continue }
                if !links.contains(Link(source: source, type: edge.type.key, target: target)) { return false }
            }
            return true
        }
        guard edgesHold(assignment) else { return false }
        func search(_ index: Int) -> Bool {
            guard index < open.count else { return true }
            let position = open[index]
            for candidate in nodes.indices where !used.contains(candidate) {
                guard TypeConformance.conforms(nodes[candidate].type, to: graph.nodes[position].type),
                    entails(nodes[candidate], graph.nodes[position], fromFirst: fromFirst)
                else { continue }
                assignment[position] = candidate
                used.insert(candidate)
                if edgesHold(assignment) && search(index + 1) { return true }
                used.remove(candidate)
                assignment[position] = nil
            }
            return false
        }
        return search(0)
    }

    /// Whether a glued node is known to satisfy the attribute tests of a condition node.
    private func entails(_ node: Node, _ pattern: AnalysisNode, fromFirst: Bool) -> Bool {
        let own = fromFirst ? node.firstAttributes : node.secondAttributes
        let all = [node.firstAttributes, node.secondAttributes]
        for (feature, term) in pattern.attributes {
            if own[feature]?.text == term.text { continue }
            guard let literal = term.literal,
                all.contains(where: { $0[feature]?.literal.map { AttributeTerm.same($0, literal) } ?? false })
            else { return false }
        }
        return true
    }
}
