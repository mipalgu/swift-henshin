//
//  HenshinTextWriterTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of writing modules as Henshin Text and of round trips between the two forms.
@Suite("Henshin Text writing")
struct HenshinTextWriterTests {
    let engine = HenshinEngine()

    /// Writes a module and reads it back over the bank metamodel.
    func roundTrip(_ module: HenshinModule) async throws -> (HenshinTextWriting, HenshinTextTranslation) {
        let package = try await Fixtures.bankPackage()
        let written = HenshinText.write(module, packages: [package])
        return (written, HenshinText.translate(written.text, packages: [package]))
    }

    @Test("Writing is canonical: reading and writing again gives the same document")
    func canonical() async throws {
        let module = try await Fixtures.bankText().module
        let (first, read) = try await roundTrip(module)
        #expect(first.diagnostics.isEmpty, "\(first.diagnostics.map(\.message))")
        #expect(read.diagnostics.isEmpty, "\(read.diagnostics.map(\.message))\n\(first.text)")
        let (second, again) = try await roundTrip(read.module)
        #expect(second.text == first.text)
        #expect(again.diagnostics.isEmpty)
        #expect(read.module.units.map(\.name) == module.units.map(\.name))
    }

    @Test("A module read from XMI is written as Henshin Text that behaves the same")
    func fromXMI() async throws {
        let xmi = try await Fixtures.bank()
        let (written, read) = try await roundTrip(xmi.module)
        let lost = written.diagnostics.filter { $0.severity != .information }
        #expect(lost.count == 2, "\(lost.map(\.message))")
        #expect(lost.contains { $0.message.contains("'deleteTwice'") })
        #expect(lost.contains { $0.message.contains("'dormant'") })
        #expect(!written.isFaithful)
        #expect(read.diagnostics.isEmpty, "\(read.diagnostics.map(\.message))\n\(written.text)")
        #expect(written.text.contains("unit openAndFundKeep(IN client:EString, IN accountId:EInt, IN amount:EInt, VAR account:Account)"))
        #expect(written.text.contains("set balance = x + amount"))
        #expect(written.text.contains("formula !idTaken"))
        let scenarios: [(String, ParameterValues)] = [
            ("createAccount", ["client": "Alice", "accountId": 4]), ("createAccount", ["client": "Alice", "accountId": 1]),
            ("deposit", ["id": 2, "amount": 15]), ("transfer", ["from": 1, "to": 2, "amount": 30]), ("deleteAccount", ["id": 3]),
            ("removeAccountOnly", ["id": 1]), ("purgeAccount", ["id": 1]), ("closeClient", ["name": "Bob"]),
            ("closeClientNaive", ["name": "Bob"]), ("createClient", ["name": "Alice"]), ("freezeAll", [:]),
            ("befriend", ["x": "Alice", "y": "Bob"]), ("suffixName", ["name": "Alice", "suffix": "jr"]),
            ("openAndFund", ["client": "Alice", "accountId": 5, "amount": -1]),
            ("openAndFundKeep", ["client": "Alice", "accountId": 5, "amount": -1]),
            ("ensureClientAccount", ["name": "Dora", "accountId": 9]), ("depositOrCreate", ["name": "Alice", "accountId": 8, "amount": 5]),
            ("bonusTwiceTimes", ["id": 2, "n": 2]), ("deleteTwiceLenient", ["id": 3]),
        ]
        for (unit, parameters) in scenarios {
            let expected = try await Fixtures.bank()
            let actual = try await Fixtures.bank()
            let before = try await engine.apply(unitNamed: unit, of: expected.module, to: expected.model, parameters: parameters)
            let after = try await engine.apply(unitNamed: unit, of: read.module, to: actual.model, parameters: parameters)
            #expect(after.succeeded == before.succeeded, "\(unit)")
            #expect(after.appliedRules.map(\.ruleName) == before.appliedRules.map(\.ruleName), "\(unit)")
            #expect(await ModelDescription.of(actual.model) == ModelDescription.of(expected.model), "\(unit)")
        }
    }

    @Test("Untyped parameters receive the types they are used with")
    func inferredTypes() async throws {
        let xmi = try await Fixtures.bank()
        let written = await HenshinText.write(xmi.module, resourceSet: xmi.resourceSet)
        #expect(written.text.contains("rule transfer(IN from:EInt, IN to:EInt, IN amount:EInt, VAR x:EInt, VAR y:EInt)"))
        #expect(written.text.contains("unit bonusTimes(IN id:EInt, IN n:EInt)"))
        #expect(written.text.contains("unit openAndFund(IN client:EString, IN accountId:EInt, IN amount:EInt, OUT account:Account)"))
    }

