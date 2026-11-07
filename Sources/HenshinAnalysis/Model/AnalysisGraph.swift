//
//  AnalysisGraph.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin

/// The value of a node attribute, as written and, if it is a literal, as a value.
struct AttributeTerm: Sendable, Hashable {
    /// The expression as written in the rule.
    let text: String

    /// The literal value of the expression, or `nil` if it is not a literal.
    let literal: LiteralValue?

    /// Creates a term from an expression, recognising literals.
    ///
    /// - Parameters:
    ///   - text: The expression.
    ///   - variables: The parameter names of the rule, which are not literals.
    init(_ text: String, variables: Set<String>) {
        self.text = text
        if let translated = try? JavaScriptTranslator(variables: variables).translate(text),
            case .literal(let value) = translated.form
        {
            literal = value
        } else {
            literal = nil
        }
    }

    /// Whether two terms may denote the same value.
    ///
    /// Only two different literals are known to differ; any other pair may agree once
    /// parameters are bound.
    ///
    /// - Parameter other: The other term.
    /// - Returns: `false` only if both terms are literals with different values.
    func isCompatible(with other: AttributeTerm) -> Bool {
        guard let literal, let otherLiteral = other.literal else { return true }
        return Self.same(literal, otherLiteral)
    }

    /// Whether two literals denote the same value, comparing integers and reals numerically.
    static func same(_ lhs: LiteralValue, _ rhs: LiteralValue) -> Bool {
        switch (lhs, rhs) {
        case (.integer(let l), .real(let r)), (.real(let r), .integer(let l)): return Double(l) == r
        default: return lhs == rhs
        }
    }
}

/// The type of an edge in canonical orientation.
///
/// A reference and its opposite describe the same link between two objects, so an edge is
/// stored in the orientation of one of the two, called the canonical reference: the
/// containment reference if there is one, and otherwise the reference whose name and target
/// class come first.
struct EdgeType: Sendable, Hashable {
    /// The key that identifies the link type.
    let key: String

    /// The name of the canonical reference.
    let name: String

    /// Whether the canonical reference is a containment reference.
    let isContainment: Bool

    /// Whether an object refers to at most one object through the canonical reference.
    let sourceUnique: Bool

    /// Whether an object is referred to by at most one object through the canonical
    /// reference, because the opposite is single-valued or the reference contains it.
    let targetUnique: Bool
}

/// A node of an analysis graph.
struct AnalysisNode: Sendable {
    /// The identity of the rule node.
    let id: NodeID

    /// The class of the node.
    let type: EClass

    /// The attribute terms of the node, by feature name.
    let attributes: [String: AttributeTerm]
}

/// An edge of an analysis graph, in canonical orientation.
struct AnalysisEdge: Sendable {
    /// The position of the source node.
    let source: Int

    /// The position of the target node.
    let target: Int

    /// The canonical type of the edge.
    let type: EdgeType

    /// The edge as written in the rule.
    let element: RuleElement
}

/// A rule graph prepared for overlapping: nodes by position and edges in canonical form.
struct AnalysisGraph: Sendable {
    /// The nodes, in the order of the rule graph.
    private(set) var nodes: [AnalysisNode] = []

    /// The edges, in the order of the rule graph.
    private(set) var edges: [AnalysisEdge] = []

    /// The positions of the nodes by identity.
    private(set) var positions: [NodeID: Int] = [:]

    /// The positions of the edges that start at each node.
    private(set) var outgoing: [[Int]] = []

    /// The positions of the edges that end at each node.
    private(set) var incoming: [[Int]] = []

