//
//  UnitApplicationTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of applying composite transformation units.
@Suite("Unit application")
struct UnitApplicationTests {
    let engine = HenshinEngine()

    @Test("A sequential unit passes parameters through and returns outputs")
    func sequential() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model,
            parameters: ["client": "Bob", "accountId": 7, "amount": 12])
        #expect(result.succeeded)
        #expect(result.appliedRules.map(\.ruleName) == ["createAccount", "deposit"])
        #expect(await BankQueries.balance(7, in: bank.model) == 12)
        let account = try #require(await BankQueries.account(7, in: bank.model))
        #expect(result.parameters["account"] as? EUUID == account.id)
        #expect(result.parameters["client"] == nil, "input parameters are not kept in the result")
        let description = await ModelDescription.of(bank.model)
        #expect(description.contains("Account(balance=12 frozen=false id=7 owner->[/0/clients.1])"))
    }

    @Test("A failing strict sequential unit rolls back what it did")
    func rollback() async throws {
        let bank = try await Fixtures.bank()
        let before = await ModelDescription.of(bank.model)
        let result = try await engine.apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model,
            parameters: ["client": "Alice", "accountId": 5, "amount": -1])
        #expect(!result.succeeded)
        #expect(result.appliedRules.isEmpty)
        #expect(await ModelDescription.of(bank.model) == before)
        #expect(result.diagnostics.contains { $0.code == HenshinDiagnosticCode.rolledBack.rawValue })
        let again = try await engine.apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model,
            parameters: ["client": "Alice", "accountId": 5, "amount": 3])
        #expect(again.succeeded, "the model and the engine's indices are usable after a rollback")
        #expect(await BankQueries.balance(5, in: bank.model) == 3)
    }

    @Test("A strict unit without rollback fails but keeps its changes")
    func noRollback() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "openAndFundKeep", of: bank.module, to: bank.model,
            parameters: ["client": "Alice", "accountId": 5, "amount": -1])
        #expect(!result.succeeded)
        #expect(result.appliedRules.map(\.ruleName) == ["createAccount"])
        #expect(await BankQueries.balance(5, in: bank.model) == 0)
    }

    @Test("A non-strict sequential unit succeeds if any sub-unit does")
    func loose() async throws {
        let bank = try await Fixtures.bank()
        let partly = try await engine.apply(
            unitNamed: "openAndFundLoose", of: bank.module, to: bank.model,
            parameters: ["client": "Alice", "accountId": 1, "amount": 5])
        #expect(partly.succeeded)
        #expect(partly.appliedRules.map(\.ruleName) == ["deposit"])
        #expect(await BankQueries.balance(1, in: bank.model) == 105)
        let neither = try await engine.apply(
            unitNamed: "openAndFundLoose", of: bank.module, to: bank.model,
            parameters: ["client": "Nobody", "accountId": 9, "amount": 5])
        #expect(!neither.succeeded)
    }

    @Test("A conditional unit takes the then branch or the else branch")
    func conditional() async throws {
        let bank = try await Fixtures.bank()
        let then = try await engine.apply(
            unitNamed: "ensureClientAccount", of: bank.module, to: bank.model, parameters: ["name": "Alice", "accountId": 8])
        #expect(then.succeeded)
        #expect(then.appliedRules.map(\.ruleName) == ["hasClient", "createAccount"])
        #expect(then.parameters["client"] as? EUUID == (await BankQueries.client("Alice", in: bank.model))?.id)
        let otherwise = try await engine.apply(
            unitNamed: "ensureClientAccount", of: bank.module, to: bank.model, parameters: ["name": "Dana", "accountId": 9])
        #expect(otherwise.succeeded)
        #expect(otherwise.appliedRules.map(\.ruleName) == ["createClient"])
        #expect(await BankQueries.client("Dana", in: bank.model) != nil)
        #expect(await BankQueries.account(9, in: bank.model) == nil)
    }

    @Test("A conditional unit whose then branch fails undoes its condition")
    func conditionalRollback() async throws {
        let bank = try await Fixtures.bank()
        let before = await ModelDescription.of(bank.model)
        let result = try await engine.apply(
            unitNamed: "ensureClientAccount", of: bank.module, to: bank.model, parameters: ["name": "Alice", "accountId": 1])
        #expect(!result.succeeded)
        #expect(result.appliedRules.isEmpty)
        #expect(await ModelDescription.of(bank.model) == before)
    }

    @Test("A priority unit applies the first applicable sub-unit")
    func priority() async throws {
        let bank = try await Fixtures.bank()
        let deposit = try await engine.apply(
            unitNamed: "depositOrCreate", of: bank.module, to: bank.model, parameters: ["name": "Bob", "accountId": 3, "amount": 4])
        #expect(deposit.appliedRules.map(\.ruleName) == ["deposit"])
        let create = try await engine.apply(
            unitNamed: "depositOrCreate", of: bank.module, to: bank.model, parameters: ["name": "Bob", "accountId": 6, "amount": 4])
        #expect(create.appliedRules.map(\.ruleName) == ["createAccount"])
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3, 6])
    }

    @Test("An independent unit applies one applicable sub-unit")
    func independent() async throws {
        let bank = try await Fixtures.bank()
        let first = try await engine.apply(unitNamed: "freezeOrCreate", of: bank.module, to: bank.model, parameters: ["name": "Eve"])
        #expect(first.succeeded)
        #expect(first.appliedRules.map(\.ruleName) == ["freezeOwned"])
        let random = HenshinEngine(options: EngineOptions(deterministic: false, randomSeed: 42))
        var names = Set<String>()
        for _ in 0..<6 {
            let result = try await random.apply(unitNamed: "freezeOrCreate", of: bank.module, to: bank.model, parameters: ["name": "Eve"])
            #expect(result.succeeded || names.contains("createClient"))
            names.formUnion(result.appliedRules.map(\.ruleName))
        }
        #expect(names.contains("freezeOwned"))
    }

    @Test("A loop unit applies its sub-unit for as long as possible")
    func loop() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(unitNamed: "freezeAll", of: bank.module, to: bank.model)
        #expect(result.succeeded)
        #expect(result.appliedRules.count == 3)
        for id in [1, 2, 3] { #expect(await BankQueries.account(id, in: bank.model)?.eGet("frozen") as? Bool == true) }
        let idle = try await engine.apply(unitNamed: "freezeAll", of: bank.module, to: bank.model)
        #expect(idle.succeeded && idle.appliedRules.isEmpty)
    }

    @Test("A loop stops at the iteration limit with a warning")
    func iterationLimit() async throws {
        let bank = try await Fixtures.bank()
        let limited = HenshinEngine(options: EngineOptions(iterationLimit: 2))
        let result = try await limited.apply(unitNamed: "freezeAll", of: bank.module, to: bank.model)
        #expect(result.appliedRules.count == 2)
        #expect(result.diagnostics.contains { $0.code == HenshinDiagnosticCode.iterationLimit.rawValue && $0.severity == .warning })
    }

    @Test("Iterated units take their count from a constant, a parameter or an expression")
    func iterated() async throws {
        let bank = try await Fixtures.bank()
        let thrice = try await engine.apply(unitNamed: "bonusThrice", of: bank.module, to: bank.model, parameters: ["id": 3])
        #expect(thrice.succeeded && thrice.appliedRules.count == 3)
        #expect(await BankQueries.balance(3, in: bank.model) == 3)
        let times = try await engine.apply(unitNamed: "bonusTimes", of: bank.module, to: bank.model, parameters: ["id": 3, "n": 4])
        #expect(times.appliedRules.count == 4)
        let twice = try await engine.apply(unitNamed: "bonusTwiceTimes", of: bank.module, to: bank.model, parameters: ["id": 3, "n": 2])
        #expect(twice.appliedRules.count == 4)
        #expect(await BankQueries.balance(3, in: bank.model) == 11)
        let none = try await engine.apply(unitNamed: "bonusTimes", of: bank.module, to: bank.model, parameters: ["id": 3, "n": 0])
        #expect(!none.succeeded, "as in Henshin, zero iterations do not succeed")
    }

    @Test("A strict iterated unit rolls back when an iteration fails")
    func iteratedRollback() async throws {
        let bank = try await Fixtures.bank()
        let strict = try await engine.apply(unitNamed: "deleteTwice", of: bank.module, to: bank.model, parameters: ["id": 2])
        #expect(!strict.succeeded)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
        let lenient = try await engine.apply(unitNamed: "deleteTwiceLenient", of: bank.module, to: bank.model, parameters: ["id": 2])
        #expect(lenient.succeeded, "a lenient iteration succeeds if an earlier iteration did")
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 3])
    }

    @Test("An error restores the model to its state before the application")
    func restoreOnError() async throws {
        let bank = try await Fixtures.bank()
        let before = await ModelDescription.of(bank.model)
        let deposit = try #require(bank.module.unit(named: "deposit")?.rule)
        var broken = deposit
        broken.name = "brokenDeposit"
        broken.rhs.nodes[0].attributes[1].value = "x + parseInt(amount)"
        let module = HenshinModule(rules: [try #require(bank.module.unit(named: "createAccount")?.rule), broken])
        let sequence = TransformationUnit(
            id: UnitID(2), name: "openBroken",
            parameters: [UnitParameter(name: "client", kind: .in), UnitParameter(name: "id", kind: .in)],
            parameterMappings: [
                ParameterMapping(source: ParameterReference(unit: UnitID(2), name: "client"), target: ParameterReference(unit: UnitID(0), name: "client")),
                ParameterMapping(source: ParameterReference(unit: UnitID(2), name: "id"), target: ParameterReference(unit: UnitID(0), name: "accountId")),
                ParameterMapping(source: ParameterReference(unit: UnitID(2), name: "id"), target: ParameterReference(unit: UnitID(1), name: "id")),
                ParameterMapping(source: ParameterReference(unit: UnitID(2), name: "id"), target: ParameterReference(unit: UnitID(1), name: "amount")),
            ],
            kind: .sequential([UnitID(0), UnitID(1)], strict: true, rollback: false))
        var withSequence = module
        withSequence.units.append(sequence)
        await #expect(throws: HenshinError.self) {
            _ = try await engine.apply(unitNamed: "openBroken", of: withSequence, to: bank.model, parameters: ["client": "Bob", "id": 5])
        }
        #expect(await ModelDescription.of(bank.model) == before)
    }

    @Test("Cancelling an application restores the model")
    func cancellation() async throws {
        let bank = try await Fixtures.bank()
        let before = await ModelDescription.of(bank.model)
        let module = bank.module
        let model = bank.model
        let task = Task {
            try await HenshinEngine().apply(unitNamed: "freezeAll", of: module, to: model)
        }
        task.cancel()
        _ = try? await task.value
        #expect(await ModelDescription.of(bank.model) == before)
    }
}
