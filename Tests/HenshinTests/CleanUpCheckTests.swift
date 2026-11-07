//
//  CleanUpCheckTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of the validator warnings that correspond to Henshin's clean-up operation.
@Suite("Clean-up checks")
struct CleanUpCheckTests {
    /// The findings of a rule with a code.
    func findings(_ rule: Rule, _ code: HenshinDiagnosticCode) -> [SourceDiagnostic] {
        HenshinValidator.validate(rule).filter { $0.code == code.rawValue }
    }

    /// The findings of a module with a code.
    func findings(_ module: HenshinModule, _ code: HenshinDiagnosticCode, metamodels: [EPackage] = []) -> [SourceDiagnostic] {
        HenshinValidator.validate(module, metamodels: metamodels).filter { $0.code == code.rawValue }
    }

    @Test("The example module raises none of the clean-up warnings")
    func exampleIsClean() async throws {
        let bank = try await Fixtures.bank()
        let package = try #require(await bank.resourceSet.getMetamodel(uri: "http://example.org/bank"))
        let cleanUpCodes: Set<HenshinDiagnosticCode> = [
            .unusedParameter, .ambiguousMapping, .mappingTypeMismatch, .invalidMultiMapping, .invalidConditionMapping,
            .rightSideFormula, .trivialCondition, .redundantMultiRule, .multiRuleEdgeMismatch, .multiRuleParameterMismatch,
            .emptyIterations, .invalidParameterMapping, .unusedImport, .missingImport,
        ]
        let found = HenshinValidator.validate(bank.module, metamodels: [package]).filter {
            HenshinDiagnosticCode(rawValue: $0.code).map(cleanUpCodes.contains) ?? false
        }
        #expect(found.isEmpty, "\(found.map(\.message))")
    }

    // MARK: - Parameters

    @Test("Rule parameters that are used nowhere are reported")
    func unusedRuleParameters() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let lhs = rules.node(rules.account, [(rules.balance, "x")])
        let rhs = rules.node(rules.account, [(rules.balance, "x + amount")])
        let rule = Rule(
            name: "spare",
            parameters: [
                UnitParameter(name: "x", kind: .var), UnitParameter(name: "amount", kind: .in), UnitParameter(name: "limit", kind: .in),
                UnitParameter(name: "unused", kind: .in), UnitParameter(name: "length", kind: .in),
            ],
            lhs: RuleGraph(nodes: [lhs]), rhs: RuleGraph(nodes: [rhs]), mappings: [NodeMapping(origin: lhs.id, image: rhs.id)],
            attributeConditions: [AttributeCondition(conditionText: "amount < limit && 'abc'.length > 0")])
        let unused = findings(rule, .unusedParameter)
        #expect(unused.count == 2)
        #expect(unused.allSatisfy { $0.severity == .warning })
        #expect(unused.contains { $0.message.contains("'unused'") })
        #expect(unused.contains { $0.message.contains("'length'") }, "a property name after a dot is no use of a parameter")

