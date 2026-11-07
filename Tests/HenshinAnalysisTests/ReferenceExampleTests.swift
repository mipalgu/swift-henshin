//
//  ReferenceExampleTests.swift
//  HenshinAnalysisTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Foundation
import Henshin
import Testing

@testable import HenshinAnalysis

/// The directory of Henshin's published examples, if the environment names one.
///
/// The examples are not part of the package; set `HENSHIN_REFERENCE_EXAMPLES` to the
/// `examples` source directory of a checkout of Eclipse Henshin to run these comparisons.
let referenceExamples = ProcessInfo.processInfo.environment["HENSHIN_REFERENCE_EXAMPLES"].map { URL(fileURLWithPath: $0) }

/// Analyses of Henshin's published conflict and dependency analysis example.
@Suite("Henshin reference examples", .enabled(if: referenceExamples != nil))
struct ReferenceExampleTests {
    @Test("The class diagram refactorings of Henshin's analysis example interact")
    func refactorings() async throws {
        let directory = try #require(referenceExamples).appendingPathComponent("cda")
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [directory.appendingPathComponent("classDiagramMM.ecore")], in: resourceSet)
        let module = try await HenshinModuleLoader.load(url: directory.appendingPathComponent("refactorings.henshin"), resourceSet: resourceSet)
        let analyser = CriticalPairAnalyser()
        let start = Date()
        let conflicts = analyser.analyse(module.rules, direction: .conflict, granularity: .minimalReasons)
        let dependencies = analyser.analyse(module.rules, direction: .dependency, granularity: .minimalReasons)
        print("Refactorings (\(module.rules.count) rules) in \(Date().timeIntervalSince(start)) s")
        print("Conflicts (minimal reasons):\n\(conflicts)")
        print("Dependencies (minimal reasons):\n\(dependencies)")
        #expect(!conflicts.interactingPairs.isEmpty)
        #expect(!dependencies.interactingPairs.isEmpty)
        let deleteClass = try #require(module.rules.first { $0.name == "deleteClass" })
        #expect(analyser.conflicts(first: deleteClass, second: deleteClass).kinds.contains(.deleteUse))
        let start2 = Date()
        let pairs = analyser.analyse(module.rules, direction: .conflict, granularity: .criticalPairs)
        let total = pairs.pairs.flatMap { $0 }.map(\.criticalPairs.count).reduce(0, +)
        print("Critical pairs: \(total) in \(Date().timeIntervalSince(start2)) s, truncated: \(pairs.pairs.flatMap { $0 }.contains { $0.isTruncated })")
    }
}
