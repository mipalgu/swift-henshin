//
//  ScaleAndReferenceTests.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

/// Tests of larger models, persistence and, on request, the reference Henshin examples.
@Suite("Scale, persistence and reference examples")
struct ScaleAndReferenceTests {
    /// The XMI text of a bank with a number of clients, each owning one account.
    static func bankDocument(clients: Int) -> String {
        var text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <bank:Bank xmi:version="2.0" xmlns:xmi="http://www.omg.org/XMI" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:bank="http://example.org/bank" name="Generated">

            """
        for index in 0..<clients { text += "  <clients name=\"c\(index)\" accounts=\"//@accounts.\(index)\"/>\n" }
        for index in 0..<clients { text += "  <accounts id=\"\(index)\" balance=\"\(index % 7)\" owner=\"//@clients.\(index)\"/>\n" }
        return text + "</bank:Bank>\n"
    }

    /// Loads a generated bank into the resource set of the bank fixtures.
    static func generatedBank(clients: Int) async throws -> Fixtures.Bank {
        let fixtures = try await Fixtures.bank()
        let loaded = try await ModelIO.load(
            data: Data(bankDocument(clients: clients).utf8), uri: Fixtures.url("generated-\(clients).xmi").absoluteString,
            format: .xmi, resourceSet: fixtures.resourceSet)
        return Fixtures.Bank(resourceSet: fixtures.resourceSet, module: fixtures.module, model: loaded.resource)
    }

    @Test("Rules apply to a model of thousands of objects")
    func scale() async throws {
        let clients = 2_000
        let bank = try await Self.generatedBank(clients: clients)
        let engine = HenshinEngine()
        let clock = ContinuousClock()
        var depositStatistics = MatchStatistics()
        let deposits = try await clock.measure {
            for id in stride(from: 0, to: clients, by: 100) {
                let result = try await engine.apply(unitNamed: "deposit", of: bank.module, to: bank.model, parameters: ["id": id, "amount": 1])
                #expect(result.succeeded)
                depositStatistics.candidates += result.statistics.candidates
            }
        }
        var closeStatistics = MatchStatistics()
        let closes = try await clock.measure {
            for index in stride(from: 1, to: clients, by: 100) {
                let result = try await engine.apply(unitNamed: "closeClient", of: bank.module, to: bank.model, parameters: ["name": "c\(index)"])
                #expect(result.succeeded)
                closeStatistics.candidates += result.statistics.candidates
            }
        }
        let loopModel = try await Self.generatedBank(clients: 300)
        var loopResult: UnitApplication?
        let loop = try await clock.measure {
            loopResult = try await engine.apply(unitNamed: "freezeAll", of: loopModel.module, to: loopModel.model)
        }
        #expect(loopResult?.appliedRules.count == 300)
        print(
            "Scale: \(clients) clients; 20 deposits by id \(deposits) (\(depositStatistics.candidates) candidates);",
            "20 closeClient with multi-rule \(closes) (\(closeStatistics.candidates) candidates);",
            "freezeAll over 300 accounts \(loop) (\(loopResult?.statistics.candidates ?? 0) candidates,",
            "\(loopResult?.statistics.conditionChecks ?? 0) condition checks)")
        #expect(depositStatistics.candidates <= 20 * (clients + 1), "each deposit scans the accounts at most once")
        #expect(closeStatistics.candidates <= 20 * (clients + 1) * 3, "multi-matches navigate from the bound client")
    }

    @Test("A transformed model is saved and read back unchanged")
    func persistence() async throws {
        let bank = try await Fixtures.bank()
        _ = try await HenshinEngine().apply(
            unitNamed: "openAndFund", of: bank.module, to: bank.model, parameters: ["client": "Bob", "accountId": 9, "amount": 4])
        _ = try await HenshinEngine().apply(unitNamed: "closeClient", of: bank.module, to: bank.model, parameters: ["name": "Alice"])
        var diagnostics = ConversionDiagnostics()
        let text = try await ModelIO.serialise(bank.model, format: .xmi, diagnostics: &diagnostics)
        let reread = try await ModelIO.load(
            data: Data(text.utf8), uri: Fixtures.url("saved.xmi").absoluteString, format: .xmi, resourceSet: bank.resourceSet)
        #expect(await ModelDescription.of(reread.resource) == ModelDescription.of(bank.model))
        #expect(await BankQueries.accountIDs(in: reread.resource) == [2, 3, 9])
    }

    /// The directory of the reference Henshin examples, if the environment names one.
    static var referenceDirectory: URL? {
        ProcessInfo.processInfo.environment["HENSHIN_REFERENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @Test(
        "The reference Henshin examples load and validate",
        .enabled(if: ScaleAndReferenceTests.referenceDirectory != nil, "set HENSHIN_REFERENCE_DIR to run"))
    func referenceExamples() async throws {
        let directory = try #require(Self.referenceDirectory)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == HenshinConstants.fileExtension }
            .sorted { $0.path < $1.path } ?? []
        var loaded = 0
        var rules = 0
        var findings: [String: Int] = [:]
        var failures: [String] = []
        for file in files {
            do {
                let module = try await HenshinModuleLoader.load(url: file, resourceSet: ResourceSet())
                loaded += 1
                rules += module.rules.count
                for finding in HenshinValidator.validate(module) {
                    findings[finding.code, default: 0] += 1
                    if finding.severity == .error { print("  \(file.lastPathComponent): \(finding.message)") }
                }
            } catch {
                failures.append("\(file.lastPathComponent): \(error)")
            }
        }
        print("Reference examples: \(loaded) of \(files.count) documents loaded with \(rules) rules")
        print("Validation findings by code: \(findings.sorted { $0.key < $1.key })")
        for failure in failures { print("  not loaded: \(failure)") }
        #expect(loaded > 0)
    }

    @Test(
        "The reference bank example transforms its example model",
        .enabled(if: ScaleAndReferenceTests.referenceDirectory != nil, "set HENSHIN_REFERENCE_DIR to run"))
    func referenceBank() async throws {
        let directory = try #require(Self.referenceDirectory).appendingPathComponent("bank")
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [directory.appendingPathComponent("bank.ecore")], in: resourceSet)
        let module = try await HenshinModuleLoader.load(url: directory.appendingPathComponent("bank.henshin"), resourceSet: resourceSet)
        let model = try await ModelIO.load(url: directory.appendingPathComponent("example-bank.xmi"), resourceSet: resourceSet).resource
        let engine = HenshinEngine()
        let create = try await engine.apply(unitNamed: "createAccount", of: module, to: model, parameters: ["client": "Alice", "accountId": 5])
        let transfer = try await engine.apply(unitNamed: "transferMoney", of: module, to: model,
            parameters: ["client": "Alice", "fromId": 1, "toId": 2, "amount": 50.0])
        let delete = try await engine.apply(unitNamed: "deleteAllAccounts", of: module, to: model, parameters: ["client": "Charles"])
        print("Reference bank: createAccount \(create.succeeded), transferMoney \(transfer.succeeded), deleteAllAccounts \(delete.succeeded)")
        let expected = try await ModelIO.load(url: directory.appendingPathComponent("example-result.xmi"), resourceSet: resourceSet).resource
        let same = await ModelDescription.of(model) == ModelDescription.of(expected)
        print("Reference bank: result equals example-result.xmi: \(same)")
        if !same {
            print("Actual:\n\(await ModelDescription.of(model))\nExpected:\n\(await ModelDescription.of(expected))")
        }
        #expect(create.succeeded && transfer.succeeded && delete.succeeded)
        #expect(same)
    }
}
