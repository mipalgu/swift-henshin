//
//  InteractionResults.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import Henshin

/// Whether an analysis looks for conflicts or for dependencies between two rules.
public enum InteractionDirection: String, Sendable, Hashable, CaseIterable {
    /// Applying the first rule may disable the second.
    case conflict
    /// Applying the first rule may enable the second.
    case dependency
}

/// The reason why one rule application interferes with another.
///
/// The first four kinds are conflicts: the first rule, applied first, disables a match of
/// the second rule. The others are dependencies: the first rule, applied first, enables a
/// match of the second. A change of an attribute value can cause both.
public enum InteractionKind: String, Sendable, Hashable, CaseIterable, Comparable, CustomStringConvertible {
    /// The first rule deletes a node or edge that the second rule matches (conflict).
    case deleteUse = "delete-use"
    /// The first rule creates a node or edge that a negative application condition of the
    /// second rule forbids (conflict).
    case produceForbid = "produce-forbid"
    /// The first rule changes an attribute value that the second rule reads or changes
    /// (conflict or dependency).
    case changeUse = "change-use"
    /// The first rule changes an attribute value that a negative application condition of
    /// the second rule tests (conflict or dependency).
    case changeForbid = "change-forbid"
    /// The first rule creates a node or edge that the second rule matches (dependency).
    case produceUse = "produce-use"
    /// The first rule deletes a node or edge whose presence a negative application
    /// condition of the second rule forbids (dependency).
    case deleteForbid = "delete-forbid"

    /// The name of the kind, such as `delete-use`.
    public var description: String { rawValue }

