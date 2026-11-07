//
//  CompiledRule.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// A constraint on an attribute of the object that a pattern node matches.
struct AttributeCheck: Sendable {
    /// The attribute.
    let feature: EAttribute
    /// The expression that the attribute value must equal.
    let expression: CompiledExpression
}

/// A node of a pattern to be matched.
struct PatternNode: Sendable {
    /// The rule node that the pattern node stands for.
    let id: NodeID
    /// The type of the objects that the node matches.
    let type: EClass
    /// The attribute constraints of the node.
    let attributes: [AttributeCheck]
    /// The rule parameter that shares the node's name, if any.
    ///
    /// When the parameter holds an object, the node matches only that object; when it is
    /// unbound, matching binds it to the matched object. A parameter that holds any other
    /// value, such as a name, does not constrain the node.
    let parameter: String?
}

/// An edge of a pattern, between nodes given by their positions in the pattern.
struct PatternEdge: Sendable, Hashable {
    /// The position of the source node.
    let source: Int
    /// The position of the target node.
    let target: Int
    /// The name of the reference.
    let reference: String
}

/// A pair of node positions that a mapping connects.
struct PositionMapping: Sendable, Hashable {
    /// The position of the node in the host or kernel pattern.
    let host: Int
    /// The position of the node in the conclusion or multi-rule pattern.
    let image: Int
}

/// An application condition in compiled form.
indirect enum CompiledFormula: Sendable {
    /// The condition that always holds.
    case `true`
    /// A nested graph condition.
    case condition(CompiledCondition)
    /// Negation.
    case not(CompiledFormula)
    /// Conjunction.
    case and(CompiledFormula, CompiledFormula)
    /// Disjunction.
    case or(CompiledFormula, CompiledFormula)
    /// Exclusive disjunction.
    case xor(CompiledFormula, CompiledFormula)
}

/// A nested condition in compiled form.
struct CompiledCondition: Sendable {
    /// The pattern of the conclusion.
    let pattern: CompiledPattern
    /// The mappings from the host pattern to the conclusion pattern.
    let mappings: [PositionMapping]
}

/// A graph to be matched: its nodes, edges and application condition.
struct CompiledPattern: Sendable {
    /// The nodes, in the order of the rule graph.
    let nodes: [PatternNode]
    /// The edges between the nodes.
    let edges: [PatternEdge]
    /// The application condition of the graph.
    let formula: CompiledFormula
    /// Whether different nodes must match different objects.
    let injective: Bool
    /// The positions of the nodes, by rule node identity.
    let positions: [NodeID: Int]
    /// The edges incident to each node, by node position.
    let incident: [[Int]]

    /// Compiles a rule graph.
    ///
    /// - Parameters:
    ///   - graph: The rule graph.
    ///   - parameters: The parameters of the rule, which expressions may refer to.
    ///   - injective: Whether matching is injective.
    /// - Throws: ``HenshinError`` if an edge leaves the graph or an expression cannot be
    ///   translated.
    init(_ graph: RuleGraph, parameters: [UnitParameter], injective: Bool) throws(HenshinError) {
        let names = Set(parameters.map(\.name))
        var positions: [NodeID: Int] = [:]
        var nodes: [PatternNode] = []
        for (position, node) in graph.nodes.enumerated() {
            positions[node.id] = position
            var checks: [AttributeCheck] = []
            for attribute in node.attributes {
                checks.append(AttributeCheck(feature: attribute.feature, expression: try CompiledExpression(attribute.value, variables: names)))
            }
            let parameter = node.name.flatMap { names.contains($0) ? $0 : nil }
            nodes.append(PatternNode(id: node.id, type: node.type, attributes: checks, parameter: parameter))
        }
        var edges: [PatternEdge] = []
        var incident = Array(repeating: [Int](), count: nodes.count)
        for edge in graph.edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else {
                throw .malformed("edge '\(edge.type.name)' of graph '\(graph.name ?? "")' leaves its graph")
            }
            incident[source].append(edges.count)
            if target != source { incident[target].append(edges.count) }
            edges.append(PatternEdge(source: source, target: target, reference: edge.type.name))
        }
        self.nodes = nodes
        self.edges = edges
        self.positions = positions
        self.incident = incident
        self.injective = injective
        if let formula = graph.formula {
            self.formula = try Self.compile(formula, host: positions, parameters: parameters, injective: injective)
        } else {
            self.formula = .true
        }
    }

    /// Compiles an application condition over a host graph.
    private static func compile(
        _ formula: Formula, host: [NodeID: Int], parameters: [UnitParameter], injective: Bool
    ) throws(HenshinError) -> CompiledFormula {
        switch formula {
        case .true:
            return .true
        case .not(let child):
            return .not(try compile(child, host: host, parameters: parameters, injective: injective))
        case .and(let left, let right):
            return .and(
                try compile(left, host: host, parameters: parameters, injective: injective),
                try compile(right, host: host, parameters: parameters, injective: injective))
        case .or(let left, let right):
            return .or(
                try compile(left, host: host, parameters: parameters, injective: injective),
                try compile(right, host: host, parameters: parameters, injective: injective))
        case .xor(let left, let right):
            return .xor(
                try compile(left, host: host, parameters: parameters, injective: injective),
                try compile(right, host: host, parameters: parameters, injective: injective))
        case .condition(let condition):
            let pattern = try CompiledPattern(condition.conclusion, parameters: parameters, injective: injective)
            var mappings: [PositionMapping] = []
            for mapping in condition.mappings {
                guard let origin = host[mapping.origin], let image = pattern.positions[mapping.image] else {
                    throw .malformed("a mapping of a nested condition does not lead from its host graph to its conclusion")
                }
                mappings.append(PositionMapping(host: origin, image: image))
            }
            return .condition(CompiledCondition(pattern: pattern, mappings: mappings))
        }
    }
}

