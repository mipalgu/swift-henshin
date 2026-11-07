//
//  RuleApplicationTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of applying single rules.
@Suite("Rule application")
struct RuleApplicationTests {
    let engine = HenshinEngine()

    @Test("A rule creates an object with attributes and references, and returns it")
    func create() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "createAccount", of: bank.module, to: bank.model, parameters: ["client": "Alice", "accountId": 4])
        #expect(result.succeeded)
        #expect(result.appliedRules.map(\.ruleName) == ["createAccount"])
        let account = try #require(await BankQueries.account(4, in: bank.model))
        #expect(result.parameters["account"] as? EUUID == account.id)
        #expect(account.eGet("balance") as? Int == 0)
        #expect(account.eGet("frozen") as? Bool == false)
        let alice = try #require(await BankQueries.client("Alice", in: bank.model))
        #expect(ModelGraph.identifiers(alice.eGet("accounts")).contains(account.id))
        #expect(ModelGraph.identifiers(account.eGet("owner")) == [alice.id])
        let theBank = try #require(await BankQueries.objects("Bank", in: bank.model).first)
        #expect(ModelGraph.identifiers(theBank.eGet("accounts")).last == account.id)
        #expect(await bank.model.getRootObjects().count == 1)
        let application = try #require(result.appliedRules.first)
        #expect(application.createdObjects == [account.id])
        #expect(application.deletedObjects.isEmpty)
        #expect(!application.changes.isEmpty)
    }

    @Test("The created model equals the expected model")
    func expectedModel() async throws {
        let bank = try await Fixtures.bank()
        _ = try await engine.apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model,
            parameters: ["client": "Alice", "accountId": 4, "amount": 25])
        let expected = try await Fixtures.model("bank-after-open.xmi", in: bank.resourceSet)
        #expect(await ModelDescription.of(bank.model) == ModelDescription.of(expected))
    }

    @Test("A negative application condition blocks a rule")
    func negativeCondition() async throws {
        let bank = try await Fixtures.bank()
        let before = await ModelDescription.of(bank.model)
        let result = try await engine.apply(
            unitNamed: "createAccount", of: bank.module, to: bank.model, parameters: ["client": "Bob", "accountId": 2])
        #expect(!result.succeeded)
        #expect(result.appliedRules.isEmpty)
        #expect(await ModelDescription.of(bank.model) == before)
    }

    @Test("A rule without a match fails without changes")
    func noMatch() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "createAccount", of: bank.module, to: bank.model, parameters: ["client": "Nobody", "accountId": 9])
        #expect(!result.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
    }

    @Test("Attribute expressions compute new values and conditions guard rules")
    func attributes() async throws {
        let bank = try await Fixtures.bank()
        let deposit = try await engine.apply(
            unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 2, "amount": 15])
        #expect(deposit.succeeded)
        #expect(deposit.appliedRules.first?.parameters["x"] as? Int == 50)
        #expect(deposit.parameters["x"] == nil, "the values of VAR parameters are hidden from the caller")
        #expect(await BankQueries.balance(2, in: bank.model) == 65)
        let negative = try await engine.apply(
            unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 2, "amount": -5])
        #expect(!negative.succeeded)
        #expect(await BankQueries.balance(2, in: bank.model) == 65)
        #expect(deposit.statistics.queries >= 1)
    }

    @Test("Values move between objects and conditions see bound parameters")
    func move() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "transfer", of: bank.module, to: bank.model, parameters: ["from": 1, "to": 3, "amount": 30])
        #expect(result.succeeded)
        #expect(await BankQueries.balance(1, in: bank.model) == 70)
        #expect(await BankQueries.balance(3, in: bank.model) == 30)
        let overdrawn = try await engine.apply(
            unitNamed: "transfer", of: bank.module, to: bank.model, parameters: ["from": 3, "to": 1, "amount": 31])
        #expect(!overdrawn.succeeded)
    }

    @Test("Text values are concatenated and transformed")
    func text() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "suffixName", of: bank.module, to: bank.model, parameters: ["name": "Bob", "suffix": "jr"])
        #expect(result.succeeded)
        #expect(await BankQueries.client("Bob JR", in: bank.model) != nil)
    }

    @Test("Deleting an object with its references satisfies the dangling condition")
    func delete() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "deleteAccount", of: bank.module, to: bank.model, parameters: ["id": 3])
        #expect(result.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2])
        let bob = try #require(await BankQueries.client("Bob", in: bank.model))
        #expect(ModelGraph.identifiers(bob.eGet("accounts")).count == 1)
        #expect(result.appliedRules.first?.deletedObjects.count == 1)
    }

    @Test("The dangling condition blocks deleting a referenced object")
    func dangling() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "removeAccountOnly", of: bank.module, to: bank.model, parameters: ["id": 3])
        #expect(!result.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
    }

    @Test("Without the dangling condition, references to a deleted object are removed")
    func purge() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "purgeAccount", of: bank.module, to: bank.model, parameters: ["id": 3])
        #expect(result.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2])
        let bob = try #require(await BankQueries.client("Bob", in: bank.model))
        #expect(ModelGraph.identifiers(bob.eGet("accounts")).count == 1)
        let theBank = try #require(await BankQueries.objects("Bank", in: bank.model).first)
        #expect(ModelGraph.identifiers(theBank.eGet("accounts")).count == 2)
    }

    @Test("An engine option can turn the dangling condition off for every rule")
    func danglingOverride() async throws {
        let bank = try await Fixtures.bank()
        let lenient = HenshinEngine(options: EngineOptions(checkDangling: false))
        let result = try await lenient.apply(unitNamed: "removeAccountOnly", of: bank.module, to: bank.model, parameters: ["id": 1])
        #expect(result.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [2, 3])
    }

    @Test("A multi-rule deletes every account of a closed client")
    func multiRule() async throws {
        let bank = try await Fixtures.bank()
        let naive = try await engine.apply(unitNamed: "closeClientNaive", of: bank.module, to: bank.model, parameters: ["name": "Bob"])
        #expect(!naive.succeeded)
        let rule = try #require(bank.module.unit(named: "closeClient")?.rule)
        let matches = try await engine.findMatches(of: rule, in: bank.model, parameters: ["name": "Bob"])
        #expect(matches.count == 1)
        #expect(matches.first?.multiMatches.first?.count == 2)
        let result = try await engine.apply(unitNamed: "closeClient", of: bank.module, to: bank.model, parameters: ["name": "Bob"])
        #expect(result.succeeded)
        #expect(await BankQueries.client("Bob", in: bank.model) == nil)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1])
        #expect(result.appliedRules.first?.deletedObjects.count == 3)
        let expected = try await Fixtures.model("bank-after-close.xmi", in: bank.resourceSet)
        #expect(await ModelDescription.of(bank.model) == ModelDescription.of(expected))
    }

    @Test("A multi-rule without matches leaves the kernel to apply alone")
    func emptyMultiRule() async throws {
        let bank = try await Fixtures.bank()
        _ = try await engine.apply(unitNamed: "createClient", of: bank.module, to: bank.model, parameters: ["name": "Carol"])
        let result = try await engine.apply(unitNamed: "closeClient", of: bank.module, to: bank.model, parameters: ["name": "Carol"])
        #expect(result.succeeded)
        #expect(await BankQueries.client("Carol", in: bank.model) == nil)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
    }

    @Test("A positive application condition requires its conclusion")
    func positiveCondition() async throws {
        let bank = try await Fixtures.bank()
        let rule = try #require(bank.module.unit(named: "freezeOwned")?.rule)
        #expect(try await engine.findMatches(of: rule, in: bank.model).count == 3)
        _ = try await engine.apply(unitNamed: "purgeAccount", of: bank.module, to: bank.model, parameters: ["id": 2])
        _ = try await engine.apply(unitNamed: "createClient", of: bank.module, to: bank.model, parameters: ["name": "Carol"])
        let orphan = try await engine.apply(
            HenshinModuleFactory.orphanAccountRule(module: bank.module), to: bank.model, parameters: ["id": 7])
        #expect(orphan.succeeded)
        let matches = try await engine.findMatches(of: rule, in: bank.model)
        #expect(matches.count == 2)
    }

    @Test("Negative conditions over two mapped nodes forbid an edge between them")
    func edgeCondition() async throws {
        let bank = try await Fixtures.bank()
        let first = try await engine.apply(unitNamed: "befriend", of: bank.module, to: bank.model, parameters: ["x": "Alice", "y": "Bob"])
        #expect(first.succeeded)
        let second = try await engine.apply(unitNamed: "befriend", of: bank.module, to: bank.model, parameters: ["x": "Alice", "y": "Bob"])
        #expect(!second.succeeded)
        let reverse = try await engine.apply(unitNamed: "befriend", of: bank.module, to: bank.model, parameters: ["x": "Bob", "y": "Alice"])
        #expect(reverse.succeeded)
        let selfish = try await engine.apply(unitNamed: "befriend", of: bank.module, to: bank.model, parameters: ["x": "Bob", "y": "Bob"])
        #expect(!selfish.succeeded)
    }

    @Test("A deactivated rule succeeds without effect")
    func dormant() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "dormant", of: bank.module, to: bank.model)
        #expect(result.succeeded)
        #expect(result.appliedRules.isEmpty)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
    }

    @Test("Missing and unexpected parameters are reported")
    func parameters() async throws {
        let bank = try await Fixtures.bank()
        await #expect(throws: HenshinError.missingParameter(unit: "deposit", parameter: "amount")) {
            _ = try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 1])
        }
        await #expect(throws: HenshinError.invalidParameter(unit: "deposit", parameter: "x")) {
            _ = try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 1, "amount": 1, "x": 3])
        }
        await #expect(throws: HenshinError.invalidParameter(unit: "deposit", parameter: "bogus")) {
            _ = try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["bogus": 1])
        }
        await #expect(throws: HenshinError.unknownUnit("nothing")) {
            _ = try await engine.apply(unitNamed: "nothing", of: bank.module, to: bank.model)
        }
    }

    @Test("A node named like a value parameter is not bound to the value")
    func nodeNamedLikeValueParameter() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let lhs = rules.node(rules.client, name: "client", [(rules.name, "client")])
        let rhs = rules.node(rules.client, name: "client", [(rules.name, "client + '!'")])
        let rule = Rule(
            name: "exclaim", parameters: [UnitParameter(name: "client", kind: .in)], lhs: RuleGraph(nodes: [lhs]),
            rhs: RuleGraph(nodes: [rhs]), mappings: [NodeMapping(origin: lhs.id, image: rhs.id)])
        let result = try await engine.apply(rule, to: bank.model, parameters: ["client": "Bob"])
        #expect(result.succeeded)
        #expect(await BankQueries.client("Bob!", in: bank.model) != nil)
    }

    @Test("Object parameters fix nodes to given objects")
    func objectParameter() async throws {
        let bank = try await Fixtures.bank()
        let found = try await engine.apply(unitNamed: "hasClient", of: bank.module, to: bank.model, parameters: ["name": "Bob"])
        let bob = try #require(found.parameters["client"] as? EUUID)
        #expect(bob == (await BankQueries.client("Bob", in: bank.model))?.id)
        let rule = try #require(bank.module.unit(named: "hasClient")?.rule)
        let alice = try #require(await BankQueries.client("Alice", in: bank.model))
        let matches = try await engine.findMatches(of: rule, in: bank.model, parameters: ["name": "Bob", "client": alice])
        #expect(matches.isEmpty)
        let aliceMatches = try await engine.findMatches(of: rule, in: bank.model, parameters: ["client": alice.id])
        #expect(aliceMatches.count == 1)
        #expect(aliceMatches.first?.parameters["name"] as? String == "Alice")
        let unknown = try await engine.findMatches(of: rule, in: bank.model, parameters: ["client": EUUID()])
        #expect(unknown.isEmpty)
    }
}

