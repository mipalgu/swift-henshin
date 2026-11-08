//
//  SuccessorEquivalenceTests.swift
//  HenshinStateSpaceTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Henshin
import Testing

@testable import HenshinStateSpace

/// Tests that the successors of states are those reached by applying each pinned rule to a
/// fresh copy of the state's model.
@Suite("Successor equivalence")
struct SuccessorEquivalenceTests {
    /// An exploration to compare: the loaded files and the explorer.
    struct Scenario {
        /// The name of the scenario, for failure messages.
        let name: String
        /// The loaded files.
        let loaded: Fixtures.Loaded
        /// The explorer.
        let explorer: StateSpaceExplorer
    }

    /// The board of three cells, each stepping through three states.
    static func cells() async throws -> Fixtures.Loaded {
        try await Fixtures.load("cells.henshin", metamodel: "cells.ecore", model: "cells-3.xmi")
    }

    /// The explorations to compare.
    static func scenarios() async throws -> [Scenario] {
        let cells = try await cells()
        let ring = try await Fixtures.ring()
        let bank = try await Fixtures.bank()
        let empty = try await Fixtures.graph("graph-empty.xmi")
        let chain = try await Fixtures.graph("graph-chain.xmi")
        let identity = ExplorationOptions(equivalence: .identity, concurrency: 1)
        let deposits = ExplorationOptions(maximumDepth: 3, parameterValues: ["deposit": [["id": 1, "amount": 10], ["id": 2, "amount": 5]]])
        var inactive = try cells.module.rule("ab")
        inactive.isActivated = false
        let clients = ExplorationOptions(maximumDepth: 2, parameterValues: ["createClient": [["name": "Carol"]]])
        return [
            Scenario(name: "cells", loaded: cells, explorer: try StateSpaceExplorer(module: cells.module)),
            Scenario(name: "cells by identity", loaded: cells, explorer: try StateSpaceExplorer(module: cells.module, options: identity)),
            Scenario(
                name: "cells with an inactive rule", loaded: cells,
                explorer: StateSpaceExplorer(rules: [inactive, try cells.module.rule("bc"), try cells.module.rule("ca")])),
            Scenario(name: "ring", loaded: ring, explorer: try StateSpaceExplorer(module: ring.module, rules: ExplorationTests.protocolRules)),
            Scenario(
                name: "ring in seeded random order", loaded: ring,
                explorer: try StateSpaceExplorer(
                    module: ring.module, rules: ExplorationTests.protocolRules,
                    options: ExplorationOptions(engineOptions: EngineOptions(deterministic: false, randomSeed: 7)))),
            Scenario(name: "freeze", loaded: bank, explorer: try StateSpaceExplorer(module: bank.module, rules: ["freezeOwned", "dormant"])),
            Scenario(name: "deposit", loaded: bank, explorer: try StateSpaceExplorer(module: bank.module, rules: ["deposit"], options: deposits)),
            Scenario(
                name: "clients", loaded: bank,
                explorer: try StateSpaceExplorer(module: bank.module, rules: ["createClient", "deleteAccount"], units: ["freezeAll"], options: clients)),
            Scenario(
                name: "nodes", loaded: empty,
                explorer: StateSpaceExplorer(
                    rules: [try empty.module.rule("createNode"), try empty.module.rule("mark")], options: ExplorationOptions(maximumDepth: 3))),
            Scenario(
                name: "chain", loaded: chain,
                explorer: StateSpaceExplorer(
                    rules: try ["propagate", "deleteNext", "addNext", "deleteNode"].map { try chain.module.rule($0) },
                    options: ExplorationOptions(maximumDepth: 3))),
        ]
    }