    /// Orders kinds by their declaration.
    ///
    /// - Parameters:
    ///   - lhs: The first kind.
    ///   - rhs: The second kind.
    /// - Returns: `true` if the first kind is declared before the second.
    public static func < (lhs: InteractionKind, rhs: InteractionKind) -> Bool {
        let order = allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// How finely an analysis describes the interactions of two rules.
///
/// The levels follow Born, Lambers, Strüber and Taentzer, "Granularity of conflicts and
/// dependencies in graph transformation systems" (FASE 2017). Each level includes the
/// results of the coarser levels before it.
public enum AnalysisGranularity: Int, Sendable, Hashable, CaseIterable, Comparable, CustomStringConvertible {
    /// Only whether the rules interact at all, decided as soon as one interaction is found.
    case binary
    /// The conflict or dependency atoms: single overlapped elements that lie in some minimal
    /// reason.
    case atoms
    /// The atoms and the minimal conflict or dependency reasons.
    case minimalReasons
    /// The atoms, the minimal reasons and all critical pairs, each with its overlap graph and
    /// the matches of both rules.
    case criticalPairs

    /// The name of the level, such as `minimal-reasons`.
    public var description: String {
        switch self {
        case .binary: return "binary"
        case .atoms: return "atoms"
        case .minimalReasons: return "minimal-reasons"
        case .criticalPairs: return "critical-pairs"
        }
    }

    /// Finds a level by its name, as given by ``description``.
    ///
    /// - Parameter name: The name of the level.
    /// - Returns: The level, or `nil` if no level has the name.
    public init?(name: String) {
        guard let level = Self.allCases.first(where: { $0.description == name }) else { return nil }
        self = level
    }

    /// Orders levels from coarse to fine.
    ///
    /// - Parameters:
    ///   - lhs: The first level.
    ///   - rhs: The second level.
    /// - Returns: `true` if the first level is coarser than the second.
    public static func < (lhs: AnalysisGranularity, rhs: AnalysisGranularity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A graph of a rule that an overlap refers to.
public enum RuleGraphRole: Sendable, Hashable, CustomStringConvertible {
    /// The left-hand side, together with the conclusions of positive application conditions
    /// where these were merged into it.
    case leftHandSide
    /// The right-hand side.
    case rightHandSide
    /// The conclusion of a negative application condition, by position among the rule's
    /// negative conditions.
    case negativeCondition(index: Int, name: String?)

    /// A short description, such as `LHS`, `RHS` or `NAC 0 (linked)`.
    public var description: String {
        switch self {
        case .leftHandSide: return "LHS"
        case .rightHandSide: return "RHS"
        case .negativeCondition(let index, let name):
            return name.map { "NAC \(index) (\($0))" } ?? "NAC \(index)"
        }
    }
}

/// An element of a rule graph: a node, an edge or an attribute of a node.
public enum RuleElement: Sendable, Hashable, CustomStringConvertible {
    /// A node, by identity.
    case node(NodeID)
    /// An edge, as written in the rule: its source node, reference and target node.
    case edge(source: NodeID, reference: String, target: NodeID)
    /// An attribute of a node.
    case attribute(node: NodeID, feature: String)

    /// A description such as `#3`, `#3-next->#4` or `#3.marked`.
    public var description: String {
        switch self {
        case .node(let id): return id.description
        case .edge(let source, let reference, let target): return "\(source)-\(reference)->\(target)"
        case .attribute(let node, let feature): return "\(node).\(feature)"
        }
    }
}

/// Two elements, one of each rule, that an overlap identifies.
public struct ElementOverlap: Sendable, Hashable, CustomStringConvertible {
    /// The element of the first rule.
    public let first: RuleElement

    /// The element of the second rule.
    public let second: RuleElement

    /// Creates an element overlap.
    ///
    /// - Parameters:
    ///   - first: The element of the first rule.
    ///   - second: The element of the second rule.
    public init(first: RuleElement, second: RuleElement) {
        self.first = first
        self.second = second
    }

    /// A description such as `#3=#7`.
    public var description: String { "\(first)=\(second)" }
}

/// A partial identification of a graph of the first rule with a graph of the second rule.
///
/// In categorical terms, it is the span between the two graphs whose apex holds the
/// identified nodes and edges.
public struct OverlapSpan: Sendable, Hashable, CustomStringConvertible {
    /// The graph of the first rule.
    public let firstGraph: RuleGraphRole

    /// The graph of the second rule.
    public let secondGraph: RuleGraphRole

    /// The identified nodes.
    public let nodes: [ElementOverlap]

    /// The identified edges.
    public let edges: [ElementOverlap]

    /// Creates a span.
    ///
    /// - Parameters:
    ///   - firstGraph: The graph of the first rule.
    ///   - secondGraph: The graph of the second rule.
    ///   - nodes: The identified nodes.
    ///   - edges: The identified edges.
    public init(firstGraph: RuleGraphRole, secondGraph: RuleGraphRole, nodes: [ElementOverlap], edges: [ElementOverlap]) {
        self.firstGraph = firstGraph
        self.secondGraph = secondGraph
        self.nodes = nodes
        self.edges = edges
    }

    /// The number of identified nodes and edges.
    public var size: Int { nodes.count + edges.count }

    /// A description listing the graphs and the identified elements.
    public var description: String {
        let elements = (nodes + edges).map(\.description).joined(separator: ", ")
        return "\(firstGraph)~\(secondGraph) {\(elements)}"
    }
}

/// An element that causes an interaction, together with its kind.
public struct CriticalElement: Sendable, Hashable, CustomStringConvertible {
    /// The kind of interaction that the element causes.
    public let kind: InteractionKind

    /// The overlapped elements of both rules.
    public let overlap: ElementOverlap

    /// Creates a critical element.
    ///
    /// - Parameters:
    ///   - kind: The kind of interaction.
    ///   - overlap: The overlapped elements.
    public init(kind: InteractionKind, overlap: ElementOverlap) {
        self.kind = kind
        self.overlap = overlap
    }

    /// A description such as `delete-use #3=#7`.
    public var description: String { "\(kind) \(overlap)" }
}

/// A conflict or dependency atom: the smallest building block of an interaction.
///
/// An atom identifies one element that the first rule deletes, creates or changes with one
/// element that the second rule uses or forbids, together with the end nodes of an edge,
/// and lies in at least one minimal reason.
public struct InteractionAtom: Sendable, Hashable, CustomStringConvertible {
    /// The element that causes the interaction.
    public let element: CriticalElement

    /// The span of the atom: the element and, for an edge, its end nodes.
    public let span: OverlapSpan

    /// The number of minimal reasons that contain the atom.
    public let minimalReasonCount: Int

    /// Creates an atom.
    ///
    /// - Parameters:
    ///   - element: The element that causes the interaction.
    ///   - span: The span of the atom.
    ///   - minimalReasonCount: The number of minimal reasons that contain it.
    public init(element: CriticalElement, span: OverlapSpan, minimalReasonCount: Int) {
        self.element = element
        self.span = span
        self.minimalReasonCount = minimalReasonCount
    }

    /// The kind of the atom.
    public var kind: InteractionKind { element.kind }

    /// A description of the atom.
    public var description: String { "\(element) in \(minimalReasonCount) minimal reason(s)" }
}

/// A minimal conflict or dependency reason.
///
/// A reason is an overlap of the two rules that contains at least one critical element and
/// at which both rules are applicable to the overlap graph, so that the dangling condition
/// and, where they can be decided, the negative application conditions hold. A reason is
/// minimal if no smaller overlap is a reason.
public struct InteractionReason: Sendable, Hashable, CustomStringConvertible {
    /// The kinds of interaction that the reason shows, in order.
    public let kinds: [InteractionKind]

    /// The overlap.
    public let span: OverlapSpan

    /// The elements of the overlap that cause the interaction.
    public let criticalElements: [CriticalElement]

    /// Creates a reason.
    ///
    /// - Parameters:
    ///   - kinds: The kinds of interaction.
    ///   - span: The overlap.
    ///   - criticalElements: The elements that cause the interaction.
    public init(kinds: [InteractionKind], span: OverlapSpan, criticalElements: [CriticalElement]) {
        self.kinds = kinds
        self.span = span
        self.criticalElements = criticalElements
    }

    /// A description listing the kinds and the overlap.
    public var description: String { "\(kinds.map(\.description).joined(separator: "+")) \(span)" }
}

/// A node of an overlap graph.
public struct OverlapNode: Sendable, Hashable {
    /// The name of the class of the node: the more specific class of the overlapped nodes.
    public let typeName: String

    /// The node of the first rule that the node stands for, if any.
    public let first: NodeID?

    /// The node of the second rule that the node stands for, if any.
    public let second: NodeID?

    /// Creates an overlap node.
    ///
    /// - Parameters:
    ///   - typeName: The name of the class of the node.
    ///   - first: The node of the first rule, if any.
    ///   - second: The node of the second rule, if any.
    public init(typeName: String, first: NodeID?, second: NodeID?) {
        self.typeName = typeName
        self.first = first
        self.second = second
    }
}

/// An edge of an overlap graph.
public struct OverlapEdge: Sendable, Hashable {
    /// The position of the source node in the overlap graph.
    public let source: Int

    /// The name of the reference, in the canonical orientation of the analysis.
    public let reference: String

    /// The position of the target node in the overlap graph.
    public let target: Int

    /// Whether the edge stands for an edge of the first rule.
    public let fromFirst: Bool

    /// Whether the edge stands for an edge of the second rule.
    public let fromSecond: Bool

    /// Creates an overlap edge.
    ///
    /// - Parameters:
    ///   - source: The position of the source node.
    ///   - reference: The name of the reference.
    ///   - target: The position of the target node.
    ///   - fromFirst: Whether the edge comes from the first rule.
    ///   - fromSecond: Whether the edge comes from the second rule.
    public init(source: Int, reference: String, target: Int, fromFirst: Bool, fromSecond: Bool) {
        self.source = source
        self.reference = reference
        self.target = target
        self.fromFirst = fromFirst
        self.fromSecond = fromSecond
    }
}

/// The graph that glues two rule graphs along an overlap: the minimal context of a critical
/// pair.
public struct OverlapGraph: Sendable, Hashable {
    /// The nodes.
    public let nodes: [OverlapNode]

    /// The edges.
    public let edges: [OverlapEdge]

    /// Creates an overlap graph.
    ///
    /// - Parameters:
    ///   - nodes: The nodes.
    ///   - edges: The edges.
    public init(nodes: [OverlapNode], edges: [OverlapEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// A critical pair: two rule applications to a minimal model that interact.
///
/// The overlap graph is the minimal context. For a delete-use conflict it is the model to
/// which both rules are applied; for a produce-use dependency, the model that the first rule
/// produces and to which the second is applied; for the conditions of the second rule,
/// the model in which the condition is matched.
public struct CriticalPair: Sendable, Hashable, CustomStringConvertible {
    /// The kinds of interaction of the pair, in order.
    public let kinds: [InteractionKind]

    /// The overlap of the two rule graphs.
    public let span: OverlapSpan

    /// The overlap graph.
    public let graph: OverlapGraph

    /// The match of the first rule's graph in the overlap graph, by node identity.
    public let firstMatch: [NodeID: Int]

    /// The match of the second rule's graph in the overlap graph, by node identity.
    public let secondMatch: [NodeID: Int]

    /// The elements of the overlap that cause the interaction.
    public let criticalElements: [CriticalElement]

    /// Whether the pair is essential: every overlapped element causes the interaction or is
    /// an end node of an edge that does (Lambers, Ehrig and Orejas, 2008).
    public let isEssential: Bool

    /// Creates a critical pair.
    ///
    /// - Parameters:
    ///   - kinds: The kinds of interaction.
    ///   - span: The overlap.
    ///   - graph: The overlap graph.
    ///   - firstMatch: The match of the first rule.
    ///   - secondMatch: The match of the second rule.
    ///   - criticalElements: The elements that cause the interaction.
    ///   - isEssential: Whether the pair is essential.
    public init(
        kinds: [InteractionKind], span: OverlapSpan, graph: OverlapGraph, firstMatch: [NodeID: Int],
        secondMatch: [NodeID: Int], criticalElements: [CriticalElement], isEssential: Bool
    ) {
        self.kinds = kinds
        self.span = span
        self.graph = graph
        self.firstMatch = firstMatch
        self.secondMatch = secondMatch
        self.criticalElements = criticalElements
        self.isEssential = isEssential
    }

    /// A description listing the kinds, whether the pair is essential and the overlap.
    public var description: String {
        "\(kinds.map(\.description).joined(separator: "+"))\(isEssential ? " (essential)" : "") \(span)"
    }
}

/// The interactions of an ordered pair of rules.
public struct RulePairInteraction: Sendable, CustomStringConvertible {
    /// Whether the analysis looked for conflicts or dependencies.
    public let direction: InteractionDirection

    /// The name of the rule applied first.
    public let firstRule: String

    /// The name of the rule whose applicability the first rule changes.
    public let secondRule: String

    /// The granularity of the analysis.
    public let granularity: AnalysisGranularity

    /// Whether the rules interact: the first may disable (conflict) or enable (dependency)
    /// the second.
    public let interacts: Bool

    /// The kinds of interaction found, in order.
    ///
    /// At ``AnalysisGranularity/binary`` granularity this holds the kind of the first
    /// interaction found only.
    public let kinds: [InteractionKind]

    /// The atoms, from ``AnalysisGranularity/atoms`` granularity on.
    public let atoms: [InteractionAtom]

    /// The minimal reasons, from ``AnalysisGranularity/minimalReasons`` granularity on.
    public let minimalReasons: [InteractionReason]

    /// The critical pairs, at ``AnalysisGranularity/criticalPairs`` granularity.
    public let criticalPairs: [CriticalPair]

    /// Whether a limit of the analysis options cut the list of critical pairs short.
    public let isTruncated: Bool

    /// What the analysis approximated, such as conditions that it could not take into
    /// account.
    public let notes: [String]

    /// Creates the interactions of a rule pair.
    ///
    /// - Parameters:
    ///   - direction: Whether conflicts or dependencies were analysed.
    ///   - firstRule: The name of the rule applied first.
    ///   - secondRule: The name of the other rule.
    ///   - granularity: The granularity of the analysis.
    ///   - interacts: Whether the rules interact.
    ///   - kinds: The kinds of interaction found.
    ///   - atoms: The atoms.
    ///   - minimalReasons: The minimal reasons.
    ///   - criticalPairs: The critical pairs.
    ///   - isTruncated: Whether a limit cut the critical pairs short.
    ///   - notes: What the analysis approximated.
    public init(
        direction: InteractionDirection, firstRule: String, secondRule: String, granularity: AnalysisGranularity,
        interacts: Bool, kinds: [InteractionKind], atoms: [InteractionAtom], minimalReasons: [InteractionReason],
        criticalPairs: [CriticalPair], isTruncated: Bool, notes: [String]
    ) {
        self.direction = direction
        self.firstRule = firstRule
        self.secondRule = secondRule
        self.granularity = granularity
        self.interacts = interacts
        self.kinds = kinds
        self.atoms = atoms
        self.minimalReasons = minimalReasons
        self.criticalPairs = criticalPairs
        self.isTruncated = isTruncated
        self.notes = notes
    }

    /// A multi-line report of the interactions.
    public var description: String {
        let verb = direction == .conflict ? "conflicts with" : "enables"
        guard interacts else {
            let negated = direction == .conflict ? "does not conflict with" : "does not enable"
            return (["\(firstRule) \(negated) \(secondRule)"] + notes.map { "  note: \($0)" }).joined(separator: "\n")
        }
        var lines = ["\(firstRule) \(verb) \(secondRule): \(kinds.map(\.description).joined(separator: ", "))"]
        if granularity >= .atoms {
            lines.append("  atoms: \(atoms.count)")
            lines += atoms.map { "    \($0)" }
        }
        if granularity >= .minimalReasons {
            lines.append("  minimal reasons: \(minimalReasons.count)")
            lines += minimalReasons.map { "    \($0)" }
        }
        if granularity >= .criticalPairs {
            lines.append("  critical pairs: \(criticalPairs.count)\(isTruncated ? " (truncated)" : "")")
            lines += criticalPairs.map { "    \($0)" }
        }
        lines += notes.map { "  note: \($0)" }
        return lines.joined(separator: "\n")
    }
}

/// The interactions of every ordered pair of a list of rules.
public struct InteractionTable: Sendable, CustomStringConvertible {
    /// Whether the table lists conflicts or dependencies.
    public let direction: InteractionDirection

    /// The names of the rules, in order.
    public let rules: [String]

    /// The interactions of each ordered pair, by row (first rule) and column (second rule).
    public let pairs: [[RulePairInteraction]]

    /// Creates a table.
    ///
    /// - Parameters:
    ///   - direction: Whether the table lists conflicts or dependencies.
    ///   - rules: The names of the rules.
    ///   - pairs: The interactions by first and second rule.
    public init(direction: InteractionDirection, rules: [String], pairs: [[RulePairInteraction]]) {
        self.direction = direction
        self.rules = rules
        self.pairs = pairs
    }

    /// The interactions of two rules, by name.
    ///
    /// - Parameters:
    ///   - first: The name of the rule applied first.
    ///   - second: The name of the other rule.
    /// - Returns: The interactions, or `nil` if the table does not hold one of the rules.
    public func interaction(first: String, second: String) -> RulePairInteraction? {
        guard let row = rules.firstIndex(of: first), let column = rules.firstIndex(of: second) else { return nil }
        return pairs[row][column]
    }

    /// The pairs of rules that interact, in row order.
    public var interactingPairs: [RulePairInteraction] { pairs.flatMap { $0 }.filter(\.interacts) }

    /// A matrix of the number of minimal reasons (or `x` for an interaction found at binary
    /// granularity, `.` for none), one row per first rule.
    public var description: String {
        let width = max(rules.map(\.count).max() ?? 0, 1)
        func pad(_ text: String) -> String { text + String(repeating: " ", count: max(width - text.count, 0)) }
        var lines = [pad("") + " | " + rules.indices.map { "\($0)" }.joined(separator: " ")]
        for (row, name) in rules.enumerated() {
            let cells = pairs[row].map { pair -> String in
                guard pair.interacts else { return "." }
                if pair.granularity >= .minimalReasons { return "\(pair.minimalReasons.count)" }
                if pair.granularity >= .atoms { return "\(pair.atoms.count)" }
                return "x"
            }
            lines.append(pad(name) + " | " + cells.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