/// An attribute value that a rule application assigns.
struct AttributeAssignment: Sendable {
    /// The right-hand side node of the object.
    let node: NodeID
    /// The attribute.
    let feature: EAttribute
    /// The expression of the value.
    let expression: CompiledExpression
}

/// An edge that a rule application creates, between right-hand side nodes.
struct CreatedEdge: Sendable {
    /// The right-hand side node of the referring object.
    let source: NodeID
    /// The right-hand side node of the referenced object.
    let target: NodeID
    /// The name of the reference.
    let reference: String
}

/// A rule in the form in which the engine matches and applies it.
struct CompiledRule: Sendable {
    /// The rule.
    let rule: Rule
    /// The pattern of the left-hand side, with its application condition.
    let lhs: CompiledPattern
    /// The conditions on parameter values.
    let conditions: [CompiledExpression]
    /// Whether the dangling condition is checked.
    let checkDangling: Bool
    /// The positions of the left-hand side nodes that the rule deletes.
    let deletedNodes: [Int]
    /// The left-hand side edges that the rule deletes.
    let deletedEdges: [PatternEdge]
    /// The right-hand side nodes that the rule creates.
    let createdNodes: [RuleNode]
    /// The right-hand side nodes that the rule preserves, with their left-hand side positions.
    let preservedNodes: [(rhs: NodeID, lhs: Int)]
    /// For a multi-rule, the right-hand side nodes that stand for nodes of the kernel rule.
    let kernelImages: [(rhs: NodeID, kernel: NodeID)]
    /// The edges that the rule creates.
    let createdEdges: [CreatedEdge]
    /// The attribute values that the rule assigns.
    let assignments: [AttributeAssignment]
    /// The multi-rules, with the positions of their nodes that stand for kernel nodes.
    let multiRules: [(rule: CompiledRule, mappings: [PositionMapping])]
    /// For each deleted node, by position, how many reference ends the rule deletes at it.
    let deletedReferenceEnds: [Int: Int]
    /// The positions of the left-hand side nodes that some multi-rule also refers to.
    let nodesSharedWithMultiRules: Set<Int>

