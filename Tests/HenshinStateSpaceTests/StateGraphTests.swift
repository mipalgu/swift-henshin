//
//  StateGraphTests.swift
//  HenshinStateSpaceTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin
import Testing

@testable import HenshinStateSpace

/// Tests of state graphs, certificates and isomorphism.
@Suite("State graphs")
struct StateGraphTests {
    /// A model of graph nodes linked by next references.
    ///
    /// - Parameters:
    ///   - count: The number of nodes.
    ///   - edges: The next references, by node position.
    ///   - marked: The positions of the marked nodes.
    ///   - order: The order in which the nodes are added to the model.
    /// - Returns: The model.
    static func model(count: Int, edges: [(Int, Int)], marked: Set<Int> = [], order: [Int]? = nil) async throws -> ResourceSnapshot {
        let module = try await Fixtures.graph("graph-empty.xmi").module
        let node = try module.rule("deleteNext").lhs.nodes[0].type
        var objects = (0..<count).map { _ in DynamicEObject(eClass: node) }
        for position in marked { objects[position].eSet("marked", value: true) }
        for (source, target) in edges {
            var targets = objects[source].eGet("next") as? [EUUID] ?? []
            targets.append(objects[target].id)
            objects[source].eSet("next", value: targets)
        }
        let resource = Resource()
        await resource.add(contentsOf: (order ?? Array(0..<count)).map { objects[$0] })
        return await resource.snapshot()
    }

    /// The edges of a directed cycle through nodes.
    static func cycle(_ nodes: [Int]) -> [(Int, Int)] {
        nodes.indices.map { (nodes[$0], nodes[($0 + 1) % nodes.count]) }
    }

    @Test("Isomorphic models have equal certificates and an isomorphism")
    func isomorphic() async throws {
        let first = StateGraph(try await Self.model(count: 4, edges: [(0, 1), (1, 2), (2, 3), (0, 2)], marked: [0]))
        let second = StateGraph(
            try await Self.model(count: 4, edges: [(3, 2), (2, 1), (1, 0), (3, 1)], marked: [3], order: [2, 0, 3, 1]))
        #expect(first.certificate == second.certificate)
        let mapping = try #require(first.isomorphism(to: second))
        #expect(Set(mapping) == Set(0..<4))
        #expect(first.identityForm != second.identityForm)
    }

    @Test("Attribute values and edge directions tell models apart")
    func different() async throws {
        let base = StateGraph(try await Self.model(count: 3, edges: [(0, 1), (1, 2)]))
        let marked = StateGraph(try await Self.model(count: 3, edges: [(0, 1), (1, 2)], marked: [1]))
        let reversed = StateGraph(try await Self.model(count: 3, edges: [(1, 0), (1, 2)]))
        let fewer = StateGraph(try await Self.model(count: 3, edges: [(0, 1)]))
        #expect(base.certificate != marked.certificate)
        #expect(base.isomorphism(to: marked) == nil)
        #expect(base.isomorphism(to: reversed) == nil)
        #expect(base.isomorphism(to: fewer) == nil)
    }

    @Test("Equal certificates of non-isomorphic models are told apart by the exact check")
    func colourRefinementLimit() async throws {
        let six = StateGraph(try await Self.model(count: 6, edges: Self.cycle([0, 1, 2, 3, 4, 5])))
        let twoThrees = StateGraph(try await Self.model(count: 6, edges: Self.cycle([0, 1, 2]) + Self.cycle([3, 4, 5])))
        #expect(six.certificate == twoThrees.certificate)
        #expect(six.isomorphism(to: twoThrees) == nil)
        let rotated = StateGraph(try await Self.model(count: 6, edges: Self.cycle([3, 4, 5, 0, 1, 2]), order: [5, 4, 3, 2, 1, 0]))
        #expect(six.isomorphism(to: rotated) != nil)
    }

    @Test("Loops and parallel structure are respected")
    func loops() async throws {
        let loop = StateGraph(try await Self.model(count: 2, edges: [(0, 0), (0, 1)]))
        let other = StateGraph(try await Self.model(count: 2, edges: [(1, 1), (1, 0)], order: [1, 0]))
        let moved = StateGraph(try await Self.model(count: 2, edges: [(1, 1), (0, 1)]))
        #expect(loop.isomorphism(to: other) != nil)
        #expect(loop.isomorphism(to: moved) == nil)
    }

    @Test("The stable hasher is deterministic and separates strings")
    func hasher() {
        #expect(StableHasher.hash("abc") == StableHasher.hash("abc"))
        #expect(StableHasher.hash("ab") != StableHasher.hash("abc"))
        var first = StableHasher()
        first.combine("a")
        first.combine("bc")
        var second = StableHasher()
        second.combine("ab")
        second.combine("c")
        #expect(first.finalise() != second.finalise())
    }

    @Test("Cyclic exploration identifies symmetric states")
    func symmetricExploration() async throws {
        let snapshot = try await Self.model(count: 3, edges: Self.cycle([0, 1, 2]), marked: [0])
        let resource = Resource()
        await resource.restore(snapshot)
        let module = try await Fixtures.graph("graph-empty.xmi").module
        let space = try await StateSpaceExplorer(rules: [try module.rule("propagate")]).explore(from: resource)
        #expect(space.states.count == 3)
        #expect(space.deadlocks.count == 1)
        let identity = try await StateSpaceExplorer(rules: [try module.rule("mark")], options: ExplorationOptions(equivalence: .identity))
            .explore(from: resource)
        let iso = try await StateSpaceExplorer(rules: [try module.rule("mark")]).explore(from: resource)
        #expect(identity.states.count == 4)
        #expect(iso.states.count == 3)
    }
}
