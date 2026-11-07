//
//  ConflictTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin
import Testing

@testable import HenshinAnalysis

/// Tests of conflict detection on neutral graph, bank and token-ring rules.
@Suite("Conflicts")
struct ConflictTests {
    let analyser = CriticalPairAnalyser()

    @Test("Deleting an edge conflicts with using it")
    func deleteEdgeUse() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(
            first: try rules.rule("deleteNext"), second: try rules.rule("deleteNext"), granularity: .criticalPairs)
        #expect(result.interacts)
        #expect(result.kinds == [.deleteUse])
        #expect(result.atoms.count == 1)
        #expect(result.atoms.first?.span.edges.count == 1)
        #expect(result.minimalReasons.count == 1)
        #expect(result.minimalReasons.first?.span.nodes.count == 2)
        #expect(result.minimalReasons.first?.span.edges.count == 1)
        #expect(result.criticalPairs.count == 1)
        #expect(result.criticalPairs.first?.isEssential == true)
        #expect(result.criticalPairs.first?.graph.nodes.count == 2)
        #expect(result.criticalPairs.first?.graph.edges.count == 1)
    }

    @Test("The dangling condition rules out deleting a linked node")
    func danglingPreventsConflict() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(
            first: try rules.rule("deleteNode"), second: try rules.rule("deleteNext"), granularity: .criticalPairs)
        #expect(!result.interacts)
        #expect(result.criticalPairs.isEmpty)
        let lenient = CriticalPairAnalyser(options: AnalysisOptions(checkDangling: false))
            .conflicts(first: try rules.rule("deleteNode"), second: try rules.rule("deleteNext"), granularity: .minimalReasons)
        #expect(lenient.interacts)
        #expect(lenient.minimalReasons.count == 2)
    }

    @Test("Deleting a node conflicts with reading it")
    func deleteNodeUse() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(
            first: try rules.rule("deleteNode"), second: try rules.rule("mark"), granularity: .criticalPairs)
        #expect(result.kinds == [.deleteUse])
        #expect(result.atoms.count == 1)
        #expect(result.minimalReasons.map(\.span.size) == [1])
        #expect(result.criticalPairs.count == 1)
    }

    @Test("Deleting a contained node requires its container in the overlap")
    func deleteNodeSelf() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(
            first: try rules.rule("deleteNode"), second: try rules.rule("deleteNode"), granularity: .criticalPairs)
        #expect(result.atoms.count == 1)
        #expect(result.minimalReasons.count == 1)
        #expect(result.minimalReasons.first?.span.nodes.count == 2)
        #expect(result.minimalReasons.first?.span.edges.count == 1)
        #expect(result.criticalPairs.count == 1)
    }

    @Test("Creating an edge conflicts with a condition that forbids it")
    func produceForbid() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(
            first: try rules.rule("addNext"), second: try rules.rule("addNext"), granularity: .criticalPairs)
        #expect(result.kinds == [.produceForbid])
        #expect(result.atoms.count == 1)
        #expect(result.minimalReasons.count == 1)
        let reason = try #require(result.minimalReasons.first)
        #expect(reason.span.firstGraph == .rightHandSide)
        #expect(reason.span.secondGraph == .negativeCondition(index: 0, name: "linked"))
        #expect(reason.span.size == 3)
        #expect(result.criticalPairs.count == 1)
    }

    @Test("Changing an attribute conflicts with reading it, unless the literals differ")
    func changeUse() async throws {
        let rules = try await Fixtures.graphRules()
        let markMark = analyser.conflicts(first: try rules.rule("mark"), second: try rules.rule("mark"))
        #expect(markMark.kinds == [.changeUse])
        #expect(markMark.atoms.count == 1)
        let markPropagate = analyser.conflicts(first: try rules.rule("mark"), second: try rules.rule("propagate"))
        #expect(markPropagate.kinds == [.changeUse])
        #expect(markPropagate.atoms.count == 1)
        let element = try #require(markPropagate.atoms.first?.element.overlap)
        let propagate = try rules.rule("propagate")
        #expect(element.second == .attribute(node: propagate.lhs.nodes[1].id, feature: "marked"))
        let propagateMark = analyser.conflicts(first: try rules.rule("propagate"), second: try rules.rule("mark"))
        #expect(propagateMark.atoms.count == 1)
    }

    @Test("Creating rules without conditions conflict with nothing")
    func createOnly() async throws {
        let rules = try await Fixtures.graphRules()
        let table = analyser.analyse(rules.rules, direction: .conflict)
        let createNode = try #require(table.rules.firstIndex(of: "createNode"))
        #expect(table.pairs[createNode].allSatisfy { !$0.interacts })
    }

    @Test("Binary granularity stops at the first interaction")
    func binary() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(first: try rules.rule("deleteNext"), second: try rules.rule("propagate"), granularity: .binary)
        #expect(result.interacts)
        #expect(result.kinds == [.deleteUse])
        #expect(result.atoms.isEmpty && result.minimalReasons.isEmpty)
        let none = analyser.conflicts(first: try rules.rule("createNode"), second: try rules.rule("mark"), granularity: .binary)
        #expect(!none.interacts)
    }

    @Test("Bank: deleting an account conflicts with every use of an account")
    func bankDeleteAccount() async throws {
        let rules = try await Fixtures.bankRules()
        let deposit = analyser.conflicts(first: try rules.rule("deleteAccount"), second: try rules.rule("deposit"), granularity: .criticalPairs)
        #expect(deposit.kinds == [.deleteUse])
        #expect(deposit.minimalReasons.count == 1)
        #expect(deposit.criticalPairs.count == 1)
        let transfer = analyser.conflicts(first: try rules.rule("deleteAccount"), second: try rules.rule("transfer"), granularity: .criticalPairs)
        #expect(transfer.atoms.count == 2)
        #expect(transfer.minimalReasons.count == 2)
        #expect(transfer.criticalPairs.count == 2)
        let itself = analyser.conflicts(first: try rules.rule("deleteAccount"), second: try rules.rule("deleteAccount"), granularity: .criticalPairs)
        #expect(itself.minimalReasons.count == 1)
        #expect(itself.minimalReasons.first?.span.nodes.count == 3)
        #expect(itself.minimalReasons.first?.span.edges.count == 2)
        #expect(itself.criticalPairs.count == 1)
    }

    @Test("Bank: creating an account conflicts with creating one of the same id")
    func bankCreateAccount() async throws {
        let rules = try await Fixtures.bankRules()
        let result = analyser.conflicts(first: try rules.rule("createAccount"), second: try rules.rule("createAccount"), granularity: .criticalPairs)
        #expect(result.kinds == [.produceForbid])
        #expect(result.atoms.count == 1)
        #expect(result.minimalReasons.count == 1)
        #expect(result.minimalReasons.first?.span.size == 3)
        #expect(result.criticalPairs.count == 1)
        let clients = analyser.conflicts(first: try rules.rule("createClient"), second: try rules.rule("createClient"))
        #expect(clients.kinds == [.produceForbid])
        #expect(clients.minimalReasons.first?.span.size == 3)
    }

    @Test("Bank: transfers conflict through the balances of both accounts")
    func bankTransfers() async throws {
        let rules = try await Fixtures.bankRules()
        let result = analyser.conflicts(first: try rules.rule("transfer"), second: try rules.rule("transfer"), granularity: .criticalPairs)
        #expect(result.kinds == [.changeUse])
        #expect(result.atoms.count == 4)
        #expect(result.minimalReasons.count == 4)
        #expect(result.criticalPairs.count == 6)
        #expect(result.criticalPairs.allSatisfy { $0.isEssential })
        let deposit = analyser.conflicts(first: try rules.rule("deposit"), second: try rules.rule("transfer"))
        #expect(deposit.atoms.count == 2)
    }

    @Test("Token ring: passing the token conflicts with entering and with passing")
    func tokenRing() async throws {
        let rules = try await Fixtures.module("ring.henshin", metamodel: "ring.ecore").1
        let passEnter = analyser.conflicts(first: try rules.rule("pass"), second: try rules.rule("enter"), granularity: .criticalPairs)
        #expect(passEnter.kinds == [.deleteUse])
        #expect(passEnter.minimalReasons.count == 1)
        let passPass = analyser.conflicts(first: try rules.rule("pass"), second: try rules.rule("pass"), granularity: .criticalPairs)
        #expect(passPass.minimalReasons.count == 1)
        #expect(passPass.minimalReasons.first?.span.size == 5)
        #expect(passPass.criticalPairs.count == 1)
        let loose = CriticalPairAnalyser(options: AnalysisOptions(respectsMultiplicities: false))
            .conflicts(first: try rules.rule("pass"), second: try rules.rule("pass"), granularity: .criticalPairs)
        #expect(loose.minimalReasons.first?.span.size == 3)
        #expect(loose.criticalPairs.count == 3)
        let enterPass = analyser.conflicts(first: try rules.rule("enter"), second: try rules.rule("pass"))
        #expect(enterPass.kinds == [.changeForbid])
        #expect(enterPass.atoms.count == 1)
        let requestEnter = analyser.conflicts(first: try rules.rule("request"), second: try rules.rule("enter"))
        #expect(!requestEnter.interacts)
    }

    @Test("Overlaps at which a negative condition matches are left out")
    func negativeConditionsFilterOverlaps() async throws {
        let (_, module) = try await Fixtures.module("graphs.henshin", metamodel: "graphs.ecore")
        var builder = try RuleBuilder(module)
        let pairDelete = builder.deleteForwardOfPair()
        let guarded = builder.useUnlessBackEdge()
        #expect(!analyser.conflicts(first: pairDelete, second: guarded).interacts)
        let unchecked = CriticalPairAnalyser(options: AnalysisOptions(checksNegativeConditions: false))
        let uncheckedResult = unchecked.conflicts(first: pairDelete, second: guarded)
        #expect(uncheckedResult.kinds == [.deleteUse])
        let chain = builder.deleteFirstOfChain()
        let onward = builder.useUnlessTargetLinks()
        let filtered = analyser.conflicts(first: chain, second: onward, granularity: .criticalPairs)
        #expect(!filtered.interacts)
        let reversed = analyser.conflicts(first: try module.rule("deleteNext"), second: onward, granularity: .criticalPairs)
        #expect(reversed.criticalPairs.count == 1)
    }

    @Test("Notes report what the analysis approximates")
    func notes() async throws {
        let rules = try await Fixtures.bankRules()
        let result = analyser.conflicts(first: try rules.rule("closeClient"), second: try rules.rule("transfer"))
        #expect(result.notes.contains { $0.contains("multi-rules") })
        #expect(result.notes.contains { $0.contains("attribute conditions of transfer") })
        #expect(result.description.contains("note:"))
    }

    @Test("Positive conditions of the second rule count as used elements")
    func positiveConditions() async throws {
        let rules = try await Fixtures.bankRules()
        let merged = analyser.conflicts(first: try rules.rule("deleteAccount"), second: try rules.rule("freezeOwned"))
        #expect(merged.minimalReasons.count == 1)
        #expect(merged.minimalReasons.first?.span.size == 3)
        let plain = CriticalPairAnalyser(options: AnalysisOptions(includesPositiveConditions: false))
            .conflicts(first: try rules.rule("deleteAccount"), second: try rules.rule("freezeOwned"))
        #expect(plain.minimalReasons.count == 1)
        #expect(plain.minimalReasons.first?.span.size == 1)
    }

    @Test("Limits cut the critical pairs short and say so")
    func limits() async throws {
        let rules = try await Fixtures.bankRules()
        let limited = CriticalPairAnalyser(options: AnalysisOptions(maximumCriticalPairs: 2))
            .conflicts(first: try rules.rule("transfer"), second: try rules.rule("transfer"), granularity: .criticalPairs)
        #expect(limited.criticalPairs.count == 2)
        #expect(limited.isTruncated)
        let essential = CriticalPairAnalyser(options: AnalysisOptions(essentialOnly: true))
            .conflicts(first: try rules.rule("transfer"), second: try rules.rule("transfer"), granularity: .criticalPairs)
        #expect(essential.criticalPairs.count == 6)
        let starved = CriticalPairAnalyser(options: AnalysisOptions(searchBudget: 1))
            .conflicts(first: try rules.rule("transfer"), second: try rules.rule("transfer"), granularity: .criticalPairs)
        #expect(starved.isTruncated)
    }
}