    /// Compiles a rule.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - options: The options that may override the rule's own matching settings.
    ///   - kernel: For a multi-rule, the kernel rule.
    ///   - types: The cache of type and reference information.
    /// - Throws: ``HenshinError`` if the rule is malformed or an expression cannot be
    ///   translated.
    init(_ rule: Rule, options: EngineOptions, kernel: Rule? = nil, types: inout TypeCatalogue) throws(HenshinError) {
        self.rule = rule
        let injective = options.injectiveMatching ?? rule.injectiveMatching
        checkDangling = options.checkDangling ?? rule.checkDangling
        let names = Set(rule.parameters.map(\.name))
        lhs = try CompiledPattern(rule.lhs, parameters: rule.parameters, injective: injective)
        var conditions: [CompiledExpression] = []
        for condition in rule.attributeConditions {
            conditions.append(try CompiledExpression(condition.conditionText, variables: names))
        }
        self.conditions = conditions

        let multiLHSImages = Set(rule.multiMappings.map(\.image).filter { rule.lhs.contains($0) })
        let multiRHSImages = Dictionary(
            rule.multiMappings.filter { rule.rhs.contains($0.image) }.map { ($0.image, $0.origin) },
            uniquingKeysWith: { first, _ in first })

        var deletedNodes: [Int] = []
        for (position, node) in rule.lhs.nodes.enumerated() where rule.image(of: node.id) == nil && !multiLHSImages.contains(node.id) {
            deletedNodes.append(position)
        }
        self.deletedNodes = deletedNodes

        var created: [RuleNode] = []
        var preserved: [(rhs: NodeID, lhs: Int)] = []
        var images: [(rhs: NodeID, kernel: NodeID)] = []
        var assignments: [AttributeAssignment] = []
        for node in rule.rhs.nodes {
            if let kernelNode = multiRHSImages[node.id] {
                images.append((node.id, kernelNode))
                continue
            }
            let origin = rule.origin(of: node.id)
            if let origin {
                guard let position = lhs.positions[origin] else {
                    throw .malformed("rule '\(rule.name)' maps a node from outside its left-hand side")
                }
                preserved.append((node.id, position))
            } else {
                created.append(node)
            }
            let originNode = origin.flatMap { rule.lhs.node($0) }
            for attribute in node.attributes {
                if let previous = originNode?.attribute(named: attribute.feature.name), previous.value == attribute.value {
                    continue
                }
                guard !attribute.feature.derived, attribute.feature.changeable else {
                    throw .malformed("rule '\(rule.name)' assigns the unchangeable attribute '\(attribute.feature.name)'")
                }
                assignments.append(
                    AttributeAssignment(
                        node: node.id, feature: attribute.feature,
                        expression: try CompiledExpression(attribute.value, variables: names)))
            }
        }
        createdNodes = created
        preservedNodes = preserved
        kernelImages = images
        self.assignments = assignments

        let kernelEdges = kernel.map { Self.edgeSet(of: $0) } ?? []
        let mappingOrigin = Dictionary(rule.multiMappings.map { ($0.image, $0.origin) }, uniquingKeysWith: { first, _ in first })
        /// Whether an edge of a multi-rule stands for an edge of its kernel rule.
        func sharedWithKernel(_ edge: RuleEdge) -> Bool {
            guard let source = mappingOrigin[edge.source], let target = mappingOrigin[edge.target] else { return false }
            return kernelEdges.contains(EdgeSignature(source: source, target: target, reference: edge.type.name))
        }
        let rhsEdges = Self.edgeSet(of: rule.rhs)
        var deletedEdges: [PatternEdge] = []
        for edge in rule.lhs.edges where !sharedWithKernel(edge) {
            let source = rule.image(of: edge.source)
            let target = rule.image(of: edge.target)
            let kept = source.flatMap { s in target.map { t in rhsEdges.contains(EdgeSignature(source: s, target: t, reference: edge.type.name)) } } ?? false
            if !kept, let s = lhs.positions[edge.source], let t = lhs.positions[edge.target] {
                deletedEdges.append(PatternEdge(source: s, target: t, reference: edge.type.name))
            }
        }
        self.deletedEdges = deletedEdges
        let lhsEdges = Self.edgeSet(of: rule.lhs)
        var createdEdges: [CreatedEdge] = []
        for edge in rule.rhs.edges where !sharedWithKernel(edge) {
            let source = rule.origin(of: edge.source)
            let target = rule.origin(of: edge.target)
            let existed = source.flatMap { s in target.map { t in lhsEdges.contains(EdgeSignature(source: s, target: t, reference: edge.type.name)) } } ?? false
            if !existed { createdEdges.append(CreatedEdge(source: edge.source, target: edge.target, reference: edge.type.name)) }
        }
        self.createdEdges = createdEdges

        var multiRules: [(rule: CompiledRule, mappings: [PositionMapping])] = []
        var shared = Set<Int>()
        for multiRule in rule.multiRules {
            let compiled = try CompiledRule(multiRule, options: options, kernel: rule, types: &types)
            var mappings: [PositionMapping] = []
            for mapping in multiRule.multiMappings {
                guard let host = lhs.positions[mapping.origin], let image = compiled.lhs.positions[mapping.image] else { continue }
                mappings.append(PositionMapping(host: host, image: image))
                shared.insert(host)
            }
            multiRules.append((compiled, mappings))
        }
        self.multiRules = multiRules
        nodesSharedWithMultiRules = shared

        var ends: [Int: Int] = [:]
        let deleted = Set(deletedNodes)
        for edge in deletedEdges {
            let opposite = types.reference(edge.reference, of: lhs.nodes[edge.source].type)?.oppositeName
            let explicitOpposite = opposite.map { name in
                deletedEdges.contains(PatternEdge(source: edge.target, target: edge.source, reference: name))
            } ?? true
            for end in [edge.source, edge.target] where deleted.contains(end) {
                ends[end, default: 0] += explicitOpposite ? 1 : 2
            }
        }
        deletedReferenceEnds = ends
    }

    /// An edge of a rule graph, identified by its ends and type.
    private struct EdgeSignature: Hashable {
        /// The source node.
        let source: NodeID
        /// The target node.
        let target: NodeID
        /// The name of the reference.
        let reference: String
    }

    /// The edges of a rule graph.
    private static func edgeSet(of graph: RuleGraph) -> Set<EdgeSignature> {
        Set(graph.edges.map { EdgeSignature(source: $0.source, target: $0.target, reference: $0.type.name) })
    }

    /// The edges of both sides of a rule.
    private static func edgeSet(of rule: Rule) -> Set<EdgeSignature> {
        edgeSet(of: rule.lhs).union(edgeSet(of: rule.rhs))
    }
}
