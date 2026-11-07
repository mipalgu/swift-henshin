//
//  DependencyTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin
import Testing

@testable import HenshinAnalysis

/// Tests of dependency detection on neutral graph, bank and token-ring rules.
@Suite("Dependencies")
struct DependencyTests {
    let analyser = CriticalPairAnalyser()

    @Test("Creating an edge enables using it")
    func produceUse() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.dependencies(
            first: try rules.rule("addNext"), second: try rules.rule("deleteNext"), granularity: .criticalPairs)
        #expect(result.direction == .dependency)
        #expect(result.kinds == [.produceUse])
        #expect(result.atoms.count == 1)
        #expect(result.minimalReasons.count == 1)
        #expect(result.minimalReasons.first?.span.firstGraph == .rightHandSide)
        #expect(result.minimalReasons.first?.span.size == 3)
        #expect(result.criticalPairs.count == 1)
    }

    @Test("Deleting an edge enables a rule that forbids it")
    func deleteForbid() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.dependencies(first: try rules.rule("deleteNext"), second: try rules.rule("addNext"))
        #expect(result.kinds == [.deleteForbid])
        #expect(result.minimalReasons.count == 1)
        #expect(result.minimalReasons.first?.span.firstGraph == .leftHandSide)
    }

    @Test("A created node has only the edges its rule creates")
    func createdNodes() async throws {
        let rules = try await Fixtures.graphRules()
        let mark = analyser.dependencies(first: try rules.rule("createNode"), second: try rules.rule("mark"))
        #expect(mark.kinds == [.produceUse])
        #expect(mark.minimalReasons.first?.span.size == 1)
        let delete = analyser.dependencies(first: try rules.rule("createNode"), second: try rules.rule("deleteNode"))
        #expect(delete.minimalReasons.first?.span.size == 3)
        let next = analyser.dependencies(first: try rules.rule("createNode"), second: try rules.rule("deleteNext"))
        #expect(!next.interacts)
    }

    @Test("Changing an attribute enables reading the new value only")
    func changeUse() async throws {
        let rules = try await Fixtures.graphRules()
        let markPropagate = analyser.dependencies(first: try rules.rule("mark"), second: try rules.rule("propagate"))
        #expect(markPropagate.kinds == [.changeUse])
        #expect(markPropagate.atoms.count == 1)
        let propagate = try rules.rule("propagate")
        #expect(markPropagate.atoms.first?.element.overlap.second == .attribute(node: propagate.lhs.nodes[0].id, feature: "marked"))
        let markMark = analyser.dependencies(first: try rules.rule("mark"), second: try rules.rule("mark"))
        #expect(!markMark.interacts)
        let chain = analyser.dependencies(first: try rules.rule("propagate"), second: try rules.rule("propagate"))
        #expect(chain.atoms.count == 1)
    }

    @Test("Bank: creating and deleting accounts enable each other")
    func bank() async throws {
        let rules = try await Fixtures.bankRules()
        let deposit = analyser.dependencies(first: try rules.rule("createAccount"), second: try rules.rule("deposit"))
        #expect(deposit.kinds == [.produceUse])
        #expect(deposit.minimalReasons.count == 1)
        let delete = analyser.dependencies(first: try rules.rule("createAccount"), second: try rules.rule("deleteAccount"))
        #expect(delete.minimalReasons.count == 1)
        #expect(delete.minimalReasons.first?.span.nodes.count == 3)
        #expect(delete.minimalReasons.first?.span.edges.count == 2)
        let recreate = analyser.dependencies(first: try rules.rule("deleteAccount"), second: try rules.rule("createAccount"))
        #expect(recreate.kinds == [.deleteForbid])
        #expect(recreate.atoms.count == 1)
        #expect(recreate.minimalReasons.first?.span.size == 3)
    }

    @Test("Token ring: the protocol steps enable one another")
    func tokenRing() async throws {
        let rules = try await Fixtures.module("ring.henshin", metamodel: "ring.ecore").1
        let requestEnter = analyser.dependencies(first: try rules.rule("request"), second: try rules.rule("enter"))
        #expect(requestEnter.kinds == [.changeUse])
        let leavePass = analyser.dependencies(first: try rules.rule("leave"), second: try rules.rule("pass"))
        #expect(leavePass.kinds == [.changeForbid])
        let passEnter = analyser.dependencies(first: try rules.rule("pass"), second: try rules.rule("enter"))
        #expect(passEnter.kinds == [.produceUse])
        #expect(passEnter.minimalReasons.count == 1)
        let enterLeave = analyser.dependencies(first: try rules.rule("enter"), second: try rules.rule("leave"))
        #expect(enterLeave.kinds == [.changeUse])
        let requestLeave = analyser.dependencies(first: try rules.rule("request"), second: try rules.rule("leave"))
        #expect(!requestLeave.interacts)
    }

    @Test("A dependency table covers every ordered pair")
    func table() async throws {
        let rules = try await Fixtures.graphRules()
        let table = analyser.analyse(rules.rules, direction: .dependency, granularity: .atoms)
        #expect(table.rules.count == rules.rules.count)
        #expect(table.pairs.count == rules.rules.count)
        #expect(table.interaction(first: "addNext", second: "deleteNext")?.interacts == true)
        #expect(table.interaction(first: "addNext", second: "missing") == nil)
        #expect(table.interactingPairs.contains { $0.firstRule == "createNode" && $0.secondRule == "mark" })
        #expect(table.description.contains("createNode"))
    }
}
