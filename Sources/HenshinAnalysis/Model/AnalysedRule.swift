//
//  AnalysedRule.swift
//  HenshinAnalysis
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin

/// A negative application condition of a rule, prepared for overlapping.
struct AnalysedCondition: Sendable {
    /// The position of the condition among the negative conditions of the rule.
    let index: Int

    /// The name of the conclusion graph, if it has one.
    let name: String?

    /// The conclusion graph, whose nodes take over the attributes of the nodes they are
    /// mapped from.
    let graph: AnalysisGraph

    /// The node of the conclusion that each left-hand side node is mapped to, by position.
    let hostMapping: [Int: Int]

    /// The conclusion nodes that no left-hand side node is mapped to.
    let conditionOnlyNodes: Set<Int>

    /// The conclusion edges that do not stand for an edge of the left-hand side.
    let conditionOnlyEdges: Set<Int>

    /// The attributes that each conclusion node tests beyond those of its left-hand side
    /// node, by position.
    let conditionOnlyAttributes: [Int: Set<String>]

    /// Whether the conclusion has a nested condition of its own, which the analysis cannot
    /// decide.
    let isNested: Bool

    /// The role of the conclusion graph in reports.
    var role: RuleGraphRole { .negativeCondition(index: index, name: name) }
}

/// A rule, classified into what it deletes, creates, preserves and changes.
///
/// An edge of the left-hand side is preserved if both of its nodes are preserved and the
/// right-hand side has an edge of the same reference between their images. An attribute of a
/// preserved node is changed if the right-hand side gives it a value that differs from the
/// left-hand side, as in Henshin's interpreter.
struct AnalysedRule: Sendable {
    /// The rule.
    let rule: Rule

    /// The left-hand side.
    let lhs: AnalysisGraph

    /// The left-hand side extended by the conclusions of positive application conditions;
    /// the nodes and edges that the conditions add come after those of ``lhs``.
    let requiredLHS: AnalysisGraph

    /// The right-hand side, whose preserved nodes keep the attributes of the left-hand side
    /// that the right-hand side does not change.
    let rhs: AnalysisGraph

    /// The right-hand side node of each preserved left-hand side node, by position.
    let lhsToRHS: [Int: Int]

    /// The left-hand side node of each preserved right-hand side node, by position.
    let rhsToLHS: [Int: Int]

    /// The left-hand side nodes that the rule deletes.
    let deletedNodes: Set<Int>

    /// The left-hand side edges that the rule deletes.
    let deletedEdges: Set<Int>

    /// The right-hand side nodes that the rule creates.
    let createdNodes: Set<Int>

    /// The right-hand side edges that the rule creates.
    let createdEdges: Set<Int>

    /// The attributes that the rule changes, by left-hand side node position.
    let changedLHS: [Int: Set<String>]

    /// The attributes that the rule changes, by right-hand side node position.
    let changedRHS: [Int: Set<String>]

    /// The negative application conditions.
    let negativeConditions: [AnalysedCondition]

    /// Whether the rule is applied only if deleting nodes leaves no reference dangling.
    let checksDangling: Bool

    /// What the analysis could not take into account for the rule.
    let notes: [String]

