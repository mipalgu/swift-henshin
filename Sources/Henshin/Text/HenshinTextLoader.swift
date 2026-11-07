//
//  HenshinTextLoader.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// Loads Henshin modules from Henshin Text documents.
///
/// A Henshin Text document (conventionally with the extension `.henshin_text`) imports
/// metamodel packages by name with `ePackageImport`. The loader looks the names up among
/// the metamodels registered with the resource set and the packages of its loaded
/// resources. A package that is not found there is looked for, as Henshin's editor does, in
/// the Ecore documents beside the Henshin Text document: first in the one named after the
/// package, then in all of them.
public enum HenshinTextLoader {
    /// Loads a module from a Henshin Text document.
    ///
    /// - Parameters:
    ///   - url: The location of the document.
    ///   - resourceSet: The resource set whose metamodels the document imports; use the set
    ///     that holds the models to transform, so that rule types and model classes are the
    ///     same.
    ///   - metamodels: Ecore documents to register before the document is read.
    /// - Returns: The module.
    /// - Throws: ``HenshinError/invalidText(document:diagnostics:)`` if the document has
    ///   errors, or the error of reading the document or a metamodel.
    public static func load(url: URL, resourceSet: ResourceSet, metamodels: [URL] = []) async throws -> HenshinModule {
        let translation = try await translate(url: url, resourceSet: resourceSet, metamodels: metamodels)
        let errors = translation.diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else { throw HenshinError.invalidText(document: url.lastPathComponent, diagnostics: errors) }
        return translation.module
    }

    /// Reads and translates a Henshin Text document, reporting its problems rather than
    /// throwing them.
    ///
    /// - Parameters:
    ///   - url: The location of the document.
    ///   - resourceSet: The resource set whose metamodels the document imports.
    ///   - metamodels: Ecore documents to register before the document is read.
    /// - Returns: The module, as far as it could be translated, with the diagnostics.
    /// - Throws: The error of reading the document or a metamodel.
    public static func translate(url: URL, resourceSet: ResourceSet, metamodels: [URL] = []) async throws -> HenshinTextTranslation {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return try await translate(text: text, directory: url.deletingLastPathComponent(), resourceSet: resourceSet, metamodels: metamodels)
    }

    /// Reads and translates the text of a Henshin Text document.
    ///
    /// - Parameters:
    ///   - text: The document.
    ///   - directory: The directory in which to look for Ecore documents of imported
    ///     packages that the resource set does not know, if any.
    ///   - resourceSet: The resource set whose metamodels the document imports.
    ///   - metamodels: Ecore documents to register before the document is read.
    /// - Returns: The module, as far as it could be translated, with the diagnostics.
    /// - Throws: The error of reading a metamodel.
    public static func translate(
        text: String, directory: URL? = nil, resourceSet: ResourceSet, metamodels: [URL] = []
    ) async throws -> HenshinTextTranslation {
        if !metamodels.isEmpty { try await ModelIO.registerMetamodels(at: metamodels, in: resourceSet) }
        let parsed = HenshinText.parse(text)
        var packages = await knownPackages(in: resourceSet)
        /// The imports that no known package satisfies.
        func missing() -> [String] {
            parsed.document.imports.map(\.text).filter { name in !packages.contains { qualifiedNames(of: $0).contains(name) } }
        }
        if let directory, !missing().isEmpty {
            let documents = ecoreDocuments(in: directory)
            for name in missing() {
                let first = name.split(separator: HenshinTextConstants.qualifier).first.map(String.init) ?? name
                if let named = documents.first(where: { $0.deletingPathExtension().lastPathComponent == first }) {
                    _ = try? await ModelIO.registerMetamodels(at: [named], in: resourceSet)
                }
            }
            packages = await knownPackages(in: resourceSet)
            if !missing().isEmpty {
                for document in documents { _ = try? await ModelIO.registerMetamodels(at: [document], in: resourceSet) }
                packages = await knownPackages(in: resourceSet)
            }
        }
        return HenshinText.translate(parsed: parsed, packages: packages)
    }

    /// The root packages that a resource set knows: its registered metamodels and the
    /// packages of its resources, each once.
    static func knownPackages(in resourceSet: ResourceSet) async -> [EPackage] {
        var packages: [EPackage] = []
        for uri in await resourceSet.getMetamodelURIs(includingSubpackages: false) {
            if let package = await resourceSet.getMetamodel(uri: uri), !packages.contains(where: { $0.nsURI == package.nsURI }) {
                packages.append(package)
            }
        }
        for resource in await resourceSet.getResources() {
            for package in await resource.getRootObjects().compactMap({ $0 as? EPackage }) where !packages.contains(where: { $0.nsURI == package.nsURI }) {
                packages.append(package)
            }
        }
        return packages
    }

    /// The qualified names of a package and its nested packages.
    private static func qualifiedNames(of package: EPackage, prefix: String = "") -> [String] {
        let name = prefix.isEmpty ? package.name : prefix + String(HenshinTextConstants.qualifier) + package.name
        return [name] + package.eSubpackages.flatMap { qualifiedNames(of: $0, prefix: name) }
    }

    /// The Ecore documents in a directory, sorted by name.
    private static func ecoreDocuments(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == ModelFormat.ecore.fileExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
