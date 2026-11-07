//
//  HenshinTextCorpusTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests over the Henshin Text examples of the Henshin project, when a copy of them is
/// available.
///
/// Set `HENSHIN_TEXT_REFERENCE_DIR` to a directory that holds `.henshin_text` documents with
/// their Ecore metamodels and, where Henshin provides them, the `.henshin` documents that
/// Henshin's own translation produces.
@Suite("Henshin Text reference corpus")
struct HenshinTextCorpusTests {
    /// The directory of the reference documents, if one is given.
    static var referenceDirectory: URL? {
        ProcessInfo.processInfo.environment["HENSHIN_TEXT_REFERENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The Ecore documents for a Henshin Text document: those beside it or, if there are
    /// none, those in the directories beside its own.
    static func metamodels(for document: URL) -> [URL] {
        let manager = FileManager.default
        /// The Ecore documents in a directory.
        func ecore(in directory: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == ModelFormat.ecore.fileExtension }.sorted { $0.path < $1.path }
        }
        let directory = document.deletingLastPathComponent()
        let beside = ecore(in: directory)
        if !beside.isEmpty { return beside }
        let siblings = (try? manager.contentsOfDirectory(at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return siblings.sorted { $0.path < $1.path }.flatMap { ecore(in: $0) }
    }

    /// A summary of the structure of a rule, for comparison with Henshin's translation.
    static func summary(_ rule: Rule) -> String {
        /// The shape of a formula.
        func shape(_ formula: Formula?) -> String {
            switch formula {
            case nil: return "-"
            case .true?: return "T"
            case .condition(let condition)?:
                return "NC(\(condition.conclusion.nodes.count)n\(condition.conclusion.edges.count)e\(condition.mappings.count)m\(shape(condition.conclusion.formula)))"
            case .not(let child)?: return "!\(shape(child))"
            case .and(let left, let right)?: return "(\(shape(left))&\(shape(right)))"
            case .or(let left, let right)?: return "(\(shape(left))|\(shape(right)))"
            case .xor(let left, let right)?: return "(\(shape(left))^\(shape(right)))"
            }
        }
        let multi = rule.multiRules.map { summary($0) }.joined(separator: ";")
        return "\(rule.name)[L\(rule.lhs.nodes.count)n\(rule.lhs.edges.count)e R\(rule.rhs.nodes.count)n\(rule.rhs.edges.count)e "
            + "M\(rule.mappings.count) MM\(rule.multiMappings.count) P\(rule.parameters.count) C\(rule.attributeConditions.count) "
            + "F\(shape(rule.lhs.formula)) {\(multi)}]"
    }

    @Test(
        "The reference Henshin Text documents translate, validate, round-trip and match Henshin's translation",
        .enabled(if: HenshinTextCorpusTests.referenceDirectory != nil, "set HENSHIN_TEXT_REFERENCE_DIR to run"))
    func corpus() async throws {
        let directory = try #require(Self.referenceDirectory)
        let documents = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == HenshinTextConstants.fileExtension }
            .sorted { $0.path < $1.path } ?? []
        var translated = 0
        var stable = 0
        var compared = 0
        var matching = 0
        for document in documents {
            let name = document.deletingLastPathComponent().lastPathComponent + "/" + document.lastPathComponent
            let resourceSet = ResourceSet()
            let translation = try await HenshinTextLoader.translate(url: document, resourceSet: resourceSet, metamodels: Self.metamodels(for: document))
            let errors = translation.diagnostics.filter { $0.severity == .error }
            let warnings = translation.diagnostics.filter { $0.severity == .warning }
            print("\(name): \(translation.module.rules.count) rules, \(translation.module.units.count) units; \(errors.count) errors, \(warnings.count) warnings")
            for error in errors { print("  error \(error.range.map { "\($0.start.line):\($0.start.column)" } ?? "-") \(error.message)") }
            guard errors.isEmpty else { continue }
            translated += 1
            let findings = HenshinValidator.validate(translation.module)
            let validationErrors = findings.filter { $0.severity == .error }
            for finding in validationErrors { print("  validator error: \(finding.message)") }
            let counts = Dictionary(grouping: findings, by: \.code).mapValues(\.count)
            if !counts.isEmpty { print("  validator findings: \(counts.sorted { $0.key < $1.key })") }
            let packages = await HenshinTextLoader.knownPackages(in: resourceSet)
            let first = HenshinText.write(translation.module, packages: packages)
            let reread = HenshinText.translate(first.text, packages: packages)
            let second = HenshinText.write(reread.module, packages: packages)
            let isStable = reread.isValid && second.text == first.text
            if isStable { stable += 1 }
            let lost = first.diagnostics.filter { $0.severity != .information }
            print("  round trip: \(isStable ? "stable" : "UNSTABLE"); writer findings \(lost.count) (\(lost.map(\.message).joined(separator: "; ")))")
            for problem in reread.diagnostics where problem.severity == .error { print("  re-read error: \(problem.message)") }
            let expected = document.deletingPathExtension().appendingPathExtension(HenshinConstants.fileExtension)
            guard FileManager.default.fileExists(atPath: expected.path) else { continue }
            compared += 1
            let reference = try await HenshinModuleLoader.load(url: expected, resourceSet: resourceSet)
            let ours = Set(translation.module.rules.map(Self.summary))
            let theirs = Set(reference.rules.map(Self.summary))
            if ours == theirs {
                matching += 1
                print("  rules match Henshin's translation")
            } else {
                for rule in ours.subtracting(theirs).sorted() { print("  ours:   \(rule)") }
                for rule in theirs.subtracting(ours).sorted() { print("  theirs: \(rule)") }
            }
            let ourUnits = translation.module.units.filter { $0.rule == nil }.map { "\($0.kind.className) \($0.parameters.count)" }.sorted()
            let theirUnits = reference.units.filter { $0.rule == nil }.map { "\($0.kind.className) \($0.parameters.count)" }.sorted()
            print("  units: ours \(ourUnits), Henshin's \(theirUnits)")
        }
        print("Henshin Text corpus: \(translated) of \(documents.count) translated without errors, \(stable) stable round trips, "
            + "\(matching) of \(compared) with rules matching Henshin's translation")
        #expect(translated > 0)
        try await bankBehaviour(in: directory)
    }

    /// Applies the rules of Henshin's bank test case, translated by this package and by
    /// Henshin, to Henshin's example bank model and compares the results.
    func bankBehaviour(in directory: URL) async throws {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        guard let text = files.first(where: { $0.lastPathComponent == "bank.\(HenshinTextConstants.fileExtension)" }),
            let model = files.first(where: { $0.lastPathComponent == "example-bank.xmi" })
        else { return }
        let reference = text.deletingPathExtension().appendingPathExtension(HenshinConstants.fileExtension)
        let metamodel = text.deletingLastPathComponent().appendingPathComponent("bank.ecore")
        guard FileManager.default.fileExists(atPath: reference.path), FileManager.default.fileExists(atPath: metamodel.path) else { return }
        let scenarios: [(String, ParameterValues)] = [
            ("createAccount", ["client": "Alice", "accountId": 5]),
            ("transferMoney", ["client": "Alice", "fromId": 1, "toId": 2, "amount": 50.0]),
            ("deleteAllAccounts", ["client": "Charles"]),
        ]
        let ourSet = ResourceSet()
        let ours = try await HenshinTextLoader.load(url: text, resourceSet: ourSet, metamodels: [metamodel])
        let ourModel = try await ModelIO.load(url: model, resourceSet: ourSet).resource
        let theirSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [metamodel], in: theirSet)
        let theirs = try await HenshinModuleLoader.load(url: reference, resourceSet: theirSet)
        let theirModel = try await ModelIO.load(url: model, resourceSet: theirSet).resource
        let engine = HenshinEngine()
        for (unit, parameters) in scenarios {
            let ourResult = try await engine.apply(unitNamed: unit, of: ours, to: ourModel, parameters: parameters)
            let theirResult = try await engine.apply(unitNamed: unit, of: theirs, to: theirModel, parameters: parameters)
            print("Bank test case: \(unit) succeeded \(ourResult.succeeded) (Henshin's translation \(theirResult.succeeded))")
            #expect(ourResult.succeeded == theirResult.succeeded, "\(unit)")
        }
        let same = await ModelDescription.of(ourModel) == ModelDescription.of(theirModel)
        print("Bank test case: models equal after both translations: \(same)")
        #expect(same)
    }
}
