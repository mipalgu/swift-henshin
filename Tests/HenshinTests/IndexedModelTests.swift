//
//  IndexedModelTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of matching and applying rules through an indexed model.
@Suite("Indexed models")
struct IndexedModelTests {
    let engine = HenshinEngine()

    /// The rules and parameter values that the comparisons with the engine use.
    static let applications: [(rule: String, parameters: ParameterValues)] = [
        ("deposit", ["id": 2, "amount": 15]),
        ("createAccount", ["client": "Alice", "accountId": 4]),
        ("deleteAccount", ["id": 3]),
        ("freezeOwned", [:]),
        ("addBonus", ["id": 1]),
    ]

    /// The rule of a module with a name, failing the test if there is none.
    ///
    /// - Parameters:
    ///   - name: The name of the rule.
    ///   - module: The module.
    /// - Returns: The rule.
    func rule(_ name: String, of module: HenshinModule) throws -> Rule {
        try #require(module.unit(named: name)?.rule)
    }

    /// Describes the model of a snapshot as ``ModelDescription`` describes a resource.
    ///
    /// - Parameter snapshot: The snapshot.
    /// - Returns: The canonical description.
    func describe(_ snapshot: ResourceSnapshot) async -> String {
        let resource = Resource()
        await resource.restore(snapshot)
        return await ModelDescription.of(resource)
    }

    /// The parameter values that are not object identities, as sorted text.
    ///
    /// - Parameter values: The parameter values.
    /// - Returns: One `name=value` entry per value.
    func plainValues(_ values: ParameterValues) -> [String] {
        values.filter { !($0.value is EUUID) }.map { "\($0.key)=\($0.value)" }.sorted()
    }

