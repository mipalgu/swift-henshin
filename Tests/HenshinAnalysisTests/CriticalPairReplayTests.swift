//
//  CriticalPairReplayTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin
import Testing

@testable import HenshinAnalysis

/// Builds the overlap graph of a critical pair as a model and replays the pair with the
/// engine: both rules must be applicable at their matches, and after the first rule the
/// second must no longer be applicable at the remains of its match.
@Suite("Critical pair replay")
struct CriticalPairReplayTests {
    let analyser = CriticalPairAnalyser()

    /// A rule whose left-hand side nodes are bound to parameters, so that a match can be
    /// given.
    ///
    /// - Parameter rule: The rule.
    /// - Returns: The rule and the parameter name of each left-hand side node.
    static func pinned(_ rule: Rule) -> (Rule, [NodeID: String]) {
        var copy = rule
        var names: [NodeID: String] = [:]
        copy.parameters = rule.parameters.map { UnitParameter(name: $0.name, kind: .unknown, typeName: $0.typeName) }
        for index in copy.lhs.nodes.indices {
            let name = "pin\(copy.lhs.nodes[index].id.rawValue)"
            copy.lhs.nodes[index].name = name
            copy.parameters.append(UnitParameter(name: name, kind: .unknown))
            names[copy.lhs.nodes[index].id] = name
        }
        return (copy, names)
    }

    /// The model of an overlap graph, with literal attribute values of both rules.
    static func model(of pair: CriticalPair, first: Rule, second: Rule) async throws -> (Resource, [EUUID]) {
        var nodesByID: [NodeID: RuleNode] = [:]
        for node in first.lhs.nodes + first.rhs.nodes + second.lhs.nodes { nodesByID[node.id] = node }
        var objects: [DynamicEObject] = []
        for node in pair.graph.nodes {
            let candidates = [node.first, node.second].compactMap { $0.flatMap { nodesByID[$0] } }
            let ruleNode = try #require(candidates.first { $0.type.name == node.typeName })
            var object = DynamicEObject(eClass: ruleNode.type)
            for candidate in candidates {
                for attribute in candidate.attributes {
                    if let translated = try? JavaScriptTranslator(variables: []).translate(attribute.value),
                        case .literal(let literal) = translated.form, let value = literal.ecoreValue
                    {
                        object.eSet(attribute.feature.name, value: value)
                    }
                }
            }
            objects.append(object)
        }
        for edge in pair.graph.edges {
            let reference = try #require(objects[edge.source].eClass.eAllReferences.first { $0.name == edge.reference })
            Self.link(&objects, edge.source, reference, edge.target)
            if let oppositeID = reference.opposite,
                let opposite = objects[edge.target].eClass.eAllReferences.first(where: { $0.id == oppositeID })
            {
                Self.link(&objects, edge.target, opposite, edge.source)
            }
        }
        let resource = Resource()
        await resource.add(contentsOf: objects)
        return (resource, objects.map(\.id))
    }

    /// Adds a reference from one object to another.
    static func link(_ objects: inout [DynamicEObject], _ source: Int, _ reference: EReference, _ target: Int) {
        let id = objects[target].id
        if reference.isMany {
            var ids = (objects[source].eGet(reference.name) as? [EUUID]) ?? []
            if !ids.contains(id) { ids.append(id) }
            objects[source].eSet(reference.name, value: ids)
        } else {
            objects[source].eSet(reference.name, value: id)
        }
    }

    /// Whether a rule is applicable at a match given by overlap graph positions.
    static func applicable(_ rule: Rule, at match: [NodeID: Int], ids: [EUUID], in resource: Resource) async throws -> Bool {
        let (pinned, names) = pinned(rule)
        var parameters: ParameterValues = [:]
        for node in rule.lhs.nodes {
            guard let position = match[node.id], let name = names[node.id] else { continue }
            guard await resource.contains(id: ids[position]) else { return false }
            parameters[name] = ids[position]
        }
        return try await !HenshinEngine().findMatches(of: pinned, in: resource, parameters: parameters, limit: 1).isEmpty
    }

    /// Replays every critical pair of a conflicting rule pair.
    func replay(_ firstName: String, _ secondName: String, in rules: HenshinModule, expected: Int) async throws {
        let first = try rules.rule(firstName)
        let second = try rules.rule(secondName)
        let result = analyser.conflicts(first: first, second: second, granularity: .criticalPairs)
        #expect(result.criticalPairs.count == expected, "\(firstName) / \(secondName)")
        for pair in result.criticalPairs where pair.span.secondGraph == .leftHandSide {
            let (resource, ids) = try await Self.model(of: pair, first: first, second: second)
            #expect(try await Self.applicable(first, at: pair.firstMatch, ids: ids, in: resource), "\(pair)")
            #expect(try await Self.applicable(second, at: pair.secondMatch, ids: ids, in: resource), "\(pair)")
            let (pinned, names) = Self.pinned(first)
            var parameters: ParameterValues = [:]
            for node in first.lhs.nodes {
                if let position = pair.firstMatch[node.id], let name = names[node.id] { parameters[name] = ids[position] }
            }
            let application = try await HenshinEngine().apply(pinned, to: resource, parameters: parameters)
            #expect(application.succeeded, "\(pair)")
            #expect(try await !Self.applicable(second, at: pair.secondMatch, ids: ids, in: resource), "\(pair)")
        }
    }

    @Test("Graph rule conflicts replay as conflicts")
    func graphRules() async throws {
        let rules = try await Fixtures.graphRules()
        try await replay("deleteNext", "deleteNext", in: rules, expected: 1)
        try await replay("deleteNext", "propagate", in: rules, expected: 1)
        try await replay("deleteNode", "mark", in: rules, expected: 1)
        try await replay("deleteNode", "deleteNode", in: rules, expected: 1)
        try await replay("mark", "mark", in: rules, expected: 1)
        try await replay("mark", "propagate", in: rules, expected: 1)
        try await replay("propagate", "mark", in: rules, expected: 1)
        try await replay("propagate", "propagate", in: rules, expected: 2)
    }

    @Test("Token ring conflicts replay as conflicts")
    func tokenRing() async throws {
        let rules = try await Fixtures.module("ring.henshin", metamodel: "ring.ecore").1
        try await replay("pass", "enter", in: rules, expected: 1)
        try await replay("pass", "pass", in: rules, expected: 1)
        try await replay("enter", "leave", in: rules, expected: 0)
        try await replay("enter", "enter", in: rules, expected: 2)
    }
}
