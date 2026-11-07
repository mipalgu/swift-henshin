//
//  AnalysisTestSupport.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Henshin
import Testing

@testable import HenshinAnalysis

/// Locates and loads the fixtures of the tests.
enum Fixtures {
    /// The directory that holds the fixtures.
    static var directory: URL {
        guard let url = Bundle.module.url(forResource: "Resources", withExtension: nil) else {
            fatalError("The test resources are missing")
        }
        return url
    }

    /// The location of a fixture.
    ///
    /// - Parameter name: The file name of the fixture.
    /// - Returns: Its location.
    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Loads a rule module together with its metamodel.
    ///
    /// - Parameters:
    ///   - rules: The file name of the rule module.
    ///   - metamodel: The file name of the metamodel.
    /// - Returns: The resource set and the module.
    static func module(_ rules: String, metamodel: String) async throws -> (ResourceSet, HenshinModule) {
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [url(metamodel)], in: resourceSet)
        let module = try await HenshinModuleLoader.load(url: url(rules), resourceSet: resourceSet)
        return (resourceSet, module)
    }

    /// The graph rules.
    static func graphRules() async throws -> HenshinModule { try await module("graphs.henshin", metamodel: "graphs.ecore").1 }

    /// The bank rules.
    static func bankRules() async throws -> HenshinModule { try await module("bank.henshin", metamodel: "bank.ecore").1 }
}

extension HenshinModule {
    /// The rule with a name, failing the test if there is none.
    ///
    /// - Parameter name: The name of the rule.
    /// - Returns: The rule.
    func rule(_ name: String) throws -> Rule { try #require(rules.first { $0.name == name }) }
}

/// Builds rules over the graph metamodel for tests that need rules the fixtures lack.
struct RuleBuilder {
    /// The class of graph nodes.
    let node: EClass
    /// The reference between graph nodes.
    let next: EReference
    /// The next free node identity.
    var nextID = 100_000

    /// Takes the class and reference from the graph rules.
    ///
    /// - Parameter module: The graph rules.
    init(_ module: HenshinModule) throws {
        let rule = try module.rule("deleteNext")
        node = rule.lhs.nodes[0].type
        next = try #require(rule.lhs.edges.first).type
    }

    /// A fresh node.
    mutating func fresh(_ name: String? = nil) -> RuleNode {
        nextID += 1
        return RuleNode(id: NodeID(nextID), name: name, type: node)
    }

    /// A rule that deletes the forward edge of two nodes that link to each other.
    mutating func deleteForwardOfPair() -> Rule {
        let (a, b, ra, rb) = (fresh("a"), fresh("b"), fresh("a"), fresh("b"))
        return Rule(
            name: "deleteForwardOfPair",
            lhs: RuleGraph(nodes: [a, b], edges: [RuleEdge(source: a.id, target: b.id, type: next), RuleEdge(source: b.id, target: a.id, type: next)]),
            rhs: RuleGraph(nodes: [ra, rb], edges: [RuleEdge(source: rb.id, target: ra.id, type: next)]),
            mappings: [NodeMapping(origin: a.id, image: ra.id), NodeMapping(origin: b.id, image: rb.id)])
    }

    /// An identity rule that matches an edge unless the reverse edge exists.
    mutating func useUnlessBackEdge() -> Rule {
        let (x, y, nx, ny, rx, ry) = (fresh("x"), fresh("y"), fresh(), fresh(), fresh("x"), fresh("y"))
        let nac = NestedCondition(
            conclusion: RuleGraph(name: "backEdge", nodes: [nx, ny], edges: [RuleEdge(source: ny.id, target: nx.id, type: next)]),
            mappings: [NodeMapping(origin: x.id, image: nx.id), NodeMapping(origin: y.id, image: ny.id)])
        return Rule(
            name: "useUnlessBackEdge",
            lhs: RuleGraph(nodes: [x, y], edges: [RuleEdge(source: x.id, target: y.id, type: next)], formula: .not(.condition(nac))),
            rhs: RuleGraph(nodes: [rx, ry], edges: [RuleEdge(source: rx.id, target: ry.id, type: next)]),
            mappings: [NodeMapping(origin: x.id, image: rx.id), NodeMapping(origin: y.id, image: ry.id)])
    }

    /// A rule that deletes the first edge of a chain of two edges.
    mutating func deleteFirstOfChain() -> Rule {
        let (a, b, c, ra, rb, rc) = (fresh("a"), fresh("b"), fresh("c"), fresh("a"), fresh("b"), fresh("c"))
        return Rule(
            name: "deleteFirstOfChain",
            lhs: RuleGraph(nodes: [a, b, c], edges: [RuleEdge(source: a.id, target: b.id, type: next), RuleEdge(source: b.id, target: c.id, type: next)]),
            rhs: RuleGraph(nodes: [ra, rb, rc], edges: [RuleEdge(source: rb.id, target: rc.id, type: next)]),
            mappings: [NodeMapping(origin: a.id, image: ra.id), NodeMapping(origin: b.id, image: rb.id), NodeMapping(origin: c.id, image: rc.id)])
    }

    /// An identity rule that matches an edge unless its target links to a further node.
    mutating func useUnlessTargetLinks() -> Rule {
        let (x, y, ny, nz, rx, ry) = (fresh("x"), fresh("y"), fresh(), fresh(), fresh("x"), fresh("y"))
        let nac = NestedCondition(
            conclusion: RuleGraph(name: "onward", nodes: [ny, nz], edges: [RuleEdge(source: ny.id, target: nz.id, type: next)]),
            mappings: [NodeMapping(origin: y.id, image: ny.id)])
        return Rule(
            name: "useUnlessTargetLinks",
            lhs: RuleGraph(nodes: [x, y], edges: [RuleEdge(source: x.id, target: y.id, type: next)], formula: .not(.condition(nac))),
            rhs: RuleGraph(nodes: [rx, ry], edges: [RuleEdge(source: rx.id, target: ry.id, type: next)]),
            mappings: [NodeMapping(origin: x.id, image: rx.id), NodeMapping(origin: y.id, image: ry.id)])
    }
}
