//
//  ParameterAndConsistencyTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of the parameter semantics and the static checks described for Henshin: hidden
/// variable parameters, type checks of given values, unique signatures, parameter passing
/// between units, and the consistency warnings for deletion and containment.
@Suite("Parameters and consistency checks")
struct ParameterAndConsistencyTests {
    let engine = HenshinEngine()

    /// The codes of the findings of a module or rule.
    func codes(_ findings: [SourceDiagnostic]) -> [String] { findings.map(\.code) }

    // MARK: - Parameter kinds at run time

    @Test("Values of variable parameters stay hidden from the caller of a rule")
    func hiddenRuleVariable() async throws {
        let bank = try await Fixtures.bank()
        let result = try await engine.apply(
            unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 2, "amount": 15])
        #expect(result.succeeded)
        #expect(result.parameters["x"] == nil, "x is a VAR parameter")
        #expect(result.parameters["amount"] as? Int == 15)
        #expect(result.appliedRules.first?.parameters["x"] as? Int == 50, "the rule application still records it")
    }

    @Test("Values of variable parameters stay hidden from the caller of a composite unit")
    func hiddenUnitVariable() async throws {
        let bank = try await Fixtures.bank()
        var module = bank.module
        let bonus = try #require(module.unit(named: "addBonus"))
        let id = UnitID(module.units.count)
        module.units.append(
            TransformationUnit(
                id: id, name: "bonusOnce",
                parameters: [UnitParameter(name: "id", kind: .in), UnitParameter(name: "before", kind: .var)],
                parameterMappings: [
                    ParameterMapping(source: ParameterReference(unit: id, name: "id"), target: ParameterReference(unit: bonus.id, name: "id")),
                    ParameterMapping(source: ParameterReference(unit: bonus.id, name: "x"), target: ParameterReference(unit: id, name: "before")),
                ],
                kind: .sequential([bonus.id], strict: true, rollback: true)))
        let result = try await engine.apply(unitNamed: "bonusOnce", of: module, to: bank.model, parameters: ["id": 2])
        #expect(result.succeeded)
        #expect(result.parameters["before"] == nil)
        #expect(await BankQueries.balance(2, in: bank.model) == 51)
    }

    @Test("A value of the wrong type is rejected before anything is applied")
    func typeMismatch() async throws {
        let bank = try await Fixtures.bank()
        await #expect(throws: HenshinError.parameterTypeMismatch(unit: "deposit", parameter: "amount", expected: "EInt")) {
            _ = try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": 2, "amount": "two"])
        }
        await #expect(throws: HenshinError.parameterTypeMismatch(unit: "createAccount", parameter: "client", expected: "EString")) {
            _ = try await engine.apply(
                unitNamed: "createAccount", of: bank.module, to: bank.model, parameters: ["client": true, "accountId": 7])
        }
        #expect(await BankQueries.balance(2, in: bank.model) == 50)
        #expect(await BankQueries.accountIDs(in: bank.model) == [1, 2, 3])
        let deposit = try #require(bank.module.unit(named: "deposit")?.rule)
        await #expect(throws: HenshinError.parameterTypeMismatch(unit: "deposit", parameter: "id", expected: "EInt")) {
            _ = try await engine.findMatches(of: deposit, in: bank.model, parameters: ["id": 2.5])
        }
    }

    @Test("Values of compatible types and of undeclared types are accepted")
    func typeMatch() async throws {
        let bank = try await Fixtures.bank()
        let widened = try await engine.apply(
            unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": Int64(2), "amount": Int16(5)])
        #expect(widened.succeeded)
        #expect(await BankQueries.balance(2, in: bank.model) == 55)
        let untyped = try await engine.apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model, parameters: ["client": "Alice", "accountId": 8, "amount": 3])
        #expect(untyped.succeeded)
        let client = try #require(await BankQueries.client("Alice", in: bank.model))
        let rule = try #require(bank.module.unit(named: "hasClient")?.rule)
        #expect(rule.parameter(named: "client")?.typeName == "Client")
        _ = try await engine.findMatches(of: rule, in: bank.model, parameters: ["name": "Alice", "client": client.id])
        #expect(ParameterTypeCheck.accepts(3.5, typeNamed: "EDouble") && ParameterTypeCheck.accepts(3, typeNamed: "EFloat"))
        #expect(ParameterTypeCheck.accepts(Decimal(2), typeNamed: "EBigDecimal"))
        #expect(!ParameterTypeCheck.accepts("3", typeNamed: "EDouble"))
        #expect(ParameterTypeCheck.accepts(false, typeNamed: "EBooleanObject") && !ParameterTypeCheck.accepts(0, typeNamed: "EBoolean"))
        #expect(ParameterTypeCheck.accepts("x", typeNamed: "EStringObject") && ParameterTypeCheck.accepts(1, typeNamed: "EDate"))
    }

    // MARK: - Static checks

    @Test("Rules and units with the same signature are reported")
    func duplicateSignature() async throws {
        let bank = try await Fixtures.bank()
        var module = bank.module
        let deposit = try #require(module.unit(named: "deposit")?.rule)
        module.units.append(TransformationUnit(id: UnitID(module.units.count), rule: deposit))
        let findings = HenshinValidator.validate(module).filter { $0.code == HenshinDiagnosticCode.duplicateSignature.rawValue }
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)

        var overloaded = bank.module
        var variant = deposit
        variant.parameters.removeLast()
        overloaded.units.append(TransformationUnit(id: UnitID(overloaded.units.count), rule: variant))
        #expect(!codes(HenshinValidator.validate(overloaded)).contains(HenshinDiagnosticCode.duplicateSignature.rawValue))
    }

    @Test("A variable parameter must occur in the left-hand side")
    func variableOnLeftSide() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let code = HenshinDiagnosticCode.varParameterNotInLeftSide.rawValue
        let lhs = rules.node(rules.account)
        let rhs = rules.node(rules.account, [(rules.balance, "q")])
        let unused = Rule(
            name: "unused", parameters: [UnitParameter(name: "q", kind: .var)], lhs: RuleGraph(nodes: [lhs]),
            rhs: RuleGraph(nodes: [rhs]), mappings: [NodeMapping(origin: lhs.id, image: rhs.id)])
        let findings = HenshinValidator.validate(unused).filter { $0.code == code }
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)

        let named = rules.identity("named", RuleGraph(nodes: [rules.node(rules.account, name: "q")]), parameters: [UnitParameter(name: "q", kind: .var)])
        #expect(!codes(HenshinValidator.validate(named)).contains(code))

        let host = rules.node(rules.account)
        let image = rules.node(rules.account, [(rules.balance, "q")])
        let conditioned = rules.identity(
            "conditioned",
            RuleGraph(nodes: [host], formula: .condition(NestedCondition(conclusion: RuleGraph(nodes: [image]), mappings: [NodeMapping(origin: host.id, image: image.id)]))),
            parameters: [UnitParameter(name: "q", kind: .var)])
        #expect(!codes(HenshinValidator.validate(conditioned)).contains(code))

        var kernel = rules.identity("kernel", RuleGraph(nodes: [rules.node(rules.bank)]), parameters: [UnitParameter(name: "q", kind: .var)])
        let multi = rules.identity("multi", RuleGraph(nodes: [rules.node(rules.account, [(rules.balance, "q")])]), parameters: [UnitParameter(name: "q", kind: .var)])
        kernel.multiRules = [multi]
        #expect(!codes(HenshinValidator.validate(kernel)).contains(code))
        var lonelyMulti = rules.identity("lonely", RuleGraph(nodes: [rules.node(rules.bank)]))
        lonelyMulti.multiRules = [rules.identity("inner", RuleGraph(nodes: [rules.node(rules.account)]), parameters: [UnitParameter(name: "q", kind: .var)])]
        #expect(codes(HenshinValidator.validate(lonelyMulti)).filter { $0 == code }.count == 1)
    }

    @Test("A unit must pass a value to every input parameter of the units it invokes")
    func unpassedParameter() async throws {
        let bank = try await Fixtures.bank()
        var module = bank.module
        let deposit = try #require(module.unit(named: "deposit"))
        let id = UnitID(module.units.count)
        module.units.append(
            TransformationUnit(
                id: id, name: "depositSomething", parameters: [UnitParameter(name: "id", kind: .in)],
                parameterMappings: [
                    ParameterMapping(source: ParameterReference(unit: id, name: "id"), target: ParameterReference(unit: deposit.id, name: "id"))
                ],
                kind: .loop(deposit.id)))
        let findings = HenshinValidator.validate(module).filter { $0.code == HenshinDiagnosticCode.unpassedParameter.rawValue }
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.message.contains("'amount'") == true)
    }

    @Test("Deleting a node without its containment edge is a warning")
    func deletionWithoutContainment() async throws {
        let module = try await Fixtures.bank().module
        let code = HenshinDiagnosticCode.deletionWithoutContainment.rawValue
        for name in ["removeAccountOnly", "dormant"] {
            let rule = try #require(module.unit(named: name)?.rule)
            let findings = HenshinValidator.validate(rule).filter { $0.code == code }
            #expect(findings.count == 1, "\(name)")
            #expect(findings.first?.severity == .warning)
        }
        for name in ["deleteAccount", "purgeAccount", "closeClient"] {
            let rule = try #require(module.unit(named: name)?.rule)
            #expect(!codes(HenshinValidator.validate(rule)).contains(code), "\(name)")
        }
    }

    @Test("A rule whose graph holds a containment cycle is a warning")
    func containmentCycle() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let nested = EReference(name: "nested", eType: rules.bank, upperBound: -1, containment: true)
        let outer = rules.node(rules.bank)
        let inner = rules.node(rules.bank)
        let rule = Rule(
            name: "cycle", lhs: RuleGraph(), rhs: RuleGraph(nodes: [outer, inner], edges: [
                RuleEdge(source: outer.id, target: inner.id, type: nested), RuleEdge(source: inner.id, target: outer.id, type: nested),
            ]))
        let findings = HenshinValidator.validate(rule).filter { $0.code == HenshinDiagnosticCode.containmentCycle.rawValue }
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        let chain = Rule(
            name: "chain", lhs: RuleGraph(), rhs: RuleGraph(nodes: [outer, inner], edges: [RuleEdge(source: outer.id, target: inner.id, type: nested)]))
        #expect(!codes(HenshinValidator.validate(chain)).contains(HenshinDiagnosticCode.containmentCycle.rawValue))
    }
}