        var kernel = rules.identity("kernel", RuleGraph(nodes: [rules.node(rules.bank)]), parameters: [UnitParameter(name: "n", kind: .in)])
        kernel.multiRules = [rules.identity("multi", RuleGraph(nodes: [rules.node(rules.client, [(rules.name, "n")])]))]
        #expect(findings(kernel, .unusedParameter).isEmpty, "a kernel parameter used by a multi-rule is used")
        let named = rules.identity("named", RuleGraph(nodes: [rules.node(rules.bank, name: "b")]), parameters: [UnitParameter(name: "b", kind: .out)])
        #expect(findings(named, .unusedParameter).isEmpty)
    }

    @Test("Unit parameters that take part in no mapping or iteration count are reported")
    func unusedUnitParameters() async throws {
        let bank = try await Fixtures.bank()
        var module = bank.module
        let bonus = try #require(module.unit(named: "addBonus"))
        let id = UnitID(module.units.count)
        module.units.append(
            TransformationUnit(
                id: id, name: "bonusSpare",
                parameters: [UnitParameter(name: "id", kind: .in), UnitParameter(name: "n", kind: .in), UnitParameter(name: "spare", kind: .in)],
                parameterMappings: [ParameterMapping(source: ParameterReference(unit: id, name: "id"), target: ParameterReference(unit: bonus.id, name: "id"))],
                kind: .iterated(bonus.id, iterations: "n + 1", strict: false, rollback: true)))
        let unused = findings(module, .unusedParameter)
        #expect(unused.count == 1)
        #expect(unused.first?.message.contains("'spare'") == true)
    }

    @Test("A multi-rule that redeclares a kernel parameter differently is reported")
    func multiRuleParameterMismatch() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let parameter = UnitParameter(name: "n", kind: .in, typeName: "EString")
        var kernel = rules.identity("kernel", RuleGraph(nodes: [rules.node(rules.client, [(rules.name, "n")])]), parameters: [parameter])
        kernel.multiRules = [rules.identity("same", RuleGraph(nodes: [rules.node(rules.bank)]), parameters: [parameter])]
        #expect(findings(kernel, .multiRuleParameterMismatch).isEmpty)
        kernel.multiRules.append(
            rules.identity("other", RuleGraph(nodes: [rules.node(rules.bank)]), parameters: [UnitParameter(name: "n", kind: .out, typeName: "EString")]))
        kernel.multiRules.append(
            rules.identity("typed", RuleGraph(nodes: [rules.node(rules.bank)]), parameters: [UnitParameter(name: "n", kind: .in, typeName: "EInt")]))
        #expect(findings(kernel, .multiRuleParameterMismatch).count == 2)
    }

    // MARK: - Mappings

    @Test("Ambiguous and ill-typed rule mappings are reported")
    func ruleMappings() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let lhs = rules.node(rules.account)
        let first = rules.node(rules.account)
        let second = rules.node(rules.client)
        let rule = Rule(
            name: "split", lhs: RuleGraph(nodes: [lhs]), rhs: RuleGraph(nodes: [first, second]),
            mappings: [NodeMapping(origin: lhs.id, image: first.id), NodeMapping(origin: lhs.id, image: second.id)])
        #expect(findings(rule, .ambiguousMapping).count == 1)
        let mismatch = findings(rule, .mappingTypeMismatch)
        #expect(mismatch.count == 1)
        #expect(mismatch.first?.message.contains("'Client'") == true)

        let left = rules.node(rules.account)
        let right = rules.node(rules.account)
        let merged = rules.node(rules.account)
        let merging = Rule(
            name: "merge", lhs: RuleGraph(nodes: [left, right]), rhs: RuleGraph(nodes: [merged]),
            mappings: [NodeMapping(origin: left.id, image: merged.id), NodeMapping(origin: right.id, image: merged.id)], injectiveMatching: false)
        #expect(findings(merging, .ambiguousMapping).count == 1)
    }

    @Test("Multi-mappings must lead from a kernel side to the same multi-rule side")
    func multiMappings() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        var kernel = rules.identity("kernel", RuleGraph(nodes: [rules.node(rules.bank)]))
        var multi = rules.identity("multi", RuleGraph(nodes: [rules.node(rules.bank), rules.node(rules.account)]))
        multi.multiMappings = [
            NodeMapping(origin: kernel.lhs.nodes[0].id, image: multi.lhs.nodes[0].id),
            NodeMapping(origin: kernel.rhs.nodes[0].id, image: multi.rhs.nodes[0].id),
        ]
        kernel.multiRules = [multi]
        #expect(findings(kernel, .invalidMultiMapping).isEmpty)
        kernel.multiRules[0].multiMappings.append(NodeMapping(origin: kernel.lhs.nodes[0].id, image: multi.rhs.nodes[1].id))
        #expect(findings(kernel, .invalidMultiMapping).count == 1)
        kernel.multiRules[0].multiMappings.removeLast()
        kernel.multiRules[0].multiMappings.append(NodeMapping(origin: kernel.lhs.nodes[0].id, image: multi.lhs.nodes[1].id))
        #expect(findings(kernel, .ambiguousMapping).count == 1)
        #expect(findings(kernel, .mappingTypeMismatch).count == 1)

        var plain = rules.identity("plain", RuleGraph(nodes: [rules.node(rules.bank)]))
        plain.multiMappings = [NodeMapping(origin: plain.lhs.nodes[0].id, image: plain.rhs.nodes[0].id)]
        let stray = findings(plain, .invalidMultiMapping)
        #expect(stray.count == 1)
        #expect(stray.first?.message.contains("not a multi-rule") == true)
    }

    @Test("Mappings of nested conditions must lead from the host graph to the conclusion")
    func conditionMappings() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let host = rules.node(rules.account)
        let owner = rules.node(rules.client)
        let image = rules.node(rules.account)
        let holder = rules.node(rules.client)
        let conclusion = RuleGraph(nodes: [image, holder], edges: [RuleEdge(source: holder.id, target: image.id, type: rules.accounts)])
        let valid = rules.identity(
            "valid", RuleGraph(nodes: [host, owner], formula: .not(.condition(NestedCondition(conclusion: conclusion, mappings: [NodeMapping(origin: host.id, image: image.id)])))))
        #expect(findings(valid, .invalidConditionMapping).isEmpty)
        #expect(findings(valid, .mappingTypeMismatch).isEmpty)

        let stray = rules.identity(
            "stray",
            RuleGraph(nodes: [host], formula: .condition(NestedCondition(conclusion: conclusion, mappings: [NodeMapping(origin: owner.id, image: image.id)]))))
        #expect(findings(stray, .invalidConditionMapping).count == 1)

        let person = try #require(rules.client.eSuperTypes.first)
        let general = rules.node(person)
        let refined = rules.identity(
            "refined",
            RuleGraph(nodes: [host, owner], formula: .condition(NestedCondition(conclusion: RuleGraph(nodes: [image, general]), mappings: [
                NodeMapping(origin: host.id, image: image.id), NodeMapping(origin: owner.id, image: general.id),
            ]))))
        #expect(findings(refined, .mappingTypeMismatch).isEmpty, "a superclass is related")
        let unrelated = rules.identity(
            "unrelated",
            RuleGraph(nodes: [host, owner], formula: .condition(NestedCondition(conclusion: RuleGraph(nodes: [image, holder]), mappings: [
                NodeMapping(origin: owner.id, image: image.id), NodeMapping(origin: owner.id, image: holder.id),
            ]))))
        #expect(findings(unrelated, .mappingTypeMismatch).count == 1)
        #expect(findings(unrelated, .ambiguousMapping).count == 1)
    }

    // MARK: - Conditions

    @Test("An application condition of a right-hand side is reported")
    func rightSideFormula() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        var rule = rules.identity("checked", RuleGraph(nodes: [rules.node(rules.bank)]))
        rule.rhs.formula = .true
        let found = findings(rule, .rightSideFormula)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
    }

    @Test("Nested conditions that always or never hold are reported")
    func trivialConditions() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let host = rules.node(rules.account, [(rules.balance, "0")])
        let copy = rules.node(rules.account, [(rules.balance, " 0 ")])
        let always = NestedCondition(conclusion: RuleGraph(nodes: [copy]), mappings: [NodeMapping(origin: host.id, image: copy.id)])
        let alwaysRule = rules.identity("always", RuleGraph(nodes: [host], formula: .not(.condition(always))))
        let found = findings(alwaysRule, .trivialCondition)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("always holds") == true)

        let never = NestedCondition(conclusion: RuleGraph(nodes: [copy], formula: .not(.true)), mappings: [NodeMapping(origin: host.id, image: copy.id)])
        let neverRule = rules.identity("never", RuleGraph(nodes: [host], formula: .condition(never)))
        #expect(findings(neverRule, .trivialCondition).first?.message.contains("never hold") == true)

        let differing = rules.node(rules.account, [(rules.balance, "1")])
        let real = NestedCondition(conclusion: RuleGraph(nodes: [differing]), mappings: [NodeMapping(origin: host.id, image: differing.id)])
        #expect(findings(rules.identity("real", RuleGraph(nodes: [host], formula: .condition(real))), .trivialCondition).isEmpty)
        let owner = rules.node(rules.client)
        let image = rules.node(rules.account)
        let extended = NestedCondition(
            conclusion: RuleGraph(nodes: [image, owner], edges: [RuleEdge(source: owner.id, target: image.id, type: rules.accounts)]),
            mappings: [NodeMapping(origin: host.id, image: image.id)])
        #expect(findings(rules.identity("extended", RuleGraph(nodes: [host], formula: .condition(extended))), .trivialCondition).isEmpty)
    }

    // MARK: - Multi-rules

    @Test("A multi-rule that only repeats its kernel rule is reported")
    func redundantMultiRule() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        var kernel = rules.identity("kernel", RuleGraph(nodes: [rules.node(rules.bank)]))
        var copy = rules.identity("copy", RuleGraph(nodes: [rules.node(rules.bank)]))
        copy.multiMappings = [
            NodeMapping(origin: kernel.lhs.nodes[0].id, image: copy.lhs.nodes[0].id),
            NodeMapping(origin: kernel.rhs.nodes[0].id, image: copy.rhs.nodes[0].id),
        ]
        kernel.multiRules = [copy]
        let found = findings(kernel, .redundantMultiRule)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("'copy'") == true)

        let bank = try await Fixtures.bank()
        let closeClient = try #require(bank.module.unit(named: "closeClient")?.rule)
        #expect(findings(closeClient, .redundantMultiRule).isEmpty)
    }

    @Test("A multi-rule that treats a kernel edge differently from its kernel is reported")
    func multiRuleEdges() async throws {
        var rules = try BankRules(try await Fixtures.bank().module)
        let bank = rules.node(rules.bank)
        let client = rules.node(rules.client)
        let bankImage = rules.node(rules.bank)
        let edge = RuleEdge(source: bank.id, target: client.id, type: rules.clients)
        let clientImage = rules.node(rules.client)
        var kernel = Rule(
            name: "unlink", lhs: RuleGraph(nodes: [bank, client], edges: [edge]), rhs: RuleGraph(nodes: [bankImage, clientImage]),
            mappings: [NodeMapping(origin: bank.id, image: bankImage.id), NodeMapping(origin: client.id, image: clientImage.id)])
        let multiBank = rules.node(rules.bank)
        let multiClient = rules.node(rules.client)
        let multiBankImage = rules.node(rules.bank)
        let multiClientImage = rules.node(rules.client)
        var multi = Rule(
            name: "keep", lhs: RuleGraph(nodes: [multiBank, multiClient], edges: [RuleEdge(source: multiBank.id, target: multiClient.id, type: rules.clients)]),
            rhs: RuleGraph(nodes: [multiBankImage, multiClientImage], edges: [RuleEdge(source: multiBankImage.id, target: multiClientImage.id, type: rules.clients)]),
            mappings: [NodeMapping(origin: multiBank.id, image: multiBankImage.id), NodeMapping(origin: multiClient.id, image: multiClientImage.id)])
        multi.multiMappings = [
            NodeMapping(origin: bank.id, image: multiBank.id), NodeMapping(origin: client.id, image: multiClient.id),
            NodeMapping(origin: bankImage.id, image: multiBankImage.id), NodeMapping(origin: clientImage.id, image: multiClientImage.id),
        ]
        kernel.multiRules = [multi]
        let preserved = findings(kernel, .multiRuleEdgeMismatch)
        #expect(preserved.count == 1)
        #expect(preserved.first?.message.contains("preserves an edge 'clients' that its kernel rule 'unlink' deletes") == true)

        kernel.multiRules[0].rhs.edges = []
        kernel.rhs.edges = [RuleEdge(source: bankImage.id, target: clientImage.id, type: rules.clients)]
        let deleted = findings(kernel, .multiRuleEdgeMismatch)
        #expect(deleted.count == 1)
        #expect(deleted.first?.message.contains("deletes an edge 'clients' that its kernel rule 'unlink' preserves") == true)

        kernel.lhs.edges = []
        kernel.multiRules[0].lhs.edges = []
        kernel.multiRules[0].rhs.edges = [RuleEdge(source: multiBankImage.id, target: multiClientImage.id, type: rules.clients)]
        #expect(findings(kernel, .multiRuleEdgeMismatch).isEmpty, "both create the edge")
        kernel.multiRules[0].lhs.edges = [RuleEdge(source: multiBank.id, target: multiClient.id, type: rules.clients)]
        #expect(findings(kernel, .multiRuleEdgeMismatch).first?.message.contains("preserves an edge 'clients' that its kernel rule 'unlink' creates") == true)
        kernel.lhs.edges = [edge]
        kernel.multiRules[0].lhs.edges = []
        #expect(findings(kernel, .multiRuleEdgeMismatch).first?.message.contains("creates an edge 'clients' that its kernel rule 'unlink' preserves") == true)
    }

    // MARK: - Units and modules

    @Test("An iterated unit without a number of iterations is reported")
    func emptyIterations() async throws {
        var module = try await Fixtures.bank().module
        let bonus = try #require(module.unit(named: "addBonus"))
        module.units.append(TransformationUnit(id: UnitID(module.units.count), name: "bonusSomeTimes", kind: .iterated(bonus.id, iterations: " ", strict: false, rollback: true)))
        let found = findings(module, .emptyIterations)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
    }

    @Test("Parameter mappings to units other than direct sub-units are reported")
    func invalidParameterMappings() async throws {
        var module = try await Fixtures.bank().module
        let deposit = try #require(module.unit(named: "deposit"))
        let other = try #require(module.unit(named: "createAccount"))
        let id = UnitID(module.units.count)
        module.units.append(
            TransformationUnit(
                id: id, name: "depositAll",
                parameters: [UnitParameter(name: "id", kind: .in), UnitParameter(name: "amount", kind: .in)],
                parameterMappings: [
                    ParameterMapping(source: ParameterReference(unit: id, name: "id"), target: ParameterReference(unit: deposit.id, name: "id")),
                    ParameterMapping(source: ParameterReference(unit: id, name: "amount"), target: ParameterReference(unit: deposit.id, name: "amount")),
                    ParameterMapping(source: ParameterReference(unit: id, name: "id"), target: ParameterReference(unit: other.id, name: "accountId")),
                    ParameterMapping(source: ParameterReference(unit: id, name: "missing"), target: ParameterReference(unit: deposit.id, name: "id")),
                ],
                kind: .loop(deposit.id)))
        let found = findings(module, .invalidParameterMapping)
        #expect(found.count == 2)
        #expect(found.contains { $0.message.contains("direct sub-units") })
        #expect(found.contains { $0.message.contains("'missing'") })
    }

    @Test("Unused and missing metamodel imports are reported when the metamodels are known")
    func imports() async throws {
        let bank = try await Fixtures.bank()
        let package = try #require(await bank.resourceSet.getMetamodel(uri: "http://example.org/bank"))
        var module = bank.module
        #expect(findings(module, .unusedImport, metamodels: [package]).isEmpty)
        module.imports.append("http://example.org/unused")
        let unused = findings(module, .unusedImport, metamodels: [package])
        #expect(unused.count == 1)
        #expect(unused.first?.message.contains("http://example.org/unused") == true)
        module.imports = []
        #expect(findings(module, .missingImport, metamodels: [package]).count == 1)
        #expect(findings(module, .missingImport).isEmpty, "without metamodels the imports are not checked")
    }
}