    /// The successors of a state, found by applying the pinned form of each rule at each
    /// match to a fresh copy of the state's model.
    ///
    /// - Parameters:
    ///   - model: The model of the state.
    ///   - explorer: The explorer whose rules, units and options apply.
    ///   - worker: The resource to apply rules in.
    /// - Returns: The successors, rules first and in order, then units.
    static func pinnedSuccessors(of model: ResourceSnapshot, explorer: StateSpaceExplorer, worker: Resource) async throws -> [Successor] {
        let engine = HenshinEngine(options: explorer.options.engineOptions)
        var result: [Successor] = []
        for rule in explorer.rules.map(PinnedRule.init) {
            for given in explorer.options.parameterValues[rule.original.name] ?? [[:]] {
                await worker.restore(model)
                for match in try await engine.findMatches(of: rule.original, in: worker, parameters: given) {
                    await worker.restore(model)
                    let application = try await engine.apply(rule.rule, to: worker, parameters: rule.arguments(for: match, given: given))
                    guard application.succeeded else { continue }
                    let successor = await worker.snapshot()
                    var parameters = given
                    for (name, value) in rule.reportedParameters(match) { parameters[name] = value }
                    result.append(
                        Successor(
                            label: rule.original.name, isUnit: false, match: rule.reportedMatch(match), parameters: parameters,
                            model: successor, graph: StateGraph(successor)))
                }
            }
        }
        for name in explorer.units {
            for given in explorer.options.parameterValues[name] ?? [[:]] {
                await worker.restore(model)
                let application = try await engine.apply(unitNamed: name, of: explorer.module, to: worker, parameters: given)
                guard application.succeeded else { continue }
                let successor = await worker.snapshot()
                result.append(
                    Successor(
                        label: name, isUnit: true, match: [:], parameters: given.merging(application.parameters) { $1 },
                        model: successor, graph: StateGraph(successor)))
            }
        }
        return result
    }

    /// Parameter values as sorted text, with object identities included.
    ///
    /// - Parameter values: The parameter values.
    /// - Returns: One `name=value` entry per value.
    static func text(_ values: ParameterValues) -> [String] {
        values.map { "\($0.key)=\($0.value)" }.sorted()
    }

    @Test("Every state has the successors that pinned rule application reaches")
    func successorsMatchPinnedApplication() async throws {
        for scenario in try await Self.scenarios() {
            let space = try await scenario.explorer.explore(from: scenario.loaded.model)
            let resourceSet = await scenario.loaded.model.resourceSet
            let worker = Resource(uri: "equivalence://worker")
            await worker.setResourceSet(resourceSet)
            let pinned = scenario.explorer.rules.map(PinnedRule.init)
            var compared = 0
            for state in space.states {
                let found = try await scenario.explorer.successors(of: state.model, pinned: pinned, worker: worker)
                let expected = try await Self.pinnedSuccessors(of: state.model, explorer: scenario.explorer, worker: worker)
                #expect(found.count == expected.count, "\(scenario.name), state \(state.id)")
                for (successor, reference) in zip(found, expected) {
                    #expect(successor.label == reference.label, "\(scenario.name)")
                    #expect(successor.isUnit == reference.isUnit, "\(scenario.name)")
                    #expect(successor.match == reference.match, "\(scenario.name)")
                    #expect(Self.text(successor.parameters) == Self.text(reference.parameters), "\(scenario.name)")
                    #expect(successor.graph.certificate == reference.graph.certificate, "\(scenario.name)")
                    #expect(successor.graph.isomorphism(to: reference.graph) != nil, "\(scenario.name)")
                    if Set(successor.graph.objects) == Set(reference.graph.objects) {
                        #expect(successor.graph.identityForm == reference.graph.identityForm, "\(scenario.name)")
                    }
                    compared += 1
                }
            }
            #expect(compared > 0, "\(scenario.name)")
        }
    }

    @Test("Three cells of three states each give 27 states and 81 transitions")
    func cellStateSpace() async throws {
        let cells = try await Self.cells()
        for equivalence in StateEquivalence.allCases {
            let options = ExplorationOptions(equivalence: equivalence, concurrency: 1)
            let space = try await StateSpaceExplorer(module: cells.module, options: options).explore(from: cells.model)
            #expect(space.states.count == 27)
            #expect(space.transitions.count == 81)
            #expect(space.isComplete)
            #expect(space.deadlocks.isEmpty)
            #expect(Set(space.states.map(\.certificate)).count == 27)
            #expect(space.transitions.filter { $0.source == 0 }.map(\.label) == ["ab", "ab", "ab"])
        }
    }
}
