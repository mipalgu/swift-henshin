//
//  RuleGraph.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore

/// The identity of a node of a rule graph.
///
/// Mappings, edges and parameters refer to nodes by identity, so that a node of a
/// left-hand side, a right-hand side or the conclusion of a nested condition can be told
/// apart even when nodes share a name. Identities are unique within a ``HenshinModule``;
/// the module reader assigns them in document order.
public struct NodeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The number that identifies the node.
    public let rawValue: Int

    /// Creates a node identity.
    ///
    /// - Parameter rawValue: The number that identifies the node; it must be unique within
    ///   the module that holds the node.
    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Orders node identities by their numbers.
    ///
    /// - Parameters:
    ///   - lhs: The first identity.
    ///   - rhs: The second identity.
    /// - Returns: `true` if the first identity comes before the second.
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The number of the node, prefixed with `#`.
    public var description: String { "#\(rawValue)" }
}

/// A node of a rule graph: a placeholder for a model object of a given class.
///
/// A node matches an object whose class is the node's type or a subclass of it. Its
/// attributes constrain or assign attribute values of that object.
public struct RuleNode: Sendable, Identifiable {
    /// The identity of the node within its module.
    public let id: NodeID

    /// The name of the node, if it has one.
    ///
    /// A node whose name equals the name of a rule parameter is bound to that parameter:
    /// the parameter passes the matched object in or out of the rule.
    public var name: String?

    /// The class of the objects that the node matches or creates.
    public var type: EClass

    /// The attribute constraints or assignments of the node.
    public var attributes: [RuleAttribute]

    /// Creates a node.
    ///
    /// - Parameters:
    ///   - id: The identity of the node within its module.
    ///   - name: The name of the node, if any.
    ///   - type: The class of the objects that the node stands for.
    ///   - attributes: The attribute constraints or assignments of the node.
    public init(id: NodeID, name: String? = nil, type: EClass, attributes: [RuleAttribute] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.attributes = attributes
    }

    /// Finds the attribute of the node that refers to a feature.
    ///
    /// - Parameter featureName: The name of the attribute feature.
    /// - Returns: The node attribute, or `nil` if the node has none for the feature.
    public func attribute(named featureName: String) -> RuleAttribute? {
        attributes.first { $0.feature.name == featureName }
    }
}

/// An attribute of a rule node: a value expression for one attribute feature.
///
/// In a left-hand side or a condition, the expression constrains the attribute value of the
/// matched object. In a right-hand side, an expression that differs from that of the
/// left-hand side assigns the value. The expression is written in the JavaScript subset
/// that ``JavaScriptTranslator`` translates into the Acceleo Query Language.
public struct RuleAttribute: Sendable {
    /// The attribute feature that the expression refers to.
    public var feature: EAttribute

    /// The value expression, as written in the Henshin document.
    public var value: String

    /// Creates a node attribute.
    ///
    /// - Parameters:
    ///   - feature: The attribute feature that the expression refers to.
    ///   - value: The value expression.
    public init(feature: EAttribute, value: String) {
        self.feature = feature
        self.value = value
    }
}

/// An edge of a rule graph: a placeholder for a reference between two model objects.
public struct RuleEdge: Sendable {
    /// The node of the referring object.
    public var source: NodeID

    /// The node of the referenced object.
    public var target: NodeID

    /// The reference that the edge stands for.
    public var type: EReference

    /// The position expression of the edge within a many-valued reference, if any.
    ///
    /// Positions are read but not interpreted; see the documentation of the supported
    /// features.
    public var index: String?

    /// Creates an edge.
    ///
    /// - Parameters:
    ///   - source: The node of the referring object.
    ///   - target: The node of the referenced object.
    ///   - type: The reference that the edge stands for.
    ///   - index: The position expression within a many-valued reference, if any.
    public init(source: NodeID, target: NodeID, type: EReference, index: String? = nil) {
        self.source = source
        self.target = target
        self.type = type
        self.index = index
    }
}

/// A graph of a rule: a left-hand side, a right-hand side or the conclusion of a condition.
public struct RuleGraph: Sendable {
    /// The name of the graph, if it has one.
    public var name: String?

    /// The nodes of the graph, in document order.
    public var nodes: [RuleNode]

    /// The edges of the graph, in document order.
    public var edges: [RuleEdge]

    /// The application condition that a match of the graph must satisfy, if any.
    public var formula: Formula?

    /// Creates a graph.
    ///
    /// - Parameters:
    ///   - name: The name of the graph, if any.
    ///   - nodes: The nodes of the graph.
    ///   - edges: The edges between the nodes of the graph.
    ///   - formula: The application condition of the graph, if any.
    public init(name: String? = nil, nodes: [RuleNode] = [], edges: [RuleEdge] = [], formula: Formula? = nil) {
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.formula = formula
    }

    /// Finds a node of the graph by identity.
    ///
    /// - Parameter id: The identity of the node.
    /// - Returns: The node, or `nil` if the graph does not hold it.
    public func node(_ id: NodeID) -> RuleNode? {
        nodes.first { $0.id == id }
    }

    /// Finds a node of the graph by name.
    ///
    /// - Parameter name: The name of the node.
    /// - Returns: The first node with the name, or `nil` if there is none.
    public func node(named name: String) -> RuleNode? {
        nodes.first { $0.name == name }
    }

    /// Whether the graph holds a node.
    ///
    /// - Parameter id: The identity of the node.
    /// - Returns: `true` if the node belongs to this graph.
    public func contains(_ id: NodeID) -> Bool {
        nodes.contains { $0.id == id }
    }
}

/// A mapping from a node of one graph to a node of another.
///
/// Rule mappings lead from the left-hand side to the right-hand side and mark the nodes that
/// a rule preserves. Condition mappings lead from the host graph to the conclusion of a
/// nested condition. Multi-mappings lead from a kernel rule to its multi-rule.
public struct NodeMapping: Sendable, Hashable {
    /// The node that the mapping starts from.
    public var origin: NodeID

    /// The node that the mapping leads to.
    public var image: NodeID

    /// Creates a mapping.
    ///
    /// - Parameters:
    ///   - origin: The node that the mapping starts from.
    ///   - image: The node that the mapping leads to.
    public init(origin: NodeID, image: NodeID) {
        self.origin = origin
        self.image = image
    }
}

/// An application condition over a graph.
///
/// A ``NestedCondition`` holds if its conclusion can be matched in a way that agrees with
/// the match of its host graph. Negating a nested condition gives a negative application
/// condition; a nested condition on its own is a positive application condition.
public indirect enum Formula: Sendable {
    /// The condition that always holds.
    case `true`
    /// A nested graph condition.
    case condition(NestedCondition)
    /// The negation of a formula.
    case not(Formula)
    /// The conjunction of two formulas.
    case and(Formula, Formula)
    /// The disjunction of two formulas.
    case or(Formula, Formula)
    /// The exclusive disjunction of two formulas.
    case xor(Formula, Formula)
}

/// A nested graph condition: the existence of a match of a conclusion graph.
public struct NestedCondition: Sendable {
    /// The graph that must, or must not, be found around the match of the host graph.
    public var conclusion: RuleGraph

    /// The mappings from nodes of the host graph to nodes of the conclusion.
    public var mappings: [NodeMapping]

    /// Creates a nested condition.
    ///
    /// - Parameters:
    ///   - conclusion: The graph that must be found.
    ///   - mappings: The mappings from the host graph to the conclusion.
    public init(conclusion: RuleGraph, mappings: [NodeMapping]) {
        self.conclusion = conclusion
        self.mappings = mappings
    }
}
