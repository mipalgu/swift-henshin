//
//  SupportTypeTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of the error, value and identity types that support the engine.
@Suite("Support types")
struct SupportTypeTests {
    @Test("Every error describes itself in a sentence", arguments: [
        HenshinError.metamodelMissing, .noModule("m.henshin"), .unresolvedReference(element: "node 'a'", reference: "its type"),
        .malformed("an edge leaves its graph"), .unknownUnit("u"), .missingParameter(unit: "u", parameter: "p"),
        .invalidParameter(unit: "u", parameter: "p"), .unsupportedExpression(expression: "x++", reason: "no"),
        .evaluationFailed(expression: "1/0", reason: "division"), .unboundParameter(expression: "q", parameter: "q"),
        .changeFailed(rule: "r", reason: "abstract"),
    ])
    func errors(error: HenshinError) {
        #expect(!error.description.isEmpty)
        #expect(error.errorDescription == error.description)
    }

    @Test("Wider numeric types and collections convert and compare")
    func numbers() {
        #expect(ValueSemantics.cast(7, toTypeNamed: "EBigInteger") as? EBigInteger == EBigInteger(7))
        #expect(ValueSemantics.cast(1.5, toTypeNamed: "EBigDecimal") as? Decimal == Decimal(1.5))
        #expect(ValueSemantics.integer(EBigInteger(9)) == 9)
        #expect(ValueSemantics.integer(Decimal(9.7)) == 9)
        #expect(ValueSemantics.integer(Float(2.5)) == 2)
        #expect(ValueSemantics.integer(Double.infinity) == nil)
        #expect(ValueSemantics.real(Float(0.5)) == 0.5)
        #expect(ValueSemantics.real(Decimal(2)) == 2)
        #expect(ValueSemantics.real("1.25") == 1.25)
        #expect(ValueSemantics.integer(true) == nil)
        #expect(ValueSemantics.text(of: 3) == "3")
        #expect(ValueSemantics.cast(2.0, toTypeNamed: "EInt") as? Int == 2)
        #expect(ValueSemantics.cast("x", toTypeNamed: "EInt") as? String == "x")
        #expect(ValueSemantics.cast(3, toTypeNamed: "EBoolean") as? Int == 3)
        let left = EcoreValueArray([1, 2])
        #expect(ValueSemantics.equal(left, EcoreValueArray([1, 2.0])))
        #expect(!ValueSemantics.equal(left, EcoreValueArray([1])))
    }

    @Test("Many-valued attributes receive lists")
    func manyValued() throws {
        let feature = EAttribute(name: "tags", eType: EDataType(name: "EInt"), upperBound: -1)
        let single = try #require(ValueSemantics.cast("4", to: feature) as? EcoreValueArray)
        #expect(single.values.compactMap { $0 as? Int } == [4])
        let list = try #require(ValueSemantics.cast(EcoreValueArray(["1", 2]), to: feature) as? EcoreValueArray)
        #expect(list.values.compactMap { $0 as? Int } == [1, 2])
    }

    @Test("Identities, literals and parameter kinds behave as documented")
    func identities() {
        #expect(NodeID(1) < NodeID(2))
        #expect(NodeID(3).description == "#3")
        #expect(UnitID(0) < UnitID(1))
        #expect(UnitID(4).description == "unit4")
        #expect(LiteralValue.null.ecoreValue == nil)
        #expect(ParameterKind.inout.isRequired && ParameterKind.in.isRequired && !ParameterKind.out.isRequired)
        #expect(!ParameterKind.var.acceptsInput && ParameterKind.unknown.acceptsInput)
        #expect(!ParameterKind.in.isKeptInResult && ParameterKind.var.isKeptInResult)
        var generator = SeededGenerator(seed: 1)
        var again = SeededGenerator(seed: 1)
        #expect(generator.next() == again.next())
    }

    @Test("Objects that are not dynamic objects take no part in matching")
    func foreignObjects() async throws {
        let bank = try await Fixtures.bank()
        await bank.model.add(EPackage(name: "extra", nsURI: "urn:example:extra", nsPrefix: "extra"))
        let result = try await HenshinEngine().apply(unitNamed: "freezeAll", of: bank.module, to: bank.model)
        #expect(result.appliedRules.count == 3)
        #expect(result.diagnostics.contains { $0.code == HenshinDiagnosticCode.foreignObject.rawValue })
    }

    @Test("A module of rules gives each rule a unit")
    func moduleOfRules() async throws {
        let module = try await Fixtures.bank().module
        let rules = HenshinModule(name: "copy", rules: module.rules)
        #expect(rules.units.count == module.rules.count)
        #expect(rules.unit(UnitID(99)) == nil)
        #expect(rules.unit(named: "deposit")?.rule?.parameter(named: "amount")?.kind == .in)
        let rule = try #require(rules.unit(named: "deposit")?.rule)
        #expect(rule.image(of: rule.lhs.nodes[0].id) == rule.rhs.nodes[0].id)
        #expect(rule.origin(of: rule.rhs.nodes[0].id) == rule.lhs.nodes[0].id)
        #expect(UnitKind.loop(UnitID(0)).subUnits == [UnitID(0)])
        #expect(UnitKind.conditional(if: UnitID(0), then: UnitID(1), else: nil).subUnits == [UnitID(0), UnitID(1)])
    }
}
