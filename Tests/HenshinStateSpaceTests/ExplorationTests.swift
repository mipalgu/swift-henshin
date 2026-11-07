//
//  ExplorationTests.swift
//  HenshinStateSpaceTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin
import Testing

@testable import HenshinStateSpace

/// Tests of state-space exploration.
@Suite("Exploration")
struct ExplorationTests {
    static let protocolRules = ["request", "enter", "leave", "pass"]

    @Test("A token ring of three processes has 36 states, 12 up to rotation")
    func tokenRing() async throws {
        let ring = try await Fixtures.ring()
        let explorer = try StateSpaceExplorer(module: ring.module, rules: Self.protocolRules)
        let space = try await explorer.explore(from: ring.model)
        #expect(space.states.count == 12)
        #expect(space.transitions.count == 32)
        #expect(space.isComplete)
        #expect(space.deadlocks.isEmpty)
        #expect(space.statistics.expandedStates == 12)
        #expect(space.statistics.isomorphismChecks > 0)
        var options = ExplorationOptions(equivalence: .identity)
        options.concurrency = 1
        let identity = try await StateSpaceExplorer(module: ring.module, rules: Self.protocolRules, options: options)
            .explore(from: ring.model)
        #expect(identity.states.count == 36)
        #expect(identity.transitions.count == 96)
        #expect(identity.description == "36 states, 96 transitions, complete")
    }

    @Test("Exploration leaves the given model unchanged")
    func modelUnchanged() async throws {
        let ring = try await Fixtures.ring()
        let before = await ring.model.snapshot()
        _ = try await StateSpaceExplorer(module: ring.module, rules: Self.protocolRules).explore(from: ring.model)
        let after = await ring.model.snapshot()
        #expect(StateGraph(before).identityForm == StateGraph(after).identityForm)
    }

    @Test("The number of workers does not change the state space")
    func concurrency() async throws {
        let ring = try await Fixtures.ring()
        var spaces: [StateSpace] = []
        for workers in [1, 3, 8] {
            let options = ExplorationOptions(concurrency: workers)
            spaces.append(try await StateSpaceExplorer(module: ring.module, rules: Self.protocolRules, options: options).explore(from: ring.model))
        }
        for space in spaces.dropFirst() {
            #expect(space.states.map(\.certificate) == spaces[0].states.map(\.certificate))
            #expect(space.transitions.map(\.label) == spaces[0].transitions.map(\.label))
        }
    }

    @Test("States are numbered breadth first with shortest paths")
    func breadthFirst() async throws {
        let ring = try await Fixtures.ring()
        let space = try await StateSpaceExplorer(module: ring.module, rules: Self.protocolRules).explore(from: ring.model)
        #expect(space.states.map(\.depth) == space.states.map(\.depth).sorted())
        for state in space.states {
            #expect(space.path(to: state.id).count == state.depth)
        }
        #expect(space.path(to: 0).isEmpty)
        #expect(space.outgoing(0).count == 4)
        #expect(space.incoming(0).contains { $0.label == "leave" || $0.label == "pass" })
    }

    @Test("Bounds leave states open")
    func bounds() async throws {
        let graph = try await Fixtures.graph("graph-empty.xmi")
        let rules = [try graph.module.rule("createNode")]
        let byDepth = try await StateSpaceExplorer(rules: rules, options: ExplorationOptions(maximumDepth: 3)).explore(from: graph.model)
        #expect(byDepth.states.count == 4)
        #expect(byDepth.openStates == [3])
        #expect(!byDepth.isComplete)
        #expect(byDepth.states.map(\.objectCount) == [1, 2, 3, 4])
        let byCount = try await StateSpaceExplorer(rules: rules, options: ExplorationOptions(maximumStates: 2)).explore(from: graph.model)
        #expect(byCount.states.count == 2)
        #expect(byCount.openStates == [1])
        let bySize = try await StateSpaceExplorer(rules: rules, options: ExplorationOptions(maximumObjects: 2)).explore(from: graph.model)
        #expect(bySize.states.count == 3)
        #expect(bySize.openStates == [2])
    }

    @Test("Identity and isomorphism differ when rules create objects")
    func createdObjects() async throws {
        let graph = try await Fixtures.graph("graph-empty.xmi")
        let rules = [try graph.module.rule("createNode"), try graph.module.rule("mark")]
        let iso = try await StateSpaceExplorer(rules: rules, options: ExplorationOptions(maximumDepth: 3)).explore(from: graph.model)
        #expect(iso.states.count == 6)
        let identity = try await StateSpaceExplorer(rules: rules, options: ExplorationOptions(maximumDepth: 3, equivalence: .identity))
            .explore(from: graph.model)
        #expect(identity.states.count == 8)
    }

    @Test("Bank: freezing owned accounts reaches every subset of frozen accounts")
    func bankFreeze() async throws {
        let bank = try await Fixtures.bank()
        let space = try await StateSpaceExplorer(module: bank.module, rules: ["freezeOwned"]).explore(from: bank.model)
        #expect(space.states.count == 8)
        #expect(space.transitions.count == 12)
        #expect(space.deadlocks.count == 1)
        let last = try #require(space.deadlocks.first)
        #expect(values(of: "Account", "frozen", in: space.states[last].model) == ["true", "true", "true"])
    }

