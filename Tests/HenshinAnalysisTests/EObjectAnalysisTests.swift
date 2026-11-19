//
//  EObjectAnalysisTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin
import Testing

@testable import HenshinAnalysis

/// Tests that a node typed Ecore's `EObject` overlaps with a node of any class, as every
/// model object is an `EObject` in EMF.
@Suite("EObject nodes in analysis")
struct EObjectAnalysisTests {
    let analyser = CriticalPairAnalyser()

    /// Ecore's `EObject`.
    let eObject = EcorePackage.metaClass(.eObject)

    /// An identity rule that reads one object of any class.
    func readAny() -> Rule {
        let (node, kept) = (RuleNode(id: NodeID(200_001), name: "x", type: eObject), RuleNode(id: NodeID(200_002), name: "x", type: eObject))
        return Rule(
            name: "readAny", lhs: RuleGraph(nodes: [node]), rhs: RuleGraph(nodes: [kept]),
            mappings: [NodeMapping(origin: node.id, image: kept.id)])
    }

    @Test("Deleting a node conflicts with reading any object")
    func deleteUse() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(first: try rules.rule("deleteNode"), second: readAny(), granularity: .criticalPairs)
        #expect(result.interacts)
        #expect(result.kinds == [.deleteUse])
        #expect(result.minimalReasons.map(\.span.size) == [1])
        let pair = try #require(result.criticalPairs.first)
        #expect(result.criticalPairs.count == 1)
        #expect(pair.graph.nodes.contains { $0.typeName == "Node" && $0.first != nil && $0.second != nil })
    }

    @Test("Creating a node enables reading any object")
    func produceUse() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.dependencies(first: try rules.rule("createNode"), second: readAny(), granularity: .criticalPairs)
        #expect(result.kinds == [.produceUse])
        #expect(result.criticalPairs.count == 1)
    }

    @Test("EObject is compatible with every class and the class is the meet")
    func typeConformance() async throws {
        let rules = try await Fixtures.graphRules()
        let node = try rules.rule("mark").lhs.nodes[0].type
        let graph = try rules.rule("deleteNode").lhs.nodes[0].type
        #expect(TypeConformance.conforms(node, to: eObject))
        #expect(!TypeConformance.conforms(eObject, to: node))
        #expect(TypeConformance.compatible(eObject, node))
        #expect(TypeConformance.meet(eObject, node).name == node.name)
        #expect(TypeConformance.meet(node, eObject).name == node.name)
        #expect(!TypeConformance.compatible(node, graph))
    }
}
