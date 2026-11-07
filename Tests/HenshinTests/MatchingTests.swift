//
//  MatchingTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Builds rules over the bank metamodel in code.
struct BankRules {
    /// The classes and features of the bank metamodel.
    let bank: EClass, client: EClass, account: EClass
    /// The features used by the rules.
    let name: EAttribute, balance: EAttribute, id: EAttribute, accounts: EReference, clients: EReference
    /// The next node identity.
    private var next = 20_000

    /// Reads the metamodel from a loaded module.
    init(_ module: HenshinModule) throws {
        let createAccount = try #require(module.unit(named: "createAccount")?.rule)
        bank = createAccount.lhs.nodes[0].type
        client = createAccount.lhs.nodes[1].type
        account = createAccount.rhs.nodes[2].type
        name = try #require(client.getEAttribute(name: "name"))
        balance = try #require(account.getEAttribute(name: "balance"))
        id = try #require(account.getEAttribute(name: "id"))
        accounts = try #require(client.getEReference(name: "accounts"))
        clients = try #require(bank.getEReference(name: "clients"))
    }

    /// A fresh node.
    mutating func node(_ type: EClass, name: String? = nil, _ attributes: [(EAttribute, String)] = []) -> RuleNode {
        next += 1
        return RuleNode(id: NodeID(next), name: name, type: type, attributes: attributes.map { RuleAttribute(feature: $0.0, value: $0.1) })
    }

    /// A rule that matches a graph and changes nothing: its right-hand side preserves every
    /// node and edge of the left-hand side.
    mutating func identity(_ name: String, _ lhs: RuleGraph, parameters: [UnitParameter] = [], injective: Bool = true) -> Rule {
        var images: [NodeID: NodeID] = [:]
        var nodes: [RuleNode] = []
        for original in lhs.nodes {
            let copy = node(original.type, name: original.name)
            images[original.id] = copy.id
            nodes.append(copy)
        }
        let edges = lhs.edges.compactMap { edge in
            images[edge.source].flatMap { s in images[edge.target].map { RuleEdge(source: s, target: $0, type: edge.type) } }
        }
        return Rule(
            name: name, parameters: parameters, lhs: lhs, rhs: RuleGraph(nodes: nodes, edges: edges),
            mappings: lhs.nodes.compactMap { original in images[original.id].map { NodeMapping(origin: original.id, image: $0) } },
            injectiveMatching: injective)
    }

    /// A condition requiring that the matched account `host` is owned by a client with a name.
    mutating func ownedBy(_ host: RuleNode, _ owner: String) -> Formula {
        let image = node(account)
        let holder = node(client, [(name, "'\(owner)'")])
        return .condition(
            NestedCondition(
                conclusion: RuleGraph(nodes: [image, holder], edges: [RuleEdge(source: holder.id, target: image.id, type: accounts)]),
                mappings: [NodeMapping(origin: host.id, image: image.id)]))
    }

    /// A condition requiring that the matched account `host` has a balance.
    mutating func hasBalance(_ host: RuleNode, _ value: Int) -> Formula {
        let image = node(account, [(balance, "\(value)")])
        return .condition(NestedCondition(conclusion: RuleGraph(nodes: [image]), mappings: [NodeMapping(origin: host.id, image: image.id)]))
    }
}

/// Tests of match finding.
@Suite("Matching")
struct MatchingTests {
    let engine = HenshinEngine()

    /// The ids of the accounts that a single-node rule matches.
    func matchedIDs(_ rule: Rule, _ bank: Fixtures.Bank, engine: HenshinEngine = HenshinEngine()) async throws -> [Int] {
        var ids: [Int] = []
        for match in try await engine.findMatches(of: rule, in: bank.model) {
            let object = try #require(match.nodes[rule.lhs.nodes[0].id])
            ids.append(try #require(await bank.model.resolve(object) as? DynamicEObject).eGet("id") as? Int ?? -1)
        }
        return ids
    }

    @Test("Injective matching maps distinct nodes to distinct objects")
    func injectivity() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let pair = RuleGraph(nodes: [rules.node(rules.client), rules.node(rules.client)])
        #expect(try await engine.findMatches(of: rules.identity("pairs", pair), in: bank.model).count == 2)
        #expect(try await engine.findMatches(of: rules.identity("pairs", pair, injective: false), in: bank.model).count == 4)
        let override = HenshinEngine(options: EngineOptions(injectiveMatching: false))
        #expect(try await override.findMatches(of: rules.identity("pairs", pair), in: bank.model).count == 4)
        #expect(try await engine.findMatches(of: rules.identity("pairs", pair), in: bank.model, limit: 1).count == 1)
    }

