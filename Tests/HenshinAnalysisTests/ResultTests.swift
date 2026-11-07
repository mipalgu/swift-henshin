//
//  ResultTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Henshin
import Testing

@testable import HenshinAnalysis

/// Tests of the reports and approximations of the analysis.
@Suite("Results")
struct ResultTests {
    let analyser = CriticalPairAnalyser()

    @Test("Granularities and kinds have names and orders")
    func names() {
        #expect(AnalysisGranularity.allCases.map(\.description) == ["binary", "atoms", "minimal-reasons", "critical-pairs"])
        for granularity in AnalysisGranularity.allCases { #expect(AnalysisGranularity(name: granularity.description) == granularity) }
        #expect(AnalysisGranularity(name: "coarse") == nil)
        #expect(AnalysisGranularity.binary < .criticalPairs)
        #expect(InteractionKind.deleteUse < .deleteForbid)
        #expect(InteractionKind.produceForbid.description == "produce-forbid")
        #expect(RuleGraphRole.leftHandSide.description == "LHS")
        #expect(RuleGraphRole.rightHandSide.description == "RHS")
        #expect(RuleGraphRole.negativeCondition(index: 1, name: nil).description == "NAC 1")
        #expect(RuleGraphRole.negativeCondition(index: 0, name: "linked").description == "NAC 0 (linked)")
        #expect(RuleElement.node(NodeID(3)).description == "#3")
        #expect(RuleElement.edge(source: NodeID(3), reference: "next", target: NodeID(4)).description == "#3-next->#4")
        #expect(RuleElement.attribute(node: NodeID(3), feature: "marked").description == "#3.marked")
    }

    @Test("Reports describe atoms, reasons and critical pairs")
    func reports() async throws {
        let rules = try await Fixtures.graphRules()
        let result = analyser.conflicts(first: try rules.rule("deleteNext"), second: try rules.rule("deleteNext"), granularity: .criticalPairs)
        let text = result.description
        #expect(text.hasPrefix("deleteNext conflicts with deleteNext: delete-use"))
        #expect(text.contains("atoms: 1"))
        #expect(text.contains("minimal reasons: 1"))
        #expect(text.contains("critical pairs: 1"))
        #expect(text.contains("(essential)"))
        #expect(text.contains("LHS~LHS {"))
        let atom = try #require(result.atoms.first)
        #expect(atom.kind == .deleteUse)
        #expect(atom.description.contains("in 1 minimal reason(s)"))
        let pair = try #require(result.criticalPairs.first)
        #expect(pair.criticalElements.first?.description.hasPrefix("delete-use ") == true)
        #expect(pair.firstMatch.count == 2 && pair.secondMatch.count == 2)
        #expect(pair.graph.nodes.allSatisfy { $0.first != nil && $0.second != nil && $0.typeName == "Node" })
        #expect(pair.graph.edges.count == 1 && pair.graph.edges[0].fromFirst && pair.graph.edges[0].fromSecond)
        let none = analyser.dependencies(first: try rules.rule("mark"), second: try rules.rule("mark"))
        #expect(none.description == "mark does not enable mark")
        let noConflict = analyser.conflicts(first: try rules.rule("createNode"), second: try rules.rule("mark"))
        #expect(noConflict.description == "createNode does not conflict with mark")
        let dependency = analyser.dependencies(first: try rules.rule("addNext"), second: try rules.rule("deleteNext"), granularity: .atoms)
        #expect(dependency.description.hasPrefix("addNext enables deleteNext: produce-use"))
        #expect(!dependency.description.contains("minimal reasons"))
    }

    @Test("Tables show counts by granularity")
    func tables() async throws {
        let rules = try await Fixtures.graphRules()
        for granularity in AnalysisGranularity.allCases {
            let table = analyser.analyse(rules.rules, direction: .conflict, granularity: granularity)
            let row = try #require(table.description.split(separator: "\n").first { $0.hasPrefix("deleteNext ") })
            #expect(row.contains(granularity == .binary ? "x" : "1"))
        }
    }

    @Test("Conditions the analysis cannot decide are noted")
    func approximations() async throws {
        let (_, module) = try await Fixtures.module("graphs.henshin", metamodel: "graphs.ecore")
        var builder = try RuleBuilder(module)
        var guarded = builder.useUnlessBackEdge()
        let nac = try #require(AnalysedRule.conjuncts(of: guarded.lhs.formula).first)
        guard case .not(.condition(let condition)) = nac else { Issue.record("expected a negative condition"); return }
        var nested = condition
        nested.conclusion.formula = .true
        guarded.lhs.formula = .and(.or(.true, .true), .and(.not(.condition(nested)), .condition(nested)))
        guarded.injectiveMatching = false
        let result = analyser.conflicts(first: try module.rule("deleteNext"), second: guarded)
        #expect(result.notes.contains { $0.contains("disjunctive or nested") })
        #expect(result.notes.contains { $0.contains("negative application condition 0") })
        #expect(result.notes.contains { $0.contains("positive application condition") })
        #expect(result.notes.contains { $0.contains("non-injectively") })
        #expect(result.kinds == [.deleteUse])
    }

    @Test("Condition nodes beyond the left-hand side are searched in the overlap graph")
    func conditionSearch() async throws {
        let rules = try await Fixtures.bankRules()
        let result = analyser.conflicts(first: try rules.rule("createClient"), second: try rules.rule("createAccount"), granularity: .criticalPairs)
        #expect(!result.interacts)
        let recreate = analyser.dependencies(first: try rules.rule("deleteAccount"), second: try rules.rule("createAccount"), granularity: .criticalPairs)
        #expect(recreate.criticalPairs.count >= 1)
        #expect(recreate.criticalPairs.allSatisfy { $0.span.secondGraph == .negativeCondition(index: 0, name: "idTaken") })
    }
}
