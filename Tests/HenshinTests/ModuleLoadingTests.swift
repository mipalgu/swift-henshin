//
//  ModuleLoadingTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Foundation
import Testing

@testable import Henshin

/// Tests of loading Henshin documents through the XMI loader.
@Suite("Loading Henshin modules")
struct ModuleLoadingTests {
    @Test("The bundled metamodel is found and registered")
    func metamodel() async throws {
        #expect(HenshinMetamodel.url() != nil)
        let resourceSet = ResourceSet()
        let package = try await HenshinMetamodel.register(in: resourceSet)
        #expect(package.nsURI == HenshinConstants.nsURI)
        #expect(package.getEClass(HenshinConstants.ClassName.rule) != nil)
        let again = try await HenshinMetamodel.register(in: resourceSet)
        #expect(again.id == package.id)
    }

    @Test("A hand-written document loads as a module with all its units")
    func units() async throws {
        let bank = try await Fixtures.bank()
        let module = bank.module
        #expect(module.name == "bankRules")
        #expect(module.imports == ["http://example.org/bank"])
        let names = module.units.map(\.name)
        #expect(names.prefix(4) == ["createAccount", "deposit", "transfer", "deleteAccount"])
        #expect(module.units.enumerated().allSatisfy { $0.element.id == UnitID($0.offset) })
        let kinds = Dictionary(module.units.map { ($0.name, $0.kind.className) }, uniquingKeysWith: { a, _ in a })
        #expect(kinds["openAndFund"] == "SequentialUnit")
        #expect(kinds["ensureClientAccount"] == "ConditionalUnit")
        #expect(kinds["depositOrCreate"] == "PriorityUnit")
        #expect(kinds["freezeOrCreate"] == "IndependentUnit")
        #expect(kinds["freezeAll"] == "LoopUnit")
        #expect(kinds["bonusThrice"] == "IteratedUnit")
        #expect(module.rules.count == 15)
    }

    @Test("Rules keep their graphs, parameters, conditions and options")
    func rule() async throws {
        let module = try await Fixtures.bank().module
        let rule = try #require(module.unit(named: "createAccount")?.rule)
        #expect(rule.parameters.map(\.name) == ["client", "accountId", "account"])
        #expect(rule.parameters.map(\.kind) == [.in, .in, .out])
        #expect(rule.parameters.map(\.typeName) == ["EString", "EInt", "Account"])
        #expect(rule.lhs.nodes.map(\.type.name) == ["Bank", "Client"])
        #expect(rule.rhs.nodes.map(\.type.name) == ["Bank", "Client", "Account"])
        #expect(rule.lhs.edges.map(\.type.name) == ["clients"])
        #expect(rule.rhs.edges.map(\.type.name) == ["clients", "accounts", "accounts"])
        #expect(rule.mappings.count == 2)
        #expect(rule.checkDangling && rule.injectiveMatching)
        guard case .not(.condition(let nac)) = rule.lhs.formula else {
            Issue.record("expected a negative application condition")
            return
        }
        #expect(nac.conclusion.nodes.count == 2)
        #expect(nac.mappings.count == 1)
        #expect(rule.lhs.node(named: "bank") != nil)
        #expect(rule.rhs.node(named: "account")?.attribute(named: "balance")?.value == "0")

        let deposit = try #require(module.unit(named: "deposit")?.rule)
        #expect(deposit.attributeConditions.map(\.conditionText) == ["amount > 0"])
        let purge = try #require(module.unit(named: "purgeAccount")?.rule)
        #expect(!purge.checkDangling)
        let dormant = try #require(module.unit(named: "dormant"))
        #expect(!dormant.isActivated)
    }

    @Test("Multi-rules and their mappings are read")
    func multiRule() async throws {
        let module = try await Fixtures.bank().module
        let rule = try #require(module.unit(named: "closeClient")?.rule)
        #expect(rule.multiRules.count == 1)
        let multi = try #require(rule.multiRules.first)
        #expect(multi.name == "closeClientAccounts")
        #expect(multi.multiMappings.count == 3)
        #expect(multi.lhs.nodes.count == 3)
    }

