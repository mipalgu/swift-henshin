//
//  HenshinMetamodel.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import Foundation

/// The Henshin transformation metamodel, shipped with this package.
///
/// The package bundles the unchanged `henshin.ecore` of the Eclipse Henshin project
/// (published under the Eclipse Public License; see the notice beside it), so that Henshin
/// documents load as instances of it through the XMI loader of `ECore`.
public enum HenshinMetamodel {
    /// The name of the resource directory of this target.
    static let bundleName = ResourceBundleName(
        package: HenshinConstants.resourcePackageName, target: HenshinConstants.resourceTargetName)

    /// The location of the bundled metamodel document.
    ///
    /// - Returns: The location, or `nil` if the resources of the package are missing.
    public static func url() -> URL? {
        BundledResources.url(
            forResource: HenshinConstants.metamodelResourceName, withExtension: ModelFormat.ecore.fileExtension,
            subdirectory: HenshinConstants.resourceSubdirectory, in: .module, bundleName: bundleName)
    }

    /// Loads the metamodel and registers it with a resource set under its namespace URI.
    ///
    /// The metamodel is loaded once per process and shared.
    ///
    /// - Parameter resourceSet: The resource set with which to register the metamodel.
    /// - Returns: The root package of the metamodel.
    /// - Throws: ``HenshinError/metamodelMissing`` if the resources of the package are
    ///   missing, or the error of the loader.
    @discardableResult
    public static func register(in resourceSet: ResourceSet) async throws -> EPackage {
        if let registered = await resourceSet.getMetamodel(uri: HenshinConstants.nsURI) { return registered }
        guard url() != nil else { throw HenshinError.metamodelMissing }
        return try await EPackage.bundled(
            named: HenshinConstants.metamodelResourceName, subdirectory: HenshinConstants.resourceSubdirectory,
            in: .module, bundleName: bundleName, registeringIn: resourceSet)
    }
}
