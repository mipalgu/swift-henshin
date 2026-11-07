//
//  HenshinTextTranslationTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of translating Henshin Text into the module model and applying the result.
@Suite("Henshin Text translation")
struct HenshinTextTranslationTests {
    let engine = HenshinEngine()

    /// Translates a document over the bank metamodel.
    func translate(_ text: String) async throws -> HenshinTextTranslation {
        HenshinText.translate("ePackageImport bank\n" + text, packages: [try await Fixtures.bankPackage()])
    }

    /// The codes of the diagnostics of a translation.
    func codes(_ translation: HenshinTextTranslation) -> [String] { translation.diagnostics.map(\.code) }

    @Test("The example document loads next to its metamodel and validates")
    func loads() async throws {
        let bank = try await Fixtures.bankText()
        #expect(bank.module.name == HenshinTextConstants.moduleName)
        #expect(bank.module.imports == ["http://example.org/bank"])
        #expect(bank.module.rules.count == 14)
        let errors = HenshinValidator.validate(bank.module).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
        let translation = try await HenshinTextLoader.translate(url: Fixtures.url("bank.henshin_text"), resourceSet: ResourceSet())
        #expect(translation.diagnostics.isEmpty, "\(translation.diagnostics.map(\.message))")
    }

    @Test("A rule graph becomes two sides, mappings and a negative application condition")
    func ruleStructure() async throws {
        let module = try await Fixtures.bankText().module
        let rule = try #require(module.unit(named: "createAccount")?.rule)
        #expect(rule.lhs.name == "createAccount_LHS" && rule.rhs.name == "createAccount_RHS")
        #expect(rule.lhs.nodes.map(\.name) == ["bank", "owner"])
        #expect(rule.rhs.nodes.map(\.name) == ["bank", "owner", "account"])
        #expect(rule.mappings.count == 2)
        #expect(rule.lhs.edges.count == 1 && rule.rhs.edges.count == 3)
        #expect(rule.rhs.nodes[2].attributes.map(\.value) == ["accountId", "0", "false"])
        #expect(rule.parameters.map(\.typeName) == ["EString", "EInt", "Account"])
        guard case .not(.condition(let nac))? = rule.lhs.formula else {
            Issue.record("expected a negative application condition, found \(String(describing: rule.lhs.formula))")
            return
        }
        #expect(nac.conclusion.name == "forbid")
        #expect(nac.conclusion.nodes.map(\.name) == ["taken", "bank"])
        #expect(nac.mappings.count == 1)
        #expect(nac.mappings.first?.origin == rule.lhs.nodes[0].id)

        let deposit = try #require(module.unit(named: "deposit")?.rule)
        #expect(deposit.lhs.nodes[0].attributes.map(\.value) == ["id", "x"])
        #expect(deposit.rhs.nodes[0].attributes.map(\.value) == ["id", "x+amount"])
        #expect(deposit.attributeConditions.map(\.conditionText) == ["amount>0"])
        let purge = try #require(module.unit(named: "purgeAccount")?.rule)
        #expect(!purge.checkDangling && purge.injectiveMatching)
        let freeze = try #require(module.unit(named: "freezeOwned")?.rule)
        guard case .condition(let pac)? = freeze.lhs.formula else {
            Issue.record("expected a positive application condition")
            return
        }
        #expect(pac.conclusion.name == "require")
        #expect(pac.conclusion.nodes.map(\.name) == ["owner", "account"])
        let suffix = try #require(module.unit(named: "suffixName")?.rule)
        #expect(suffix.rhs.nodes[0].attributes.first?.value == "name+' '+suffix.toUpperCase()")
    }

    @Test("A multi-rule copies its kernel's nodes and edges and maps them")
    func multiRule() async throws {
        let module = try await Fixtures.bankText().module
        let kernel = try #require(module.unit(named: "closeClient")?.rule)
        let multi = try #require(kernel.multiRules.first)
        #expect(multi.name == "closeClientAccounts")
        #expect(multi.parameters.map(\.name) == ["name"], "multi-rules take the parameters of their kernel")
        #expect(multi.lhs.nodes.map(\.name) == ["account", "bank", "client"])
        #expect(multi.rhs.nodes.map(\.name) == ["bank"])
        #expect(multi.lhs.nodes[2].attributes.isEmpty, "kernel nodes are copied without their attributes")
        #expect(multi.lhs.edges.count == 3)
        #expect(multi.multiMappings.count == 3)
        #expect(multi.mappings.count == 1)
        #expect(HenshinValidator.validate(kernel).filter { $0.severity == .error }.isEmpty)
    }