    @Test("Formulas combine nested conditions", arguments: ["true", "or", "and", "xor", "not", "notOr"])
    func formulas(kind: String) async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let host = rules.node(rules.account)
        let bob = rules.ownedBy(host, "Bob")
        let empty = rules.hasBalance(host, 0)
        let formula: Formula
        let expected: [Int]
        switch kind {
        case "true": (formula, expected) = (.true, [1, 2, 3])
        case "or": (formula, expected) = (.or(bob, empty), [2, 3])
        case "and": (formula, expected) = (.and(bob, empty), [3])
        case "xor": (formula, expected) = (.xor(bob, empty), [2])
        case "not": (formula, expected) = (.not(bob), [1])
        default: (formula, expected) = (.not(.or(bob, empty)), [1])
        }
        let rule = rules.identity(kind, RuleGraph(nodes: [host], formula: formula))
        #expect(try await matchedIDs(rule, bank) == expected)
    }

    @Test("Conditions nest within conditions")
    func nestedConditions() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let host = rules.node(rules.account)
        let image = rules.node(rules.account)
        let owner = rules.node(rules.client)
        let ownerAgain = rules.node(rules.client)
        let other = rules.node(rules.account)
        let inner = Formula.condition(
            NestedCondition(
                conclusion: RuleGraph(nodes: [ownerAgain, other], edges: [RuleEdge(source: ownerAgain.id, target: other.id, type: rules.accounts)]),
                mappings: [NodeMapping(origin: owner.id, image: ownerAgain.id)]))
        let outer = Formula.condition(
            NestedCondition(
                conclusion: RuleGraph(
                    nodes: [image, owner], edges: [RuleEdge(source: owner.id, target: image.id, type: rules.accounts)], formula: .not(inner)),
                mappings: [NodeMapping(origin: host.id, image: image.id)]))
        let rule = rules.identity("soleAccount", RuleGraph(nodes: [host], formula: outer))
        #expect(try await matchedIDs(rule, bank) == [1])
    }

    @Test("Deterministic matching follows the order of the resource; seeded matching is reproducible")
    func determinism() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let rule = rules.identity("all", RuleGraph(nodes: [rules.node(rules.account)]))
        #expect(try await matchedIDs(rule, bank) == [1, 2, 3])
        let seeded = HenshinEngine(options: EngineOptions(deterministic: false, randomSeed: 7))
        let first = try await matchedIDs(rule, bank, engine: seeded)
        let second = try await matchedIDs(rule, bank, engine: seeded)
        #expect(first == second)
        #expect(first.sorted() == [1, 2, 3])
    }

    @Test("Attribute expressions in the left-hand side wait for their parameters")
    func deferredExpression() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let rich = rules.node(rules.account, [(rules.balance, "y * 2")])
        let poor = rules.node(rules.account, [(rules.balance, "y")])
        let rule = rules.identity(
            "double", RuleGraph(nodes: [rich, poor]), parameters: [UnitParameter(name: "y", kind: .var)])
        let matches = try await engine.findMatches(of: rule, in: bank.model)
        #expect(matches.count == 1, "only 100 = 50 * 2 holds for two distinct accounts")
        #expect(matches.compactMap { $0.parameters["y"] as? Int } == [50])
        let lenient = try await engine.findMatches(of: rules.identity("double", RuleGraph(nodes: [rich, poor]),
            parameters: [UnitParameter(name: "y", kind: .var)], injective: false), in: bank.model)
        #expect(Set(lenient.compactMap { $0.parameters["y"] as? Int }) == [50, 0], "0 = 0 * 2 once one account may match both nodes")
    }

    @Test("A parameter that never receives a value is reported")
    func unboundParameter() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let lhs = rules.node(rules.account)
        let rhs = rules.node(rules.account, [(rules.balance, "q + 1")])
        let rule = Rule(
            name: "unbound", parameters: [UnitParameter(name: "q", kind: .var)], lhs: RuleGraph(nodes: [lhs]),
            rhs: RuleGraph(nodes: [rhs]), mappings: [NodeMapping(origin: lhs.id, image: rhs.id)])
        await #expect(throws: HenshinError.unboundParameter(expression: "q + 1", parameter: "q")) {
            _ = try await engine.apply(rule, to: bank.model)
        }
    }

    @Test("The search plan starts from bound nodes and follows references")
    func plan() async throws {
        let bank = try await Fixtures.bank()
        let rule = try #require(bank.module.unit(named: "deleteAccount")?.rule)
        var session = await ApplicationSession(module: bank.module, resource: bank.model, options: EngineOptions())
        let compiled = try session.compile(rule, unit: nil)
        let unbound = session.makePlan(compiled.lhs, bound: [])
        #expect(unbound.first.map { compiled.lhs.nodes[$0.node].type.name } == "Bank", "the single bank is the smallest extent")
        let fromAccount = session.makePlan(compiled.lhs, bound: [2])
        #expect(fromAccount.map(\.node) == [2, 0, 1] || fromAccount.map(\.node) == [2, 1, 0])
        guard case .fixed = fromAccount[0].source else {
            Issue.record("a bound node comes first")
            return
        }
        for step in fromAccount.dropFirst() {
            if case .backward(let from, _) = step.source { #expect(from == 2) } else { Issue.record("expected navigation to the account's container or owner") }
        }
        #expect(fromAccount.flatMap(\.edgeChecks).count == 2)
    }

    @Test("Search statistics count the work")
    func statistics() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "deleteAccount", of: bank.module, to: bank.model, parameters: ["id": 2])
        #expect(result.statistics.searches == 1)
        #expect(result.statistics.candidates > 0)
        #expect(result.statistics.candidates <= 6)
    }
}