    @Test("Units are applied as atomic steps")
    func units() async throws {
        let bank = try await Fixtures.bank()
        let space = try await StateSpaceExplorer(module: bank.module, rules: [], units: ["freezeAll"]).explore(from: bank.model)
        #expect(space.states.count == 2)
        #expect(space.transitions.count == 2)
        #expect(space.transitions.allSatisfy { $0.isUnit && $0.label == "freezeAll" })
        #expect(space.transitions[1].source == 1 && space.transitions[1].target == 1)
        #expect(throws: StateSpaceError.unknownUnit("missing")) {
            _ = try StateSpaceExplorer(module: bank.module, rules: [], units: ["missing"])
        }
        #expect(throws: StateSpaceError.unknownUnit("freezeAll")) {
            _ = try StateSpaceExplorer(module: bank.module, rules: ["freezeAll"])
        }
    }

    @Test("Parameter values are tried for each rule and reported on transitions")
    func parameters() async throws {
        let bank = try await Fixtures.bank()
        let options = ExplorationOptions(maximumDepth: 3, parameterValues: ["deposit": [["id": 1, "amount": 10], ["id": 2, "amount": 5]]])
        let space = try await StateSpaceExplorer(module: bank.module, rules: ["deposit"], options: options).explore(from: bank.model)
        #expect(space.states.count == 10)
        let first = try #require(space.outgoing(0).first)
        #expect(first.parameters["amount"] as? Int == 10)
        #expect(first.parameters["x"] == nil)
        #expect(first.match.count == 1)
        #expect(first.description.hasPrefix("deposit("))
    }

    @Test("A rule that needs a parameter value without one is reported")
    func unboundParameter() async throws {
        let bank = try await Fixtures.bank()
        await #expect(throws: StateSpaceError.unboundParameter(unit: "createClient", parameter: "name")) {
            _ = try await StateSpaceExplorer(module: bank.module, rules: ["createClient"], options: ExplorationOptions(maximumDepth: 1))
                .explore(from: bank.model)
        }
        let given = ExplorationOptions(maximumDepth: 2, parameterValues: ["createClient": [["name": "Carol"]]])
        let space = try await StateSpaceExplorer(module: bank.module, rules: ["createClient"], options: given).explore(from: bank.model)
        #expect(space.states.count == 2)
        #expect(space.deadlocks == [1])
        #expect(StateSpaceError.unboundParameter(unit: "u", parameter: "p").description.contains("u needs a value"))
        #expect(StateSpaceError.unknownUnit("u").description.contains("no rule or unit named u"))
        #expect(StateSpaceError.invalidProperty("x").description.contains("cannot be evaluated: x"))
    }

    @Test("Exploring all active rules of a module skips inactive ones")
    func activeRules() async throws {
        let bank = try await Fixtures.bank()
        let explorer = try StateSpaceExplorer(module: bank.module)
        #expect(!explorer.rules.contains { $0.name == "dormant" })
        #expect(explorer.rules.count == bank.module.rules.count - 1)
    }

    @Test("A path replays from the initial model to its state")
    func replay() async throws {
        let ring = try await Fixtures.ring()
        let space = try await StateSpaceExplorer(module: ring.module, rules: Self.protocolRules).explore(from: ring.model)
        let target = try #require(space.states.max { $0.depth < $1.depth })
        let path = space.path(to: target.id)
        let pinned = Dictionary(uniqueKeysWithValues: try Self.protocolRules.map { ($0, PinnedRule(try ring.module.rule($0))) })
        let model = await ring.model.snapshot()
        let resource = Resource()
        await resource.restore(model)
        for step in path {
            let rule = try #require(pinned[step.label])
            var arguments: ParameterValues = [:]
            for (node, name) in rule.parameters {
                if let object = step.match[rule.displayNames[node]!] { arguments[name] = object }
            }
            #expect(try await HenshinEngine().apply(rule.rule, to: resource, parameters: arguments).succeeded)
        }
        let reached = StateGraph(await resource.snapshot())
        #expect(reached.isomorphism(to: StateGraph(target.model)) != nil)
        #expect(reached.identityForm == StateGraph(target.model).identityForm)
    }

    @Test("The state space exports to GraphViz")
    func dot() async throws {
        let graph = try await Fixtures.graph("graph-chain.xmi")
        let space = try await StateSpaceExplorer(rules: [try graph.module.rule("propagate")]).explore(from: graph.model)
        #expect(space.states.count == 3)
        let dot = space.dot(name: "chain \"x\"", highlighted: [1])
        #expect(dot.hasPrefix("digraph \"chain \\\"x\\\"\" {"))
        #expect(dot.contains("s0 [label=\"0\", shape=doublecircle];"))
        #expect(dot.contains("s2 [label=\"2\", shape=box];"))
        #expect(dot.contains("style=\"bold\""))
        #expect(dot.contains("s0 -> s1 [label=\"propagate\"];"))
        let open = try await StateSpaceExplorer(rules: [try graph.module.rule("propagate")], options: ExplorationOptions(maximumDepth: 1))
            .explore(from: graph.model)
        #expect(open.dot().contains("style=\"dashed\""))
    }
}