    /// Prepares a rule for analysis.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - checkDangling: Overrides the dangling condition of the rule, if given.
    init(_ rule: Rule, checkDangling: Bool? = nil) {
        self.rule = rule
        let variables = Set(rule.parameters.map(\.name))
        var notes: [String] = []
        let lhs = AnalysisGraph(rule.lhs, variables: variables)
        var lhsToRHS: [Int: Int] = [:]
        var rhsToLHS: [Int: Int] = [:]
        var inherited: [NodeID: [String: AttributeTerm]] = [:]
        for mapping in rule.mappings {
            guard let origin = lhs.position(of: mapping.origin),
                let image = rule.rhs.nodes.firstIndex(where: { $0.id == mapping.image })
            else { continue }
            lhsToRHS[origin] = image
            rhsToLHS[image] = origin
            inherited[mapping.image] = lhs.nodes[origin].attributes
        }
        let rhs = AnalysisGraph(rule.rhs, variables: variables, inherited: inherited)
        self.lhs = lhs
        self.rhs = rhs
        self.lhsToRHS = lhsToRHS
        self.rhsToLHS = rhsToLHS
        deletedNodes = Set(lhs.nodes.indices.filter { lhsToRHS[$0] == nil })
        createdNodes = Set(rhs.nodes.indices.filter { rhsToLHS[$0] == nil })

        var usedRHSEdges = Set<Int>()
        var deletedEdges = Set<Int>()
        for (position, edge) in lhs.edges.enumerated() {
            guard let source = lhsToRHS[edge.source], let target = lhsToRHS[edge.target],
                let image = rhs.edges.indices.first(where: { candidate in
                    !usedRHSEdges.contains(candidate) && rhs.edges[candidate].source == source
                        && rhs.edges[candidate].target == target && rhs.edges[candidate].type == edge.type
                })
            else {
                deletedEdges.insert(position)
                continue
            }
            usedRHSEdges.insert(image)
        }
        self.deletedEdges = deletedEdges
        createdEdges = Set(rhs.edges.indices.filter { !usedRHSEdges.contains($0) })

        var changedLHS: [Int: Set<String>] = [:]
        var changedRHS: [Int: Set<String>] = [:]
        for (origin, image) in lhsToRHS {
            let before = Dictionary(
                rule.lhs.nodes[origin].attributes.map { ($0.feature.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            var changed = Set<String>()
            for attribute in rule.rhs.nodes[image].attributes where before[attribute.feature.name] != attribute.value {
                changed.insert(attribute.feature.name)
            }
            if !changed.isEmpty {
                changedLHS[origin] = changed
                changedRHS[image] = changed
            }
        }
        self.changedLHS = changedLHS
        self.changedRHS = changedRHS
        checksDangling = checkDangling ?? rule.checkDangling

        var negative: [AnalysedCondition] = []
        var required = lhs
        for conjunct in Self.conjuncts(of: rule.lhs.formula) {
            switch conjunct {
            case .not(.condition(let condition)):
                negative.append(Self.condition(condition, index: negative.count, lhs: lhs, variables: variables))
            case .condition(let condition):
                if condition.conclusion.formula != nil {
                    notes.append("a positive application condition of \(rule.name) has a nested condition, which is ignored")
                }
                Self.merge(condition, into: &required, lhs: lhs, variables: variables)
            case .true:
                break
            default:
                notes.append("a disjunctive or nested application condition of \(rule.name) is ignored")
            }
        }
        for condition in negative where condition.isNested {
            notes.append("negative application condition \(condition.index) of \(rule.name) has a nested condition and is ignored")
        }
        negativeConditions = negative
        requiredLHS = required
        if !rule.multiRules.isEmpty {
            notes.append("the multi-rules of \(rule.name) are not analysed; its kernel rule is")
        }
        if !rule.attributeConditions.isEmpty {
            notes.append("the attribute conditions of \(rule.name) are ignored, which may report more interactions")
        }
        if !rule.injectiveMatching {
            notes.append("\(rule.name) matches non-injectively; the analysis assumes injective matches")
        }
        self.notes = notes
    }

    /// The conjuncts of a formula: the formula itself unless it is a conjunction.
    static func conjuncts(of formula: Formula?) -> [Formula] {
        guard let formula else { return [] }
        if case .and(let lhs, let rhs) = formula { return conjuncts(of: lhs) + conjuncts(of: rhs) }
        return [formula]
    }

    /// Prepares a negative application condition.
    static func condition(_ condition: NestedCondition, index: Int, lhs: AnalysisGraph, variables: Set<String>)
        -> AnalysedCondition
    {
        var inherited: [NodeID: [String: AttributeTerm]] = [:]
        var hostMapping: [Int: Int] = [:]
        for mapping in condition.mappings {
            guard let host = lhs.position(of: mapping.origin),
                let image = condition.conclusion.nodes.firstIndex(where: { $0.id == mapping.image })
            else { continue }
            hostMapping[host] = image
            inherited[mapping.image] = lhs.nodes[host].attributes
        }
        let graph = AnalysisGraph(condition.conclusion, variables: variables, inherited: inherited)
        let mappedImages = Set(hostMapping.values)
        let conditionOnlyNodes = Set(graph.nodes.indices.filter { !mappedImages.contains($0) })
        let hostOf = Dictionary(hostMapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var used = Set<Int>()
        var conditionOnlyEdges = Set<Int>()
        for (position, edge) in graph.edges.enumerated() {
            guard let source = hostOf[edge.source], let target = hostOf[edge.target],
                let hostEdge = lhs.edges.indices.first(where: { candidate in
                    !used.contains(candidate) && lhs.edges[candidate].source == source
                        && lhs.edges[candidate].target == target && lhs.edges[candidate].type == edge.type
                })
            else {
                conditionOnlyEdges.insert(position)
                continue
            }
            used.insert(hostEdge)
        }
        var conditionOnlyAttributes: [Int: Set<String>] = [:]
        for (position, node) in condition.conclusion.nodes.enumerated() {
            let host = hostOf[position].map { lhs.nodes[$0].attributes } ?? [:]
            let own = Set(node.attributes.filter { host[$0.feature.name]?.text != $0.value }.map(\.feature.name))
            if !own.isEmpty { conditionOnlyAttributes[position] = own }
        }
        return AnalysedCondition(
            index: index, name: condition.conclusion.name, graph: graph, hostMapping: hostMapping,
            conditionOnlyNodes: conditionOnlyNodes, conditionOnlyEdges: conditionOnlyEdges,
            conditionOnlyAttributes: conditionOnlyAttributes, isNested: condition.conclusion.formula != nil)
    }

    /// Adds the conclusion of a positive application condition to a left-hand side.
    static func merge(_ condition: NestedCondition, into graph: inout AnalysisGraph, lhs: AnalysisGraph, variables: Set<String>) {
        var positions: [NodeID: Int] = [:]
        for mapping in condition.mappings {
            if let host = lhs.position(of: mapping.origin) { positions[mapping.image] = host }
        }
        for node in condition.conclusion.nodes where positions[node.id] == nil {
            var attributes: [String: AttributeTerm] = [:]
            for attribute in node.attributes {
                attributes[attribute.feature.name] = AttributeTerm(attribute.value, variables: variables)
            }
            positions[node.id] = graph.addNode(AnalysisNode(id: node.id, type: node.type, attributes: attributes))
        }
        for edge in condition.conclusion.edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else { continue }
            let (type, flipped) = AnalysisGraph.canonicalType(of: edge.type, sourceType: graph.nodes[source].type)
            let canonicalSource = flipped ? target : source
            let canonicalTarget = flipped ? source : target
            let exists = graph.outgoing[canonicalSource].contains { candidate in
                graph.edges[candidate].target == canonicalTarget && graph.edges[candidate].type == type
            }
            if !exists { graph.addEdge(source: source, target: target, reference: edge.type, sourceType: graph.nodes[source].type) }
        }
    }

    /// The attributes that the rule reads or changes at each left-hand side node, by position.
    var usedAttributes: [Int: Set<String>] {
        var result: [Int: Set<String>] = [:]
        for (position, node) in requiredLHS.nodes.enumerated() {
            let used = Set(node.attributes.keys).union(changedLHS[position] ?? [])
            if !used.isEmpty { result[position] = used }
        }
        return result
    }
}