/// Rules built in code for tests that need variations of the document's rules.
enum HenshinModuleFactory {
    /// A rule that creates an account without owner inside the bank.
    ///
    /// - Parameter module: The loaded bank module, whose types the rule reuses.
    /// - Returns: The rule, with an input parameter `id`.
    static func orphanAccountRule(module: HenshinModule) throws -> Rule {
        let createAccount = try #require(module.unit(named: "createAccount")?.rule)
        let bankType = try #require(createAccount.lhs.nodes.first?.type)
        let accountNode = try #require(createAccount.rhs.node(named: "account"))
        let accounts = try #require(createAccount.rhs.edges.first { $0.type.name == "accounts" && $0.source == createAccount.rhs.nodes[0].id })
        let idFeature = try #require(accountNode.attribute(named: "id")?.feature)
        let lhsBank = RuleNode(id: NodeID(10_000), type: bankType)
        let rhsBank = RuleNode(id: NodeID(10_001), type: bankType)
        let account = RuleNode(id: NodeID(10_002), type: accountNode.type, attributes: [RuleAttribute(feature: idFeature, value: "id")])
        return Rule(
            name: "createOrphanAccount", parameters: [UnitParameter(name: "id", kind: .in)],
            lhs: RuleGraph(nodes: [lhsBank]),
            rhs: RuleGraph(nodes: [rhsBank, account], edges: [RuleEdge(source: rhsBank.id, target: account.id, type: accounts.type)]),
            mappings: [NodeMapping(origin: lhsBank.id, image: rhsBank.id)])
    }
}