    @Test("Expressions are written with Henshin Text's operators and the fewest parentheses")
    func expressions() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let parameters = ["a", "b", "c", "s"].map { UnitParameter(name: $0, kind: .in) }
        let conditions = [
            "a || b && !c", "(a + b) * c > 2", "-a < 0", "'it\\'s' == s", "Math.max(a, b) == s.length", "a - (b - c) == a - b - c",
            "!(a && b)", "+a == 1.5",
        ]
        let node = rules.node(rules.account, [(rules.balance, "a"), (rules.id, "b"), (rules.name, "s")])
        var rule = rules.identity("check", RuleGraph(nodes: [node]), parameters: parameters)
        rule.lhs.nodes[0].attributes.append(RuleAttribute(feature: rules.balance, value: "c"))
        rule.attributeConditions = conditions.map { AttributeCondition(conditionText: $0) }
        var module = HenshinModule(rules: [rule])
        module.imports = ["http://example.org/bank"]
        let package = try await Fixtures.bankPackage()
        let written = HenshinText.write(module, packages: [package])
        #expect(
            written.text.contains(
                "conditions [a OR b AND !c, (a + b) * c > 2, 0 - a < 0, 'it\\'s' == s, Math.max(a, b) == s.length, "
                    + "a - (b - c) == a - b - c, !(a AND b), a == 1.5]"),
            "\(written.text)")
        let read = HenshinText.translate(written.text, packages: [package])
        let texts = try #require(read.module.rules.first).attributeConditions.map(\.conditionText)
        #expect(texts.first == "a || b && !c")
        #expect(texts[3] == "'it\\'s'==s")
        for (index, text) in texts.enumerated() {
            let original = try JavaScriptTranslator(variables: ["a", "b", "c", "s"]).translate(conditions[index])
            let again = try JavaScriptTranslator(variables: ["a", "b", "c", "s"]).translate(text)
            let expected = index == 2 ? "((0 - a) < 0)" : original.aql
            #expect(again.aql == expected, "\(conditions[index]) and \(text) translate alike")
        }

        rule.attributeConditions = ["a % b == 0", "a ? b : c", "null"].map { AttributeCondition(conditionText: $0) }
        let unexpressible = HenshinText.write(HenshinModule(rules: [rule]), packages: [package])
        #expect(unexpressible.diagnostics.filter { $0.code == HenshinTextDiagnosticCode.notExpressible.rawValue && $0.severity == .error }.count == 3)
    }

    @Test("Names that are keywords are escaped and read back")
    func keywordNames() async throws {
        let package = try await Fixtures.bankPackage()
        let text = """
            ePackageImport bank

            rule ^unit(IN ^set:EInt) {
            	graph {
            		node ^node:Account {
            			id = ^set
            		}
            	}
            }
            """
        let read = HenshinText.translate(text, packages: [package])
        #expect(read.diagnostics.isEmpty, "\(read.diagnostics.map(\.message))")
        let rule = try #require(read.module.rules.first)
        #expect(rule.name == "unit" && rule.lhs.nodes.first?.name == "node")
        let written = HenshinText.write(read.module, packages: [package])
        #expect(written.text == text + "\n")
    }

    @Test("Multi-rules write the attributes of reused kernel nodes")
    func multiRuleReuse() async throws {
        let package = try await Fixtures.bankPackage()
        let text = """
            ePackageImport bank

            rule rename(IN n:EString) {
            	graph {
            		node bank:Bank
            		node client:Client {
            			name = n
            		}
            		edges [
            			(bank->client:clients)
            		]
            		multiRule tidy {
            			graph {
            				node account:Account {
            					frozen = true
            					set frozen = false
            				}
            				reuse bank {
            					preserve name = 'b'
            					delete name = 'b'
            				}
            				edges [
            					(client->account:accounts)
            				]
            			}
            		}
            	}
            }
            """
        let read = HenshinText.translate(text, packages: [package])
        let multi = try #require(read.module.rules.first?.multiRules.first)
        #expect(multi.lhs.nodes.map(\.name) == ["account", "bank", "client"])
        #expect(multi.lhs.nodes[1].attributes.map(\.value) == ["'b'", "'b'"])
        #expect(multi.rhs.nodes.first { $0.name == "bank" }?.attributes.map(\.value) == ["'b'"])
        #expect(multi.lhs.edges.count == 2 && multi.rhs.edges.count == 2)
        let written = HenshinText.write(read.module, packages: [package])
        #expect(written.text.contains("reuse bank {"))
        let again = HenshinText.write(HenshinText.translate(written.text, packages: [package]).module, packages: [package])
        #expect(again.text == written.text)
        #expect(written.diagnostics.isEmpty, "\(written.diagnostics.map(\.message))")
    }

    @Test("Problems that Henshin Text cannot express are reported")
    func notExpressible() async throws {
        let bank = try await Fixtures.bank()
        var module = bank.module
        module.units.append(TransformationUnit(id: UnitID(module.units.count), name: "freezeAll", kind: .loop(UnitID(0))))
        module.imports = ["http://example.org/unknown"]
        let written = await HenshinText.write(module, resourceSet: bank.resourceSet)
        #expect(written.diagnostics.contains { $0.severity == .error && $0.message.contains("Two units are named 'freezeAll'") })
        #expect(written.diagnostics.contains { $0.message.contains("http://example.org/unknown") })
        #expect(written.diagnostics.contains { $0.code == HenshinTextDiagnosticCode.adjusted.rawValue && $0.message.contains("package 'bank'") })
        #expect(written.text.hasPrefix("ePackageImport bank\n"))
    }
}