    @Test("Units keep their sub-units, options and parameter mappings")
    func compositeUnits() async throws {
        let module = try await Fixtures.bank().module
        let open = try #require(module.unit(named: "openAndFund"))
        guard case .sequential(let subUnits, let strict, let rollback) = open.kind else {
            Issue.record("expected a sequential unit")
            return
        }
        #expect(subUnits.compactMap { module.unit($0)?.name } == ["createAccount", "deposit"])
        #expect(strict && rollback)
        #expect(open.parameterMappings.count == 5)
        let keep = try #require(module.unit(named: "openAndFundKeep"))
        if case .sequential(_, let strict, let rollback) = keep.kind { #expect(strict && !rollback) }
        let iterated = try #require(module.unit(named: "deleteTwice"))
        if case .iterated(_, let iterations, let strict, let rollback) = iterated.kind {
            #expect(iterations == "2" && strict && rollback)
        }
        let conditional = try #require(module.unit(named: "ensureClientAccount"))
        if case .conditional(let condition, let then, let otherwise) = conditional.kind {
            #expect(module.unit(condition)?.name == "hasClient")
            #expect(module.unit(then)?.name == "createAccount")
            #expect(otherwise.flatMap { module.unit($0)?.name } == "createClient")
        }
    }

    @Test("A document without a module is rejected")
    func noModule() async throws {
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [Fixtures.url("bank.ecore")], in: resourceSet)
        await #expect(throws: HenshinError.self) {
            _ = try await HenshinModuleLoader.load(url: Fixtures.url("bank-small.xmi"), resourceSet: resourceSet)
        }
    }

    @Test("An unresolvable type is reported")
    func unresolvedType() async throws {
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <henshin:Module xmi:version="2.0" xmlns:xmi="http://www.omg.org/XMI" xmlns:henshin="http://www.eclipse.org/emf/2011/Henshin" xmi:id="m" name="broken">
              <units xsi:type="henshin:Rule" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmi:id="r" name="r">
                <lhs xmi:id="l"><nodes xmi:id="n"><type href="missing.ecore#//Nothing"/></nodes></lhs>
                <rhs xmi:id="h"/>
              </units>
            </henshin:Module>
            """
        let resourceSet = ResourceSet()
        await #expect(throws: HenshinError.self) {
            _ = try await HenshinModuleLoader.load(
                data: Data(text.utf8), uri: Fixtures.url("broken.henshin").absoluteString, resourceSet: resourceSet)
        }
    }

    @Test("Positional fragments select a root package and Ecore's own classes resolve")
    func positionalAndEcoreFragments() async throws {
        let resourceSet = ResourceSet()
        let packages = try await ModelIO.registerMetamodels(at: [Fixtures.url("bank.ecore")], in: resourceSet)
        let package = try #require(packages.first)
        #expect((ModuleReader.navigate([package], fragment: "/0/Account") as? EClass)?.name == "Account")
        #expect((ModuleReader.navigate([package], fragment: "/0") as? EPackage)?.name == "bank")
        #expect(ModuleReader.navigate([package], fragment: "/1/Account") == nil)
        let ecore = [EcorePackage.instance]
        #expect((ModuleReader.navigate(ecore, fragment: "//ENamedElement/name") as? EAttribute)?.name == "name")
        #expect((ModuleReader.navigate(ecore, fragment: "//EClass") as? EClass)?.name == "EClass")
    }

    @Test("References to Ecore's own classes and features resolve to the native metamodel")
    func ecoreTypes() async throws {
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <henshin:Module xmi:version="2.0" xmlns:xmi="http://www.omg.org/XMI" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ecore="http://www.eclipse.org/emf/2002/Ecore" xmlns:henshin="http://www.eclipse.org/emf/2011/Henshin" xmi:id="m" name="ecoreRules">
              <imports href="http://www.eclipse.org/emf/2002/Ecore#/"/>
              <units xsi:type="henshin:Rule" xmi:id="r" name="renameClass">
                <lhs xmi:id="l">
                  <nodes xmi:id="n" outgoing="e">
                    <type href="http://www.eclipse.org/emf/2002/Ecore#//EClass"/>
                    <attributes xmi:id="a" value="'Old'"><type href="http://www.eclipse.org/emf/2002/Ecore#//ENamedElement/name"/></attributes>
                  </nodes>
                  <nodes xmi:id="s" incoming="e"><type href="http://www.eclipse.org/emf/2002/Ecore#//EClass"/></nodes>
                  <edges xmi:id="e" source="n" target="s"><type href="http://www.eclipse.org/emf/2002/Ecore#//EClass/eSuperTypes"/></edges>
                </lhs>
                <rhs xmi:id="h"/>
              </units>
            </henshin:Module>
            """
        let module = try await HenshinModuleLoader.load(
            data: Data(text.utf8), uri: Fixtures.url("ecore-rules.henshin").absoluteString, resourceSet: ResourceSet())
        let rule = try #require(module.rules.first)
        #expect(rule.lhs.nodes.first?.type.name == "EClass")
        #expect(rule.lhs.nodes.first?.attributes.first?.feature.name == "name")
        #expect(rule.lhs.edges.first?.type.name == "eSuperTypes")
        #expect(module.imports == [EcorePackage.nsURI])
    }

    @Test("Name-based fragments lead to classifiers, features and literals")
    func fragments() async throws {
        let resourceSet = ResourceSet()
        let packages = try await ModelIO.registerMetamodels(at: [Fixtures.url("bank.ecore")], in: resourceSet)
        let package = try #require(packages.first)
        #expect((ModuleReader.navigate([package], fragment: "//Account") as? EClass)?.name == "Account")
        #expect((ModuleReader.navigate([package], fragment: "//Account/balance") as? EAttribute)?.name == "balance")
        #expect((ModuleReader.navigate([package], fragment: "//Client/name") as? EAttribute)?.name == "name")
        #expect((ModuleReader.navigate([package], fragment: "/") as? EPackage)?.name == "bank")
        #expect(ModuleReader.navigate([package], fragment: "//Nothing") == nil)
        #expect(ModuleReader.navigate([package], fragment: "//Account/nothing") == nil)
    }
}
