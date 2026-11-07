//
//  CheckingTests.swift
//  HenshinStateSpaceTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin
import Testing

@testable import HenshinStateSpace

/// Tests of property checking on explored state spaces.
@Suite("Checking")
struct CheckingTests {
    /// The explored token ring and a checker for it.
    func ringChecker(rules: [String] = ExplorationTests.protocolRules) async throws -> (Fixtures.Loaded, ModelChecker) {
        let ring = try await Fixtures.ring()
        let space = try await StateSpaceExplorer(module: ring.module, rules: rules).explore(from: ring.model)
        return (ring, ModelChecker(stateSpace: space, resourceSet: ring.resourceSet))
    }

    @Test("Mutual exclusion holds as a forbidden pattern")
    func forbiddenPattern() async throws {
        let (ring, checker) = try await ringChecker()
        let result = try await checker.checkInvariant(.forbidden(try ring.module.rule("twoCritical")))
        #expect(result.holds)
        #expect(result.isConclusive)
        #expect(result.state == nil)
        #expect(result.description.contains("holds"))
    }

    @Test("Mutual exclusion holds as an AQL invariant")
    func aqlInvariant() async throws {
        let (_, checker) = try await ringChecker()
        let result = try await checker.checkInvariant(.aql("self.processes->select(p | p.state = 'critical')->size() <= 1"))
        #expect(result.holds)
        let counted = try await checker.states(satisfying: .aql("self.processes->exists(p | p.state = 'critical')"))
        #expect(counted.count == 4)
    }

    @Test("Reaching the critical section takes two steps")
    func reachability() async throws {
        let (ring, checker) = try await ringChecker()
        let result = try await checker.checkReachable(.pattern(try ring.module.rule("someCritical")))
        #expect(result.holds)
        #expect(result.path.map(\.label) == ["request", "enter"])
        #expect(result.description.contains("after 2 step(s)"))
        let never = try await checker.checkReachable(.pattern(try ring.module.rule("twoCritical")))
        #expect(!never.holds)
        #expect(never.isConclusive)
    }

    @Test("A violated invariant comes with a shortest counterexample")
    func counterexample() async throws {
        let (_, checker) = try await ringChecker()
        let result = try await checker.checkInvariant(.aql("self.processes->forAll(p | p.state <> 'waiting')"))
        #expect(!result.holds)
        #expect(result.isConclusive)
        #expect(result.path.map(\.label) == ["request"])
        let state = try #require(result.state)
        #expect(values(of: "Process", "state", in: checker.stateSpace.states[state].model) == ["idle", "idle", "waiting"])
    }

    @Test("A protocol without leaving the critical section deadlocks")
    func deadlock() async throws {
        let (_, checker) = try await ringChecker(rules: ["request", "enter"])
        #expect(checker.stateSpace.states.count == 12)
        let result = checker.checkDeadlockFreedom()
        #expect(!result.holds)
        #expect(result.path.count == 4)
        #expect(result.path.map(\.label).filter { $0 == "enter" }.count == 1)
        let deadlocks = try await checker.states(satisfying: .deadlock)
        #expect(deadlocks == checker.stateSpace.deadlocks)
        let (_, live) = try await ringChecker()
        #expect(live.checkDeadlockFreedom().holds)
    }

    @Test("Predicates combine with not, and and or")
    func combinations() async throws {
        let (ring, checker) = try await ringChecker()
        let critical = StatePredicate.pattern(try ring.module.rule("someCritical"))
        let waiting = StatePredicate.aql("self.processes->exists(p | p.state = 'waiting')")
        let both = try await checker.states(satisfying: .and(critical, waiting))
        let either = try await checker.states(satisfying: .or(critical, waiting))
        let neither = try await checker.states(satisfying: .not(.or(critical, waiting)))
        #expect(both.count == 3)
        #expect(either.count + neither.count == checker.stateSpace.states.count)
        #expect(neither.count == 1)
        let custom = StatePredicate.custom(name: "small") { $0.count < 10 }
        #expect(try await checker.checkInvariant(custom).holds)
        #expect(StatePredicate.and(critical, .not(waiting)).description == "(pattern someCritical and not aql(self.processes->exists(p | p.state = 'waiting')))")
        #expect(StatePredicate.or(.deadlock, custom).description == "(deadlock or small)")
    }

    @Test("Results on incomplete state spaces are inconclusive unless a witness exists")
    func incomplete() async throws {
        let graph = try await Fixtures.graph("graph-empty.xmi")
        let space = try await StateSpaceExplorer(rules: [try graph.module.rule("createNode")], options: ExplorationOptions(maximumDepth: 2))
            .explore(from: graph.model)
        let checker = ModelChecker(stateSpace: space, resourceSet: graph.resourceSet)
        let freedom = checker.checkDeadlockFreedom()
        #expect(freedom.holds && !freedom.isConclusive)
        #expect(freedom.description.contains("inconclusive"))
        let small = try await checker.checkInvariant(.aql("self.nodes->size() < 2"))
        #expect(!small.holds && small.isConclusive)
        let large = try await checker.checkReachable(.aql("self.nodes->size() > 5"))
        #expect(!large.holds && !large.isConclusive)
    }

    @Test("Invalid AQL properties are reported")
    func invalidProperty() async throws {
        let (_, checker) = try await ringChecker()
        await #expect(throws: StateSpaceError.self) { _ = try await checker.checkInvariant(.aql("self.processes->")) }
        await #expect(throws: StateSpaceError.self) { _ = try await checker.checkInvariant(.aql("self.processes->size()")) }
    }
}
