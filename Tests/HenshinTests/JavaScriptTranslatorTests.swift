//
//  JavaScriptTranslatorTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import Testing

@testable import Henshin

/// Tests of the translation of Henshin's JavaScript expressions into AQL.
@Suite("JavaScript to AQL translation")
struct JavaScriptTranslatorTests {
    /// A translator that knows the variables used in the tests.
    let translator = JavaScriptTranslator(variables: ["x", "y", "z", "name", "s", "t", "flag", "amount"])

    /// Translates an expression and returns the AQL text.
    func aql(_ source: String) throws -> String {
        try translator.translate(source).aql
    }

    @Test("Literals are recognised as constants")
    func literals() throws {
        #expect(try translator.translate("42").form == .literal(.integer(42)))
        #expect(try translator.translate(" -7 ").form == .literal(.integer(-7)))
        #expect(try translator.translate("3.5").form == .literal(.real(3.5)))
        #expect(try translator.translate("\"abc\"").form == .literal(.string("abc")))
        #expect(try translator.translate("'it\\'s'").form == .literal(.string("it's")))
        #expect(try translator.translate("true").form == .literal(.boolean(true)))
        #expect(try translator.translate("false").form == .literal(.boolean(false)))
        #expect(try translator.translate("null").form == .literal(.null))
        #expect(try aql("'a\\nb'") == "'a\\nb'")
        #expect(try aql("\"q'uote\"") == "'q\\'uote'")
        #expect(try aql("1e3") == "1000.0")
    }

    @Test("A lone identifier is a variable reference")
    func variable() throws {
        let translated = try translator.translate("name")
        #expect(translated.form == .variable("name"))
        #expect(translated.aql == "name")
        #expect(translated.variables == ["name"])
    }

    @Test("Arithmetic follows JavaScript precedence")
    func arithmetic() throws {
        #expect(try aql("x + 1") == "(x + 1)")
        #expect(try aql("x + y * z") == "(x + (y * z))")
        #expect(try aql("(x + y) * z") == "((x + y) * z)")
        #expect(try aql("x - y - z") == "((x - y) - z)")
        #expect(try aql("x % 3") == "(x mod 3)")
        #expect(try aql("x / 2") == "((x * 1.0) / 2)")
        #expect(try aql("-x") == "(-x)")
        #expect(try aql("+x") == "x")
        #expect(try translator.translate("x * y + z").variables == ["x", "y", "z"])
    }

    @Test("String concatenation and methods")
    func strings() throws {
        #expect(try aql("'Hello ' + name") == "('Hello ' + name)")
        #expect(try aql("s.length") == "s.size()")
        #expect(try aql("s.toUpperCase()") == "s.toUpper()")
        #expect(try aql("s.toLowerCase()") == "s.toLower()")
        #expect(try aql("s.trim()") == "s.trim()")
        #expect(try aql("s.startsWith(t)") == "s.startsWith(t)")
        #expect(try aql("s.endsWith('x')") == "s.endsWith('x')")
        #expect(try aql("s.includes(t)") == "s.contains(t)")
        #expect(try aql("s.substring(1, 3)") == "s.substring((1 + 1), 3)")
        #expect(try aql("s.substring(x)") == "s.substring((x + 1))")
        #expect(try aql("s.replace('a', 'b')") == "s.substituteFirst('a', 'b')")
    }

    @Test("Comparisons and logic")
    func comparisons() throws {
        #expect(try aql("x == 1") == "(x = 1)")
        #expect(try aql("x === 1") == "(x = 1)")
        #expect(try aql("x != 1") == "(x <> 1)")
        #expect(try aql("x !== 1") == "(x <> 1)")
        #expect(try aql("x < y && y <= z") == "((x < y) and (y <= z))")
        #expect(try aql("x > y || y >= z") == "((x > y) or (y >= z))")
        #expect(try aql("!flag") == "(not flag)")
        #expect(try aql("x > 0 && !flag || y == 2") == "(((x > 0) and (not flag)) or (y = 2))")
        #expect(try aql("flag ? x : y") == "(if flag then x else y endif)")
        #expect(try aql("x > 0 ? 'pos' : x < 0 ? 'neg' : 'zero'")
            == "(if (x > 0) then 'pos' else (if (x < 0) then 'neg' else 'zero' endif) endif)")
    }

    @Test("Math functions and number parsing")
    func functions() throws {
        #expect(try aql("Math.abs(x)") == "x.abs()")
        #expect(try aql("Math.max(x, y)") == "x.max(y)")
        #expect(try aql("Math.min(x, 3)") == "x.min(3)")
        #expect(try aql("Math.floor(x / 2)") == "((x * 1.0) / 2).floor()")
        #expect(try aql("Math.ceil(x)") == "x.ceil()")
        #expect(try aql("Math.round(x)") == "x.round()")
        #expect(try aql("parseInt(s)") == "s.toInteger()")
        #expect(try aql("parseFloat(s)") == "s.toReal()")
        #expect(try aql("String(x)") == "('' + x)")
    }

    @Test("Unsupported constructs give clear diagnostics", arguments: [
        "x = 1", "x++", "new Date()", "function() { return 1 }", "[1, 2]", "{a: 1}", "`t`",
        "x & y", "x | y", "x ^ y", "x << 1", "typeof x", "s.foo()", "Math.pow(x, 2)", "foo(x)",
        "x +", "(x", "'open", "x ? y", "1 2", "", "s.length()", "Math", "x.y.z",
    ])
    func unsupported(source: String) throws {
        #expect(throws: HenshinError.self) { try translator.translate(source) }
    }

    @Test("Unknown variables are reported")
    func unknownVariable() throws {
        do {
            _ = try translator.translate("missing + 1")
            Issue.record("expected an error")
        } catch let error as HenshinError {
            guard case .unsupportedExpression(let expression, let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(expression == "missing + 1")
            #expect(reason.contains("missing"))
        }
    }

    @Test("Translations of the documented table")
    func table() throws {
        for entry in JavaScriptTranslator.translationTable {
            let translator = JavaScriptTranslator(variables: ["a", "b", "c", "s", "t"])
            #expect(try translator.translate(entry.javaScript).aql == entry.aql, "\(entry.javaScript)")
        }
    }
}
