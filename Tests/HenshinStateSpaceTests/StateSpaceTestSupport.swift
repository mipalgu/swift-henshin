//
//  StateSpaceTestSupport.swift
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

    /// A loaded rule module together with a model.
    struct Loaded {
        /// The resource set that holds the module, the metamodel and the model.
        let resourceSet: ResourceSet
        /// The rules and units.
        let module: HenshinModule
        /// The model.
        let model: Resource
    }

    /// Loads a rule module, its metamodel and a model from a directory.
    ///
    /// - Parameters:
    ///   - rules: The file name of the rule module.
    ///   - metamodel: The file name of the metamodel.
    ///   - model: The file name of the model.
    ///   - directory: The directory of the files (default: the fixtures).
    /// - Returns: The loaded files.
    static func load(_ rules: String, metamodel: String, model: String, in directory: URL = Fixtures.directory) async throws -> Loaded {
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [directory.appendingPathComponent(metamodel)], in: resourceSet)
        let module = try await HenshinModuleLoader.load(url: directory.appendingPathComponent(rules), resourceSet: resourceSet)
        let loaded = try await ModelIO.load(url: directory.appendingPathComponent(model), resourceSet: resourceSet)
        return Loaded(resourceSet: resourceSet, module: module, model: loaded.resource)
    }

    /// The token ring of three processes.
    static func ring() async throws -> Loaded { try await load("ring.henshin", metamodel: "ring.ecore", model: "ring-3.xmi") }

    /// The bank example.
    static func bank() async throws -> Loaded { try await load("bank.henshin", metamodel: "bank.ecore", model: "bank-small.xmi") }

    /// A graph model.
    static func graph(_ model: String) async throws -> Loaded {
        try await load("graphs.henshin", metamodel: "graphs.ecore", model: model)
    }
}

extension HenshinModule {
    /// The rule with a name, failing the test if there is none.
    ///
    /// - Parameter name: The name of the rule.
    /// - Returns: The rule.
    func rule(_ name: String) throws -> Rule { try #require(rules.first { $0.name == name }) }
}

/// The attribute values of the objects of a class in a model.
///
/// - Parameters:
///   - className: The name of the class.
///   - feature: The name of the attribute.
///   - model: The model.
/// - Returns: The values as text, sorted.
func values(of className: String, _ feature: String, in model: ResourceSnapshot) -> [String] {
    model.objects.compactMap { $0 as? DynamicEObject }.filter { $0.eClass.name == className }
        .map { String(describing: $0.eGetWithDefault(feature) ?? "null") }.sorted()
}