    @Test("Units become units of their kind, with nested blocks as units of their own")
    func units() async throws {
        let module = try await Fixtures.bankText().module
        let open = try #require(module.unit(named: "openAndFund"))
        guard case .sequential(let steps, let strict, let rollback) = open.kind else {
            Issue.record("expected a sequential unit")
            return
        }
        #expect(steps.compactMap { module.unit($0)?.name } == ["createAccount", "deposit"])
        #expect(strict && rollback)
        #expect(open.parameterMappings.count == 10, "each argument is passed in and back")
        if case .sequential(_, let strict, let rollback) = try #require(module.unit(named: "openAndFundKeep")).kind {
            #expect(strict && !rollback)
        }
        if case .sequential(_, let strict, _) = try #require(module.unit(named: "openAndFundLoose")).kind { #expect(!strict) }
        if case .conditional(let test, let then, let otherwise) = try #require(module.unit(named: "ensureClientAccount")).kind {
            #expect([test, then, otherwise].compactMap { $0.flatMap { module.unit($0)?.name } } == ["hasClient", "createAccount", "createClient"])
        } else {
            Issue.record("expected a conditional unit")
        }
        if case .iterated(_, let iterations, let strict, _) = try #require(module.unit(named: "bonusTwiceTimes")).kind {
            #expect(iterations == "n*2" && !strict)
        }
        let nested = try #require(module.unit(named: "openWithBonuses"))
        guard case .sequential(let parts, _, _) = nested.kind else { return }
        #expect(parts.compactMap { module.unit($0)?.name } == ["createAccount", "openWithBonusesSequence0_1"])
        let block = try #require(module.unit(named: "openWithBonusesSequence0_1"))
        #expect(block.parameters.map(\.name) == nested.parameters.map(\.name))
        guard case .iterated(let body, let count, _, _) = block.kind else { return }
        #expect(count == "n")
        #expect(module.unit(body)?.name == "openWithBonusesSequence0_1ITERATED1")
        let errors = HenshinValidator.validate(module).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
    }

    @Test("The example in Henshin Text transforms models exactly as the example in XMI")
    func sameResults() async throws {
        let scenarios: [(String, ParameterValues)] = [
            ("createAccount", ["client": "Alice", "accountId": 4]), ("createAccount", ["client": "Alice", "accountId": 1]),
            ("deposit", ["id": 2, "amount": 15]), ("deposit", ["id": 2, "amount": -1]),
            ("transfer", ["from": 1, "to": 2, "amount": 30]), ("transfer", ["from": 3, "to": 2, "amount": 1000]),
            ("deleteAccount", ["id": 3]), ("removeAccountOnly", ["id": 1]), ("purgeAccount", ["id": 1]),
            ("closeClient", ["name": "Bob"]), ("closeClientNaive", ["name": "Bob"]),
            ("createClient", ["name": "Carol"]), ("createClient", ["name": "Alice"]), ("hasClient", ["name": "Bob"]),
            ("freezeOwned", [:]), ("freezeAll", [:]), ("addBonus", ["id": 1]), ("befriend", ["x": "Alice", "y": "Bob"]),
            ("befriend", ["x": "Alice", "y": "Alice"]), ("suffixName", ["name": "Alice", "suffix": "jr"]),
            ("openAndFund", ["client": "Bob", "accountId": 7, "amount": 12]),
            ("openAndFund", ["client": "Alice", "accountId": 5, "amount": -1]),
            ("openAndFundKeep", ["client": "Alice", "accountId": 5, "amount": -1]),
            ("openAndFundLoose", ["client": "Alice", "accountId": 1, "amount": 5]),
            ("ensureClientAccount", ["name": "Alice", "accountId": 9]), ("ensureClientAccount", ["name": "Dora", "accountId": 9]),
            ("depositOrCreate", ["name": "Alice", "accountId": 1, "amount": 5]),
            ("depositOrCreate", ["name": "Alice", "accountId": 8, "amount": 5]), ("freezeOrCreate", ["name": "Carol"]),
            ("bonusThrice", ["id": 2]), ("bonusTimes", ["id": 2, "n": 4]), ("bonusTwiceTimes", ["id": 2, "n": 2]),
            ("deleteTwiceLenient", ["id": 3]),
        ]
        for (unit, parameters) in scenarios {
            let xmi = try await Fixtures.bank()
            let text = try await Fixtures.bankText()
            let expected = try await engine.apply(unitNamed: unit, of: xmi.module, to: xmi.model, parameters: parameters)
            let actual = try await engine.apply(unitNamed: unit, of: text.module, to: text.model, parameters: parameters)
            #expect(actual.succeeded == expected.succeeded, "\(unit) \(parameters)")
            #expect(actual.appliedRules.map(\.ruleName) == expected.appliedRules.map(\.ruleName), "\(unit) \(parameters)")
            #expect(Set(actual.parameters.keys) == Set(expected.parameters.keys), "\(unit) \(parameters)")
            #expect(await ModelDescription.of(text.model) == ModelDescription.of(xmi.model), "\(unit) \(parameters)")
        }
    }

    @Test("A nested block of a unit runs as part of its unit")
    func nestedBlocks() async throws {
        let bank = try await Fixtures.bankText()
        let result = try await engine.apply(
            unitNamed: "openWithBonuses", of: bank.module, to: bank.model, parameters: ["client": "Bob", "accountId": 7, "amount": 10, "n": 3])
        #expect(result.succeeded)
        #expect(result.appliedRules.map(\.ruleName) == ["createAccount"] + Array(repeating: ["deposit", "addBonus"], count: 3).flatMap { $0 })
        #expect(await BankQueries.balance(7, in: bank.model) == 33)
        #expect(result.parameters["account"] != nil)
    }

    @Test("Matching formulas become nested conditions, including nested ones")
    func matchingFormula() async throws {
        let translation = try await translate(
            """
            rule wealthy(OUT owner:Client) {
              graph {
                node owner:Client
                matchingFormula {
                  formula !poor AND (rich XOR befriended)
                  conditionGraph poor {
                    node empty:Account { balance = 0 }
                    edges [(owner->empty:accounts)]
                  }
                  conditionGraph rich {
                    reuse owner { name = 'Alice' }
                    node full:Account
                    edges [(owner->full:accounts)]
                    matchingFormula {
                      formula large
                      conditionGraph large { reuse full { balance = 100 } }
                    }
                  }
                  conditionGraph befriended {
                    node other:Client
                    edges [(owner->other:friends)]
                  }
                }
              }
            }
            """)
        #expect(translation.diagnostics.isEmpty, "\(translation.diagnostics.map(\.message))")
        let rule = try #require(translation.module.rules.first)
        guard case .and(.not(.condition(let poor)), .xor(.condition(let rich), .condition(let befriended)))? = rule.lhs.formula else {
            Issue.record("unexpected formula \(String(describing: rule.lhs.formula))")
            return
        }
        #expect(poor.conclusion.name == "poor")
        #expect(poor.conclusion.nodes.map(\.name) == ["empty", "owner"])
        #expect(rich.conclusion.nodes.map(\.name) == ["full", "owner"])
        #expect(rich.conclusion.nodes[1].attributes.map(\.value) == ["'Alice'"])
        #expect(rich.mappings.count == 1 && befriended.mappings.count == 1)
        guard case .condition(let large)? = rich.conclusion.formula else {
            Issue.record("expected a nested condition")
            return
        }
        #expect(large.mappings.first?.origin == rich.conclusion.nodes[0].id, "nested conditions map from their enclosing conclusion")
        let bank = try await Fixtures.bank()
        let matches = try await engine.findMatches(of: rule, in: bank.model)
        #expect(matches.count == 1)
        let alice = try #require(await BankQueries.client("Alice", in: bank.model))
        #expect(matches.first?.parameters["owner"] as? EUUID == alice.id)
    }

    @Test("Attributes may be deleted, created and required on kept nodes")
    func attributeActions() async throws {
        let translation = try await translate(
            """
            rule marks(IN v:EInt) {
              graph {
                node a:Account {
                  delete id = v
                  create balance = v
                  require frozen = false
                  forbid balance = 0
                }
              }
            }
            """)
        #expect(translation.diagnostics.isEmpty, "\(translation.diagnostics.map(\.message))")
        let rule = try #require(translation.module.rules.first)
        #expect(rule.lhs.nodes[0].attributes.map(\.feature.name) == ["id"])
        #expect(rule.rhs.nodes[0].attributes.map(\.feature.name) == ["balance"])
        guard case .and(.not(.condition(let forbid)), .condition(let require))? = rule.lhs.formula else {
            Issue.record("unexpected formula")
            return
        }
        #expect(forbid.conclusion.nodes.first?.attributes.map(\.value) == ["0"])
        #expect(require.conclusion.nodes.first?.attributes.map(\.value) == ["false"])
        #expect(forbid.mappings.count == 1 && require.mappings.count == 1)
    }

    @Test("Problems of translation are reported with their positions")
    func diagnostics() async throws {
        let translation = try await translate(
            """
            rule bad(IN v:EInt, w:Nothing) {
              checkDangling false
              checkDangling true
              graph {
                node a:Account { nothing = v set balance = q }
                create node p:Person
                delete node d:Account
                node a:Account
                node c:Client
                edges [(a->c:missing), (a->d:owner), (a->ghost:owner)]
              }
            }
            rule twice() { graph { } graph { } }
            rule none() { checkDangling true }
            unit u(IN v:EInt) { bad(v, v, v) unknown() bad(v, z) }
            unit u() { none() }
            """)
        let found = codes(translation)
        let expected: [HenshinTextDiagnosticCode] = [
            .unknownMetamodelElement, .missingParameterKind, .repeatedElement, .setWithoutPreserve, .unknownName, .abstractCreation,
            .duplicateName, .actionMismatch, .graphCount, .argumentCount,
        ]
        for code in expected { #expect(found.contains(code.rawValue), "\(code)") }
        #expect(!translation.isValid)
        let nothing = try #require(translation.diagnostics.first { $0.message.contains("'Nothing'") })
        #expect(nothing.range?.start.line == 2 && nothing.range?.start.column == 23)
        let attribute = try #require(translation.diagnostics.first { $0.message.contains("no attribute 'nothing'") })
        #expect(attribute.range?.start.line == 6)
        let ghost = try #require(translation.diagnostics.first { $0.message.contains("'ghost'") })
        #expect(ghost.range?.start.line == 11)
        let count = try #require(translation.diagnostics.first { $0.code == HenshinTextDiagnosticCode.argumentCount.rawValue })
        #expect(count.range?.start.line == 16)
        #expect(translation.diagnostics.contains { $0.message.contains("'unknown'") && $0.range?.start.line == 16 })
        #expect(translation.diagnostics.contains { $0.message.contains("'z' is not a parameter") })
        let unknownImport = HenshinText.translate("ePackageImport nowhere\nrule r() { graph { } }", packages: [])
        #expect(unknownImport.diagnostics.first?.code == HenshinTextDiagnosticCode.unknownMetamodelElement.rawValue)
        #expect(unknownImport.diagnostics.first?.range?.start == SourcePosition(utf8Offset: 15, line: 1, column: 16))
    }

    @Test("Loading a document with errors throws them")
    func loadingErrors() async throws {
        let document = Fixtures.url("broken.\(HenshinTextConstants.fileExtension)")
        do {
            _ = try await HenshinTextLoader.load(url: document, resourceSet: ResourceSet())
            Issue.record("expected an error")
        } catch let error as HenshinError {
            guard case .invalidText(let name, let diagnostics) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(name == document.lastPathComponent)
            #expect(diagnostics.count == 1)
            #expect(error.description.contains("2:27"))
        }
    }
}
