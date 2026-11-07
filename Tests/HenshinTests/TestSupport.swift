//
//  TestSupport.swift
//  HenshinTests
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Testing

@testable import Henshin

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

    /// A loaded bank rule module together with a model to transform.
    struct Bank {
        /// The resource set that holds the module, the metamodel and the model.
        let resourceSet: ResourceSet
        /// The rules and units.
        let module: HenshinModule
        /// The model.
        let model: Resource
    }

    /// Loads the bank rules and a bank model into one resource set.
    ///
    /// - Parameter model: The file name of the model.
    /// - Returns: The loaded fixtures.
    static func bank(model: String = "bank-small.xmi") async throws -> Bank {
        let resourceSet = ResourceSet()
        try await ModelIO.registerMetamodels(at: [url("bank.ecore")], in: resourceSet)
        let module = try await HenshinModuleLoader.load(url: url("bank.henshin"), resourceSet: resourceSet)
        let loaded = try await ModelIO.load(url: url(model), resourceSet: resourceSet)
        return Bank(resourceSet: resourceSet, module: module, model: loaded.resource)
    }

    /// Loads the bank rules written in Henshin Text and a bank model into one resource set.
    ///
    /// The metamodel is not registered beforehand: the loader finds it beside the document.
    ///
    /// - Parameter model: The file name of the model.
    /// - Returns: The loaded fixtures.
    static func bankText(model: String = "bank-small.xmi") async throws -> Bank {
        let resourceSet = ResourceSet()
        let module = try await HenshinTextLoader.load(url: url("bank.henshin_text"), resourceSet: resourceSet)
        let loaded = try await ModelIO.load(url: url(model), resourceSet: resourceSet)
        return Bank(resourceSet: resourceSet, module: module, model: loaded.resource)
    }

    /// The bank metamodel package, read on its own.
    static func bankPackage() async throws -> EPackage {
        let resourceSet = ResourceSet()
        return try #require(try await ModelIO.registerMetamodels(at: [url("bank.ecore")], in: resourceSet).first)
    }

    /// Loads a model into a resource set that already knows its metamodel.
    ///
    /// - Parameters:
    ///   - name: The file name of the model.
    ///   - resourceSet: The resource set.
    /// - Returns: The resource of the model.
    static func model(_ name: String, in resourceSet: ResourceSet) async throws -> Resource {
        try await ModelIO.load(url: url(name), resourceSet: resourceSet).resource
    }
}

/// Describes models in a canonical text form, so that two models can be compared.
///
/// Objects are described by class, attributes in name order and references as containment
/// paths, with contained objects nested below their containers in order. Identities do not
/// appear, so a transformed model and an expected model read from a file compare equal when
/// they have the same structure.
enum ModelDescription {
    /// Describes the model of a resource.
    ///
    /// - Parameter resource: The resource.
    /// - Returns: The canonical description.
    static func of(_ resource: Resource) async -> String {
        let objects = await resource.getAllObjects().compactMap { $0 as? DynamicEObject }
        let roots = await resource.getRootObjects().compactMap { $0 as? DynamicEObject }
        var byID: [EUUID: DynamicEObject] = [:]
        for object in objects { byID[object.id] = object }
        var paths: [EUUID: String] = [:]
        func assignPaths(_ object: DynamicEObject, _ path: String) {
            paths[object.id] = path
            for reference in object.eClass.eAllReferences where reference.containment {
                for (index, child) in ModelGraph.identifiers(object.eGet(reference)).enumerated() {
                    if let childObject = byID[child] { assignPaths(childObject, "\(path)/\(reference.name).\(index)") }
                }
            }
        }
        for (index, root) in roots.enumerated() { assignPaths(root, "/\(index)") }
        var lines: [String] = []
        func describe(_ object: DynamicEObject, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            var parts: [String] = []
            for attribute in object.eClass.eAllAttributes.sorted(by: { $0.name < $1.name }) {
                if let value = object.eGetWithDefault(attribute) { parts.append("\(attribute.name)=\(value)") }
            }
            for reference in object.eClass.eAllReferences.sorted(by: { $0.name < $1.name }) where !reference.containment {
                let targets = ModelGraph.identifiers(object.eGet(reference)).map { paths[$0] ?? "?" }
                if !targets.isEmpty { parts.append("\(reference.name)->[\(targets.joined(separator: ","))]") }
            }
            lines.append("\(indent)\(object.eClass.name)(\(parts.joined(separator: " ")))")
            for reference in object.eClass.eAllReferences where reference.containment {
                for child in ModelGraph.identifiers(object.eGet(reference)) {
                    if let childObject = byID[child] { describe(childObject, depth: depth + 1) }
                }
            }
        }
        for root in roots { describe(root, depth: 0) }
        let contained = Set(paths.keys)
        let strays = objects.filter { !contained.contains($0.id) }.count
        if strays > 0 { lines.append("unreachable objects: \(strays)") }
        return lines.joined(separator: "\n")
    }
}

/// Queries on bank models.
enum BankQueries {
    /// The dynamic objects of a class.
    ///
    /// - Parameters:
    ///   - className: The name of the class.
    ///   - resource: The resource.
    /// - Returns: The objects, in the order of the resource.
    static func objects(_ className: String, in resource: Resource) async -> [DynamicEObject] {
        await resource.getAllObjects().compactMap { $0 as? DynamicEObject }.filter { $0.eClass.name == className }
    }

    /// The account with an id.
    ///
    /// - Parameters:
    ///   - id: The id of the account.
    ///   - resource: The resource.
    /// - Returns: The account, if there is one.
    static func account(_ id: Int, in resource: Resource) async -> DynamicEObject? {
        await objects("Account", in: resource).first { ($0.eGet("id") as? Int) == id }
    }

    /// The client with a name.
    ///
    /// - Parameters:
    ///   - name: The name of the client.
    ///   - resource: The resource.
    /// - Returns: The client, if there is one.
    static func client(_ name: String, in resource: Resource) async -> DynamicEObject? {
        await objects("Client", in: resource).first { ($0.eGet("name") as? String) == name }
    }

    /// The balance of the account with an id.
    static func balance(_ id: Int, in resource: Resource) async -> Int? {
        await account(id, in: resource)?.eGet("balance") as? Int
    }

    /// The ids of all accounts, sorted.
    static func accountIDs(in resource: Resource) async -> [Int] {
        await objects("Account", in: resource).compactMap { $0.eGet("id") as? Int }.sorted()
    }
}
