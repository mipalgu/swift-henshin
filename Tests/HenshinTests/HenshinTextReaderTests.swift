//
//  HenshinTextReaderTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of reading Henshin Text: tokens, outline, syntax errors and their positions.
@Suite("Henshin Text syntax")
struct HenshinTextSyntaxTests {
    @Test("The example document reads without problems and has an outline")
    func example() throws {
        let text = try String(contentsOf: Fixtures.url("bank.henshin_text"), encoding: .utf8)
        let result = HenshinText.parse(text)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics.map(\.message))")
        #expect(result.isValid)
        let kinds = result.outline.map(\.kind)
        #expect(kinds.first == HenshinTextOutlineKind.import)
        #expect(kinds.filter { $0 == HenshinTextOutlineKind.rule }.count == 14)
        #expect(kinds.filter { $0 == HenshinTextOutlineKind.unit }.count == 12)
        let closeClient = try #require(result.outline.first { $0.name == "closeClient" })
        #expect(closeClient.detail == "(IN name:EString)")
        #expect(closeClient.children.map(\.name) == ["bank", "client", "closeClientAccounts"])
        #expect(closeClient.children.last?.kind == HenshinTextOutlineKind.multiRule)
        #expect(closeClient.children.last?.children.map(\.name) == ["account"])
        #expect(closeClient.selectionRange.start.line == closeClient.range.start.line)
        #expect(result.document.declarations.count == 26)
    }

    @Test("Tokens classify keywords, names, types, literals, operators and comments")
    func tokens() {
        let text = "// note\nrule r(IN x:EInt) { graph { node a:Account { balance = x + 1 name = 'n' frozen = true } } }"
        let tokens = HenshinText.tokens(in: text)
        /// The kind of the token that starts at a column of a line.
        func kind(_ line: Int, _ column: Int) -> SourceTokenKind? {
            tokens.first { $0.range.start.line == line && $0.range.start.column == column }?.kind
        }
        #expect(kind(1, 1) == .comment)
        #expect(kind(2, 1) == .keyword)
        #expect(kind(2, 6) == .identifier)
        #expect(kind(2, 7) == .punctuation)
        #expect(kind(2, 8) == .keyword, "IN")
        #expect(kind(2, 13) == .typeName, "EInt")
        #expect(kind(2, 36) == .typeName, "the class after a colon")
        #expect(kind(2, 58) == .operator, "+")
        #expect(kind(2, 60) == .number)
        #expect(kind(2, 69) == .string)
        #expect(kind(2, 82) == .boolean)
        #expect(tokens.allSatisfy { $0.kind != .invalid })
    }

    @Test("Escaped identifiers may use keywords as names")
    func escapedIdentifiers() throws {
        let result = HenshinText.parse("ePackageImport bank\nrule ^node(IN ^set:EInt) { graph { node ^rule:Account { id = ^set } } }")
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics.map(\.message))")
        guard case .rule(let rule) = try #require(result.document.declarations.first) else {
            Issue.record("expected a rule")
            return
        }
        #expect(rule.name.text == "node")
        #expect(rule.parameters.first?.name.text == "set")
        #expect(rule.body.graphs.first?.nodes.first?.name.text == "rule")
    }

    @Test("Syntax errors are reported with their positions and reading recovers")
    func recovery() throws {
        let text = """
            ePackageImport bank
            rule broken(IN x:EInt) {
              graph {
                node a:Account { id = }
                node b Account
                edges [(a->b:accounts]
              }
            }
            rule fine() {
              graph { node c:Client }
            }
            unit u(IN x:EInt) {
              fine(
            }
            unit later() { fine() }
            """
        let result = HenshinText.parse(text)
        #expect(!result.isValid)
        let lines = result.diagnostics.compactMap { $0.range?.start.line }
        #expect(lines.contains(4), "the missing value")
        #expect(lines.contains(5), "the missing colon")
        #expect(lines.contains(6), "the unclosed edge")
        #expect(lines.contains(14), "the unclosed call")
        #expect(result.diagnostics.allSatisfy { $0.code == HenshinTextDiagnosticCode.unexpectedToken.rawValue })
        let names = result.document.declarations.map(\.name.text)
        #expect(names == ["broken", "fine", "u", "later"], "reading continues after errors")
        let missingValue = try #require(result.diagnostics.first { $0.range?.start.line == 4 })
        #expect(missingValue.range?.start.column == 27)
        #expect(missingValue.message.contains("Expected an expression"))
    }

    @Test("Lexical errors are reported")
    func lexicalErrors() {
        let result = HenshinText.parse("ePackageImport bank\nrule r() { graph { node a:Account { name = 'open } } }\n/* open")
        let codes = Set(result.diagnostics.map(\.code))
        #expect(codes.contains(HenshinTextDiagnosticCode.unterminated.rawValue))
        let stray = HenshinText.parse("ePackageImport bank # rule")
        #expect(stray.diagnostics.contains { $0.code == HenshinTextDiagnosticCode.unexpectedCharacter.rawValue && $0.range?.start.column == 21 })
    }

    @Test("A document must import a metamodel package before its declarations")
    func imports() {
        let none = HenshinText.parse("rule r() { graph { } }")
        #expect(none.diagnostics.contains { $0.message.contains("at least one metamodel package") })
        let late = HenshinText.parse("rule r() { graph { } }\nePackageImport bank")
        #expect(late.diagnostics.contains { $0.message.contains("must precede") && $0.range?.start.line == 2 })
    }

    @Test("Expressions follow the precedence of the grammar")
    func expressions() throws {
        let result = HenshinText.parse(
            "ePackageImport bank\nrule r(IN a:EInt, IN b:EInt) { conditions [a + b * 2 > -3 AND !(a == b) OR Math.max(a, b) != Integer.MAX, a - -1.5, \"q\" == 'r'] graph { } }")
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics.map(\.message))")
        var translator = HenshinTextTranslator(packages: [])
        guard case .rule(let rule) = try #require(result.document.declarations.first) else { return }
        let texts = rule.body.conditions[0].expressions.map { translator.javaScript($0, scope: ["a", "b"]) }
        #expect(texts == ["a+b*2>-3 && !(a==b) || Math.max(a,b)!=Integer.MAX", "a - -1.5", "\"q\"=='r'"])
        #expect(translator.diagnostics.isEmpty)
        _ = translator.javaScript(.parameter(TextName(text: "c", range: rule.name.range)), scope: ["a"])
        #expect(translator.diagnostics.first?.code == HenshinTextDiagnosticCode.unknownName.rawValue)
    }

    @Test("Reading and translating any prefix of a document terminates")
    func prefixes() async throws {
        let text = try String(contentsOf: Fixtures.url("bank.henshin_text"), encoding: .utf8)
        let package = try await Fixtures.bankPackage()
        let characters = Array(text)
        var invalid = 0
        for length in stride(from: 0, to: characters.count, by: 5) {
            let prefix = String(characters[..<length])
            let translation = HenshinText.translate(prefix, packages: [package])
            if !translation.isValid { invalid += 1 }
            #expect(translation.diagnostics.allSatisfy { $0.range != nil || $0.code != HenshinTextDiagnosticCode.unexpectedToken.rawValue })
        }
        #expect(invalid > 0)
    }
}