    @Test("Applying at a found match changes the model as applying the rule does")
    func sameAsEngine() async throws {
        for (name, parameters) in Self.applications {
            let applied = try await Fixtures.bank()
            let expected = try await engine.apply(unitNamed: name, of: applied.module, to: applied.model, parameters: parameters)
            let bank = try await Fixtures.bank()
            let rule = try rule(name, of: bank.module)
            var indexed = await engine.index(bank.model)
            let match = try #require(try await indexed.findMatches(of: rule, parameters: parameters, limit: 1).first)
            let result = try await indexed.apply(rule, at: match, parameters: parameters)
            #expect(result.succeeded == expected.succeeded, "\(name)")
            #expect(result.unitName == expected.unitName)
            #expect(result.appliedRules.map(\.ruleName) == expected.appliedRules.map(\.ruleName))
            #expect(plainValues(result.parameters) == plainValues(expected.parameters), "\(name)")
            #expect(
                plainValues(result.appliedRules.first?.parameters ?? [:]) == plainValues(expected.appliedRules.first?.parameters ?? [:]),
                "\(name)")
            #expect(result.appliedRules.first?.createdObjects.count == expected.appliedRules.first?.createdObjects.count)
            #expect(result.appliedRules.first?.deletedObjects.count == expected.appliedRules.first?.deletedObjects.count)
            let expectedModel = await ModelDescription.of(applied.model)
            #expect(await ModelDescription.of(bank.model) == expectedModel, "\(name)")
            #expect(await describe(indexed.model) == expectedModel, "\(name)")
        }
    }

    @Test("Matches found through the index are those that the engine finds")
    func sameMatches() async throws {
        let bank = try await Fixtures.bank()
        var indexed = await engine.index(bank.model)
        for (name, parameters) in Self.applications {
            let rule = try rule(name, of: bank.module)
            let found = try await indexed.findMatches(of: rule, parameters: parameters)
            let expected = try await engine.findMatches(of: rule, in: bank.model, parameters: parameters)
            #expect(found.map(\.nodes) == expected.map(\.nodes), "\(name)")
            #expect(found.map { plainValues($0.parameters) } == expected.map { plainValues($0.parameters) }, "\(name)")
        }
        let limited = try await indexed.findMatches(of: try rule("freezeOwned", of: bank.module), limit: 2)
        #expect(limited.count == 2)
    }

    @Test("Each match applies to the indexed model, independently of the others")
    func everyMatch() async throws {
        let bank = try await Fixtures.bank()
        let freeze = try rule("freezeOwned", of: bank.module)
        var indexed = await engine.index(bank.model)
        let before = await describe(indexed.model)
        let matches = try await indexed.findMatches(of: freeze)
        #expect(matches.count == 3)
        var frozen: [EUUID] = []
        for match in matches {
            var step = indexed
            let result = try await step.apply(freeze, at: match)
            #expect(result.succeeded)
            let account = try #require(match.nodes.values.first)
            frozen.append(account)
            let accounts = step.model.objects.compactMap { $0 as? DynamicEObject }.filter { $0.eClass.name == "Account" }
            #expect(accounts.filter { $0.eGet("frozen") as? Bool == true }.map(\.id) == [account])
            #expect(await describe(step.model) == describe(await bank.model.snapshot()))
        }
        #expect(Set(frozen).count == 3)
        #expect(await describe(indexed.model) == before, "applying a copy leaves the indexed model as it was")
    }

    @Test("The index follows the changes that its applications make")
    func followsChanges() async throws {
        let bank = try await Fixtures.bank()
        let create = try rule("createAccount", of: bank.module)
        let deposit = try rule("deposit", of: bank.module)
        let delete = try rule("deleteAccount", of: bank.module)
        var indexed = await engine.index(bank.model)
        #expect(try await indexed.findMatches(of: deposit, parameters: ["id": 4, "amount": 5]).isEmpty)
        let creation = try #require(try await indexed.findMatches(of: create, parameters: ["client": "Alice", "accountId": 4]).first)
        let created = try await indexed.apply(create, at: creation)
        #expect(created.succeeded)
        let account = try #require(created.appliedRules.first?.createdObjects.first)
        let funding = try await indexed.findMatches(of: deposit, parameters: ["id": 4, "amount": 5])
        #expect(funding.count == 1, "a newly created object is matched")
        #expect(funding.first?.nodes.values.contains(account) == true)
        #expect(try await indexed.apply(deposit, at: try #require(funding.first)).succeeded)
        #expect(await BankQueries.balance(4, in: bank.model) == 5)
        let fresh = try await engine.findMatches(of: deposit, in: bank.model, parameters: ["id": 4, "amount": 5])
        #expect(try await indexed.findMatches(of: deposit, parameters: ["id": 4, "amount": 5]).map(\.nodes) == fresh.map(\.nodes))
        let removal = try #require(try await indexed.findMatches(of: delete, parameters: ["id": 4]).first)
        #expect(try await indexed.apply(delete, at: removal).succeeded)
        #expect(try await indexed.findMatches(of: deposit, parameters: ["id": 4, "amount": 5]).isEmpty, "a deleted object is no longer matched")
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
        #expect(await describe(indexed.model) == ModelDescription.of(bank.model))
    }

    @Test("A match that no longer holds is not applied")
    func staleMatch() async throws {
        let bank = try await Fixtures.bank()
        let freeze = try rule("freezeOwned", of: bank.module)
        let delete = try rule("deleteAccount", of: bank.module)
        var indexed = await engine.index(bank.model)
        let match = try #require(try await indexed.findMatches(of: freeze).first)
        #expect(try await indexed.apply(freeze, at: match).succeeded)
        let frozen = await describe(indexed.model)
        let again = try await indexed.apply(freeze, at: match)
        #expect(!again.succeeded, "the frozen account no longer satisfies the left-hand side")
        #expect(again.appliedRules.isEmpty)
        #expect(await describe(indexed.model) == frozen)
        #expect(await ModelDescription.of(bank.model) == frozen)
        let removal = try #require(try await indexed.findMatches(of: delete, parameters: ["id": 3]).first)
        #expect(try await indexed.apply(delete, at: removal).succeeded)
        let removed = try await indexed.apply(delete, at: removal)
        #expect(!removed.succeeded, "the deleted account is not matched again")
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2])
    }

    @Test("A rule changes the indexed model, whatever the resource was changed to since")
    func indexedModelPrevails() async throws {
        let bank = try await Fixtures.bank()
        let freeze = try rule("freezeOwned", of: bank.module)
        var indexed = await engine.index(bank.model)
        let match = try #require(try await indexed.findMatches(of: freeze).first)
        let account = try #require(match.nodes.values.first)
        #expect(try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 2, "amount": 15]).succeeded)
        #expect(await BankQueries.balance(2, in: bank.model) == 65)
        #expect(try await indexed.apply(freeze, at: match).succeeded)
        #expect(await BankQueries.balance(2, in: bank.model) == 50)
        let frozen = await BankQueries.objects("Account", in: bank.model).filter { $0.eGet("frozen") as? Bool == true }.map(\.id)
        #expect(frozen == [account])
        #expect(await describe(indexed.model) == ModelDescription.of(bank.model))
    }

    @Test("An inactive rule succeeds without changes, as the engine applies it")
    func inactiveRule() async throws {
        let bank = try await Fixtures.bank()
        let dormant = try rule("dormant", of: bank.module)
        var indexed = await engine.index(bank.model)
        let before = await describe(indexed.model)
        let node = try #require(dormant.lhs.nodes.first?.id)
        let account = try #require(await BankQueries.account(1, in: bank.model)?.id)
        let result = try await indexed.apply(dormant, at: Match(ruleName: dormant.name, nodes: [node: account], parameters: [:]))
        let expected = try await engine.apply(dormant, to: bank.model)
        #expect(result.succeeded == expected.succeeded)
        #expect(result.appliedRules.isEmpty && expected.appliedRules.isEmpty)
        #expect(await describe(indexed.model) == before)
    }

    @Test("Parameter values are checked against the declared data types")
    func parameterTypes() async throws {
        let bank = try await Fixtures.bank()
        let deposit = try rule("deposit", of: bank.module)
        var indexed = await engine.index(bank.model)
        let match = try #require(try await indexed.findMatches(of: deposit, parameters: ["id": 2, "amount": 15]).first)
        await #expect(throws: HenshinError.self) {
            _ = try await indexed.findMatches(of: deposit, parameters: ["id": "two", "amount": 15])
        }
        await #expect(throws: HenshinError.self) {
            _ = try await indexed.apply(deposit, at: match, parameters: ["amount": "fifteen"])
        }
        #expect(await BankQueries.balance(2, in: bank.model) == 50)
        let result = try await indexed.apply(deposit, at: match)
        #expect(result.succeeded, "the match carries the values it was found with")
        #expect(await BankQueries.balance(2, in: bank.model) == 65)
        #expect(result.statistics.searches == 1)
    }
}