    /// Creates the analysis graph of a rule graph.
    ///
    /// - Parameters:
    ///   - graph: The rule graph.
    ///   - variables: The parameter names of the rule.
    ///   - inherited: Attribute terms that nodes take over unless they give their own, by
    ///     node identity.
    init(_ graph: RuleGraph, variables: Set<String>, inherited: [NodeID: [String: AttributeTerm]] = [:]) {
        for node in graph.nodes {
            var attributes = inherited[node.id] ?? [:]
            for attribute in node.attributes {
                attributes[attribute.feature.name] = AttributeTerm(attribute.value, variables: variables)
            }
            addNode(AnalysisNode(id: node.id, type: node.type, attributes: attributes))
        }
        for edge in graph.edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else { continue }
            addEdge(source: source, target: target, reference: edge.type, sourceType: nodes[source].type)
        }
    }

    /// The number of nodes.
    var nodeCount: Int { nodes.count }

    /// The number of edges.
    var edgeCount: Int { edges.count }

    /// Adds a node.
    ///
    /// - Parameter node: The node.
    /// - Returns: The position of the node.
    @discardableResult
    mutating func addNode(_ node: AnalysisNode) -> Int {
        let position = nodes.count
        nodes.append(node)
        positions[node.id] = position
        outgoing.append([])
        incoming.append([])
        return position
    }

    /// Adds an edge for a reference between two nodes, in canonical orientation.
    ///
    /// - Parameters:
    ///   - source: The position of the referring node.
    ///   - target: The position of the referenced node.
    ///   - reference: The reference.
    ///   - sourceType: The class of the referring node.
    mutating func addEdge(source: Int, target: Int, reference: EReference, sourceType: EClass) {
        let element = RuleElement.edge(source: nodes[source].id, reference: reference.name, target: nodes[target].id)
        let (type, flipped) = Self.canonicalType(of: reference, sourceType: sourceType)
        let edge = AnalysisEdge(
            source: flipped ? target : source, target: flipped ? source : target, type: type, element: element)
        let position = edges.count
        edges.append(edge)
        outgoing[edge.source].append(position)
        incoming[edge.target].append(position)
    }

    /// The positions of the edges that touch a node, outgoing first.
    ///
    /// - Parameter node: The position of the node.
    /// - Returns: The edge positions; a loop appears once.
    func incident(_ node: Int) -> [Int] {
        var result = outgoing[node]
        for edge in incoming[node] where !result.contains(edge) { result.append(edge) }
        return result
    }

    /// The position of a node by identity.
    ///
    /// - Parameter id: The identity of the node.
    /// - Returns: The position, or `nil` if the graph does not hold the node.
    func position(of id: NodeID) -> Int? { positions[id] }

    /// The canonical type of a reference and whether edges of the reference are reversed.
    ///
    /// - Parameters:
    ///   - reference: The reference.
    ///   - sourceType: The class of the referring node, used to find the opposite.
    /// - Returns: The canonical edge type and whether the canonical orientation is the
    ///   reverse of the reference.
    static func canonicalType(of reference: EReference, sourceType: EClass) -> (EdgeType, Bool) {
        let targetClass = reference.eType as? EClass
        let opposite = reference.opposite.flatMap { id in targetClass?.eAllReferences.first { $0.id == id } }
        guard let opposite else {
            return (
                EdgeType(
                    key: key(of: reference), name: reference.name, isContainment: reference.containment,
                    sourceUnique: !reference.isMany, targetUnique: reference.containment),
                false
            )
        }
        let keepsOrientation: Bool
        if reference.containment != opposite.containment {
            keepsOrientation = reference.containment
        } else {
            let own = key(of: reference)
            let other = key(of: opposite)
            keepsOrientation = own == other ? reference.id.description <= opposite.id.description : own < other
        }
        let canonical = keepsOrientation ? reference : opposite
        let reverse = keepsOrientation ? opposite : reference
        return (
            EdgeType(
                key: key(of: canonical), name: canonical.name, isContainment: canonical.containment,
                sourceUnique: !canonical.isMany, targetUnique: canonical.containment || !reverse.isMany),
            !keepsOrientation
        )
    }

    /// The key of a reference: its name and the name of its target class.
    static func key(of reference: EReference) -> String {
        "\(reference.name)->\(reference.eType.name)"
    }
}

/// Decides whether classes conform to one another, by identity or name.
enum TypeConformance {
    /// Whether a class is a type or one of its subclasses.
    ///
    /// - Parameters:
    ///   - eClass: The class.
    ///   - type: The type.
    /// - Returns: `true` if the class conforms to the type.
    static func conforms(_ eClass: EClass, to type: EClass) -> Bool {
        same(eClass, type) || eClass.eAllSuperTypes.contains { same($0, type) }
    }

    /// Whether two classes can describe the same object: one conforms to the other.
    static func compatible(_ lhs: EClass, _ rhs: EClass) -> Bool {
        conforms(lhs, to: rhs) || conforms(rhs, to: lhs)
    }

    /// The more specific of two compatible classes.
    static func meet(_ lhs: EClass, _ rhs: EClass) -> EClass {
        conforms(lhs, to: rhs) ? lhs : rhs
    }

    /// Whether two classes are the same, by identity or name.
    static func same(_ lhs: EClass, _ rhs: EClass) -> Bool {
        lhs.id == rhs.id || lhs.name == rhs.name
    }
}
