//
//  EObjectNodeTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests that a node typed Ecore's `EObject` matches every object, as every model object
/// is an `EObject` in EMF.
@Suite("EObject nodes")
struct EObjectNodeTests {
    let engine = HenshinEngine()

    /// Ecore's `EObject`.
    let eObject = EcorePackage.metaClass(.eObject)

    /// The names of the clients that a rule whose first left-hand node is a client matches.
    func matchedClients(_ rule: Rule, _ bank: Fixtures.Bank) async throws -> [String] {
        var names: [String] = []
        for match in try await engine.findMatches(of: rule, in: bank.model) {
            let object = try #require(match.nodes[rule.lhs.nodes[0].id])
            names.append(try #require(await bank.model.resolve(object) as? DynamicEObject).eGet("name") as? String ?? "?")
        }
        return names.sorted()
    }

    @Test("A node typed EObject matches every object, and class nodes only their instances")
    func singleNode() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let objectCount = await bank.model.getAllObjects().count
        #expect(objectCount == 6)
        let any = rules.identity("any", RuleGraph(nodes: [rules.node(eObject)]))
        #expect(try await engine.findMatches(of: any, in: bank.model).count == objectCount)
        let accounts = rules.identity("accounts", RuleGraph(nodes: [rules.node(rules.account)]))
        #expect(try await engine.findMatches(of: accounts, in: bank.model).count == 3)
        let clients = rules.identity("clients", RuleGraph(nodes: [rules.node(rules.client)]))
        #expect(try await engine.findMatches(of: clients, in: bank.model).count == 2)
    }

    @Test("A node typed EObject matches the targets of an edge")
    func edgeTarget() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let (client, target) = (rules.node(rules.client), rules.node(eObject))
        let rule = rules.identity(
            "owned", RuleGraph(nodes: [client, target], edges: [RuleEdge(source: client.id, target: target.id, type: rules.accounts)]))
        #expect(try await matchedClients(rule, bank) == ["Alice", "Bob", "Bob"])
    }

    /// A condition requiring that the matched client `host` refers to an object through
    /// `accounts`.
    func ownsObject(_ host: RuleNode, _ rules: inout BankRules) -> Formula {
        let (image, owned) = (rules.node(rules.client), rules.node(eObject))
        return .condition(
            NestedCondition(
                conclusion: RuleGraph(nodes: [image, owned], edges: [RuleEdge(source: image.id, target: owned.id, type: rules.accounts)]),
                mappings: [NodeMapping(origin: host.id, image: image.id)]))
    }

    @Test("A positive application condition with a node typed EObject")
    func positiveCondition() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let host = rules.node(rules.client)
        let rule = rules.identity("owner", RuleGraph(nodes: [host], formula: ownsObject(host, &rules)))
        #expect(try await matchedClients(rule, bank) == ["Alice", "Bob"])
    }

    @Test("A negative application condition with a node typed EObject")
    func negativeCondition() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let host = rules.node(rules.client)
        let rule = rules.identity("nonOwner", RuleGraph(nodes: [host], formula: .not(ownsObject(host, &rules))))
        #expect(try await matchedClients(rule, bank).isEmpty)
    }

    @Test("A rule with a node typed EObject applies")
    func application() async throws {
        let bank = try await Fixtures.bank()
        var rules = try BankRules(bank.module)
        let (client, target) = (rules.node(rules.client, name: "c"), rules.node(eObject, name: "x"))
        let (keptClient, keptTarget) = (rules.node(rules.client, name: "c"), rules.node(eObject, name: "x"))
        let unlink = Rule(
            name: "unlink",
            lhs: RuleGraph(nodes: [client, target], edges: [RuleEdge(source: client.id, target: target.id, type: rules.accounts)]),
            rhs: RuleGraph(nodes: [keptClient, keptTarget]),
            mappings: [NodeMapping(origin: client.id, image: keptClient.id), NodeMapping(origin: target.id, image: keptTarget.id)])
        let outcome = try await engine.apply(unlink, to: bank.model)
        #expect(outcome.succeeded)
        var links = 0
        for client in await BankQueries.objects("Client", in: bank.model) {
            links += ModelGraph.identifiers(client.eGet("accounts")).count
        }
        #expect(links == 2)
    }

    @Test("Every class conforms to EObject and EObject to no other class")
    func conformance() async throws {
        let bank = try await Fixtures.bank()
        let rules = try BankRules(bank.module)
        var types = TypeCatalogue()
        let decisions = [
            types.conforms(rules.account, to: eObject), types.conforms(eObject, to: eObject),
            types.conforms(rules.account, to: rules.account), types.conforms(eObject, to: rules.account),
            types.conforms(rules.account, to: rules.client),
        ]
        #expect(decisions == [true, true, true, false, false])
        #expect(!ClassConformance.conforms(rules.bank, to: EClass(name: EcoreClassifier.eObject.rawValue)))
        #expect(ClassConformance.conforms(rules.client, to: EClass(name: "Client")))
        #expect(!ClassConformance.conforms(rules.client, to: rules.account))
    }

    /// A metamodel that declares a class of its own called `EObject`, extended by `Node`.
    struct OwnEObjectModel {
        let ownEObject: EClass
        let node: EClass
        let other: EClass
        let explicit: EClass

        /// Creates the classes, each time with fresh identities.
        init() {
            ownEObject = EClass(name: EcoreClassifier.eObject.rawValue)
            node = EClass(name: "Node", eSuperTypes: [ownEObject])
            other = EClass(name: "Other")
            explicit = EClass(name: "Explicit", eSuperTypes: [EcorePackage.metaClass(.eObject)])
        }
    }

    @Test(
        "A node typed with a class called EObject that a metamodel declares matches only its instances",
        arguments: [false, true])
    func declaredEObjectNode(separateMetamodel: Bool) async throws {
        let model = OwnEObjectModel()
        let resource = Resource(uri: "memory:/own.xmi")
        let base = DynamicEObject(eClass: model.ownEObject)
        let node = DynamicEObject(eClass: model.node)
        await resource.add(contentsOf: [
            base, node, DynamicEObject(eClass: model.other), DynamicEObject(eClass: model.explicit),
        ])
        let ruleTypes = separateMetamodel ? OwnEObjectModel() : model
        func rule(_ type: EClass) -> Rule {
            let lhs = RuleNode(id: NodeID(1), type: type)
            let rhs = RuleNode(id: NodeID(2), type: type)
            return Rule(
                name: "find", lhs: RuleGraph(nodes: [lhs]), rhs: RuleGraph(nodes: [rhs]),
                mappings: [NodeMapping(origin: lhs.id, image: rhs.id)])
        }
        let own = rule(ruleTypes.ownEObject)
        let matched = try await engine.findMatches(of: own, in: resource).compactMap { $0.nodes[NodeID(1)] }
        #expect(Set(matched) == [base.id, node.id])
        #expect(try await engine.findMatches(of: rule(eObject), in: resource).count == 4)
        #expect(!ClassConformance.conforms(model.other, to: ruleTypes.ownEObject))
        #expect(!ClassConformance.conforms(model.explicit, to: ruleTypes.ownEObject))
        #expect(ClassConformance.conforms(model.node, to: ruleTypes.ownEObject))
        #expect(ClassConformance.conforms(model.ownEObject, to: eObject))
    }
}
