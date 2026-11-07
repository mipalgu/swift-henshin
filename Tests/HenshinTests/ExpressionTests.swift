//
//  ExpressionTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of evaluating translated expressions with AQL and of value conversions.
@Suite("Expressions and values")
struct ExpressionTests {
    /// Evaluates a JavaScript expression with variable values through AQL.
    @MainActor
    func evaluate(_ source: String, _ values: [String: any EcoreValue] = [:]) async throws -> (any EcoreValue)? {
        let expression = try CompiledExpression(source, variables: Set(values.keys))
        return try await ExpressionEvaluator().evaluate(expression, values: values.mapValues { SendableValue(value: $0) })
    }

    @Test("Translated expressions keep JavaScript's results")
    @MainActor
    func semantics() async throws {
        #expect(try await evaluate("a / b", ["a": 7, "b": 2]) as? Double == 3.5)
        #expect(try await evaluate("a % 3", ["a": 7]) as? Int == 1)
        #expect(try await evaluate("'v' + a", ["a": 7]) as? String == "v7")
        #expect(try await evaluate("a + b + 'x'", ["a": 1, "b": 2]) as? String == "3x")
        #expect(try await evaluate("s.substring(1, 3)", ["s": "abcdef"]) as? String == "bc")
        #expect(try await evaluate("s.substring(2)", ["s": "abcdef"]) as? String == "cdef")
        #expect(try await evaluate("s.length", ["s": "abcdef"]) as? Int == 6)
        #expect(try await evaluate("flag ? 'y' : 'n'", ["flag": false]) as? String == "n")
        #expect(try await evaluate("Math.max(a, b)", ["a": 3, "b": 9]) as? Int == 9)
        #expect(try await evaluate("Math.abs(a)", ["a": -4]) as? Int == 4)
        #expect(try await evaluate("parseInt(s) + 1", ["s": "41"]) as? Int == 42)
        #expect(try await evaluate("a >= 2 && !(a == 3)", ["a": 2]) as? Bool == true)
        #expect(try await evaluate("s.toUpperCase() == 'AB'", ["s": "ab"]) as? Bool == true)
        #expect(try await evaluate("s.includes('b') || false", ["s": "ab"]) as? Bool == true)
        #expect(try await evaluate("String(a) + s.replace('a', 'z')", ["a": 1, "s": "aa"]) as? String == "1za")
    }

    @Test("Evaluation failures are reported with the expression")
    @MainActor
    func failure() async throws {
        await #expect(throws: HenshinError.self) { _ = try await evaluate("a / b", ["a": 1, "b": 0]) }
        await #expect(throws: HenshinError.self) { _ = try await evaluate("parseInt(a)", ["a": 1]) }
    }

    @Test("Values are converted to the data type of their attribute")
    func casts() {
        #expect(ValueSemantics.cast("5", toTypeNamed: "EInt") as? Int == 5)
        #expect(ValueSemantics.cast(3.9, toTypeNamed: "EInt") as? Int == 3)
        #expect(ValueSemantics.cast(-3.9, toTypeNamed: "EInt") as? Int == -3)
        #expect(ValueSemantics.cast(2, toTypeNamed: "EDouble") as? Double == 2.0)
        #expect(ValueSemantics.cast(2, toTypeNamed: "EFloat") as? Float == 2.0)
        #expect(ValueSemantics.cast(2, toTypeNamed: "ELong") as? Int64 == 2)
        #expect(ValueSemantics.cast(2, toTypeNamed: "EShort") as? Int16 == 2)
        #expect(ValueSemantics.cast(2, toTypeNamed: "EByte") as? Int8 == 2)
        #expect(ValueSemantics.cast(5, toTypeNamed: "EString") as? String == "5")
        #expect(ValueSemantics.cast("true", toTypeNamed: "EBoolean") as? Bool == true)
        #expect(ValueSemantics.cast("x", toTypeNamed: "Custom") as? String == "x")
        #expect(ValueSemantics.cast(nil, toTypeNamed: "EInt") == nil)
    }

    @Test("Numbers of different types compare by value")
    func equality() {
        #expect(ValueSemantics.equal(1, 1.0))
        #expect(ValueSemantics.equal(Int64(4), 4))
        #expect(ValueSemantics.equal(nil, nil))
        #expect(!ValueSemantics.equal(nil, 0))
        #expect(!ValueSemantics.equal("1", 1))
        #expect(ValueSemantics.equal("a", "a"))
        #expect(!ValueSemantics.equal(true, 1))
    }
}

/// Tests of the static validation of modules.
@Suite("Validation")
struct ValidationTests {
    @Test("The example module has no errors, only warnings for deletions without containment")
    func clean() async throws {
        let module = try await Fixtures.bank().module
        let findings = HenshinValidator.validate(module)
        #expect(!findings.contains { $0.severity == .error })
        #expect(findings.map(\.code) == Array(repeating: HenshinDiagnosticCode.deletionWithoutContainment.rawValue, count: 2))
        #expect(findings.map(\.message).contains { $0.contains("removeAccountOnly") })
        #expect(findings.map(\.message).contains { $0.contains("dormant") })
    }

    @Test("Problems of a rule are reported")
    func findings() async throws {
        let module = try await Fixtures.bank().module
        var rules = try BankRules(module)
        let person = try #require(rules.client.eSuperTypes.first)
        let lhs = rules.node(rules.account, [(rules.balance, "nothing + 1")])
        let created = rules.node(person)
        let rule = Rule(
            name: "broken", parameters: [UnitParameter(name: "p"), UnitParameter(name: "p")], lhs: RuleGraph(nodes: [lhs]),
            rhs: RuleGraph(nodes: [created], edges: [RuleEdge(source: created.id, target: created.id, type: rules.accounts, index: "0")]),
            mappings: [NodeMapping(origin: created.id, image: lhs.id)], attributeConditions: [AttributeCondition(conditionText: "p = 1")])
        let codes = Set(HenshinValidator.validate(rule).map(\.code))
        let expected: [HenshinDiagnosticCode] = [
            .duplicateParameter, .invalidMapping, .abstractCreation, .unknownVariable, .invalidEdgeType, .edgeIndexIgnored,
            .unsupportedExpression,
        ]
        for code in expected { #expect(codes.contains(code.rawValue), "\(code)") }
        var withUnit = HenshinModule(rules: [rule])
        withUnit.units.append(TransformationUnit(id: UnitID(1), name: "loop", kind: .loop(UnitID(9))))
        #expect(HenshinValidator.validate(withUnit).contains { $0.code == HenshinDiagnosticCode.unknownSubUnit.rawValue })
    }
}
