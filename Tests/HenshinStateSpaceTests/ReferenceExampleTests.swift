//
//  ReferenceExampleTests.swift
//  HenshinStateSpaceTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Henshin
import Testing

@testable import HenshinStateSpace

/// The directory of Henshin's published examples, if the environment names one.
///
/// The examples are not part of the package; set `HENSHIN_REFERENCE_EXAMPLES` to the
/// `examples` source directory of a checkout of Eclipse Henshin to run these comparisons.
let referenceExamples = ProcessInfo.processInfo.environment["HENSHIN_REFERENCE_EXAMPLES"].map { URL(fileURLWithPath: $0) }

/// Comparisons with the state spaces of Henshin's published examples.
@Suite("Henshin reference examples", .enabled(if: referenceExamples != nil))
struct ReferenceExampleTests {
    @Test("Dining philosophers: n philosophers have 3^n states", arguments: [3, 4, 5])
    func diningPhilosophers(philosophers: Int) async throws {
        let directory = try #require(referenceExamples).appendingPathComponent("diningphils")
        let loaded = try await Fixtures.load(
            "diningphils.henshin", metamodel: "diningphils.ecore", model: "3-phils-init.xmi", in: directory)
        for _ in 3..<philosophers {
            #expect(try await HenshinEngine().apply(unitNamed: "createPhil", of: loaded.module, to: loaded.model).succeeded)
        }
        let explorer = try StateSpaceExplorer(module: loaded.module, rules: ["left", "right", "release"])
        let space = try await explorer.explore(from: loaded.model)
        print("Dining philosophers \(philosophers): \(space), \(space.statistics.duration) s")
        #expect(space.states.count == Int(pow(3.0, Double(philosophers))))
        #expect(space.isComplete)
        #expect(ModelChecker(stateSpace: space).checkDeadlockFreedom().holds == false)
    }

    @Test(
        "Dining philosophers: exploration time by number of workers",
        .enabled(if: ProcessInfo.processInfo.environment["HENSHIN_BENCHMARK"] != nil), arguments: [6, 7, 8])
    func benchmark(philosophers: Int) async throws {
        let directory = try #require(referenceExamples).appendingPathComponent("diningphils")
        for workers in [1, 4, 8] {
            let loaded = try await Fixtures.load(
                "diningphils.henshin", metamodel: "diningphils.ecore", model: "3-phils-init.xmi", in: directory)
            for _ in 3..<philosophers {
                _ = try await HenshinEngine().apply(unitNamed: "createPhil", of: loaded.module, to: loaded.model)
            }
            let explorer = try StateSpaceExplorer(
                module: loaded.module, rules: ["left", "right", "release"], options: ExplorationOptions(concurrency: workers))
            let space = try await explorer.explore(from: loaded.model)
            print("Benchmark \(philosophers) philosophers, \(workers) workers: \(space), \(space.statistics.duration) s, \(space.statistics.isomorphismChecks) isomorphism checks")
            #expect(space.states.count == Int(pow(3.0, Double(philosophers))))
        }
    }
}
