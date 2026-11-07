//
//  HenshinModuleLoader.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// Loads Henshin modules from Henshin documents.
///
/// A Henshin document (conventionally with the extension `.henshin`) is an XMI document of
/// the Henshin metamodel. The loader registers the bundled metamodel with the resource set,
/// reads the document with the XMI loader of `ECore` and turns the resulting objects into a
/// ``HenshinModule``. The metamodels that the rules refer to are found among the resources
/// and registered metamodels of the resource set and, failing that, loaded from the
/// locations that the document gives for them.
public enum HenshinModuleLoader {
    /// Loads a Henshin module from a document.
    ///
    /// - Parameters:
    ///   - url: The location of the Henshin document.
    ///   - resourceSet: The resource set into which the document and its metamodels are
    ///     loaded; use the set that holds the models to transform, so that rule types and
    ///     model classes are the same.
    ///   - metamodels: Ecore documents to register before the document is read.
    /// - Returns: The module.
    /// - Throws: ``HenshinError`` if the document holds no module or a reference cannot be
    ///   resolved, or the error of the XMI loader.
    public static func load(url: URL, resourceSet: ResourceSet, metamodels: [URL] = []) async throws -> HenshinModule {
        try await HenshinMetamodel.register(in: resourceSet)
        let loaded = try await ModelIO.load(url: url, format: .xmi, resourceSet: resourceSet, metamodels: metamodels)
        return try await read(loaded.resource, resourceSet: resourceSet)
    }

    /// Loads a Henshin module from the bytes of a document.
    ///
    /// - Parameters:
    ///   - data: The bytes of the Henshin document.
    ///   - uri: The URI of the document, against which relative references are resolved.
    ///   - resourceSet: The resource set into which the document and its metamodels are
    ///     loaded.
    ///   - metamodels: Ecore documents to register before the document is read.
    /// - Returns: The module.
    /// - Throws: The errors of ``load(url:resourceSet:metamodels:)``.
    public static func load(data: Data, uri: String, resourceSet: ResourceSet, metamodels: [URL] = []) async throws
        -> HenshinModule
    {
        try await HenshinMetamodel.register(in: resourceSet)
        let loaded = try await ModelIO.load(data: data, uri: uri, format: .xmi, resourceSet: resourceSet, metamodels: metamodels)
        return try await read(loaded.resource, resourceSet: resourceSet)
    }

    /// Reads the Henshin module that a loaded resource holds.
    ///
    /// - Parameters:
    ///   - resource: A resource of Henshin metamodel instances.
    ///   - resourceSet: The resource set that resolves the references of the module.
    /// - Returns: The module.
    /// - Throws: ``HenshinError`` if the resource holds no module or a reference cannot be
    ///   resolved.
    public static func read(_ resource: Resource, resourceSet: ResourceSet) async throws -> HenshinModule {
        var reader = await ModuleReader(resource: resource, resourceSet: resourceSet)
        return try await reader.readModule()
    }
}

/// Turns the dynamic objects of a Henshin document into a ``HenshinModule``.
struct ModuleReader {
    /// Shorthand for the feature names of the Henshin metamodel.
    private typealias Feature = HenshinConstants.FeatureName
    /// Shorthand for the class names of the Henshin metamodel.
    private typealias Class = HenshinConstants.ClassName

    /// The resource of the document.
    let resource: Resource
    /// The resource set that resolves references to metamodels.
    let resourceSet: ResourceSet
    /// The dynamic objects of the document, by identity.
    private var objects: [EUUID: DynamicEObject] = [:]
    /// The root objects of the document.
    private let roots: [any EObject]
    /// The node identities assigned so far, by node object.
    private var nodeIDs: [EUUID: NodeID] = [:]
    /// The unit identities, by unit object.
    private var unitIDs: [EUUID: UnitID] = [:]
    /// The parameters, by parameter object.
    private var parameterReferences: [EUUID: ParameterReference] = [:]
    /// The metamodel elements resolved so far, by URI and fragment.
    private var resolved: [String: any EObject] = [:]

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - resource: The resource of the document.
    ///   - resourceSet: The resource set that resolves references to metamodels.
    init(resource: Resource, resourceSet: ResourceSet) async {
        self.resource = resource
        self.resourceSet = resourceSet
        for object in await resource.getAllObjects() {
            if let dynamic = object as? DynamicEObject { objects[dynamic.id] = dynamic }
        }
        roots = await resource.getRootObjects()
    }

    /// Reads the module of the document.
    ///
    /// - Returns: The module.
    /// - Throws: ``HenshinError`` if the document holds no module or a reference cannot be
    ///   resolved.
    mutating func readModule() async throws -> HenshinModule {
        guard let root = roots.compactMap({ $0 as? DynamicEObject }).first(where: { $0.eClass.name == Class.module }) else {
            throw HenshinError.noModule(resource.uri)
        }
        var unitObjects: [DynamicEObject] = []
        collectUnits(of: root, into: &unitObjects)
        for (index, unit) in unitObjects.enumerated() { unitIDs[unit.id] = UnitID(index) }
        for unit in unitObjects {
            for parameter in references(unit, Feature.parameters) {
                parameterReferences[parameter.id] = ParameterReference(
                    unit: unitIDs[unit.id] ?? UnitID(-1), name: string(parameter, Feature.name) ?? "")
            }
        }
        var units: [TransformationUnit] = []
        for unit in unitObjects { units.append(try await readUnit(unit)) }
        var imports: [String] = []
        for value in values(root, Feature.imports) {
            if let package = try await metamodelElement(value, for: "module") as? EPackage {
                imports.append(package.nsURI)
            } else if let proxy = value as? ResourceProxy {
                imports.append(proxy.uri)
            }
        }
        return HenshinModule(
            name: string(root, Feature.name), description: string(root, Feature.description), imports: imports, units: units)
    }

    /// Collects the units of a module and its nested modules in document order.
    private func collectUnits(of module: DynamicEObject, into units: inout [DynamicEObject]) {
        units += references(module, Feature.units)
        for subModule in references(module, Feature.subModules) { collectUnits(of: subModule, into: &units) }
    }

    // MARK: - Units

    /// Reads a unit.
    private mutating func readUnit(_ object: DynamicEObject) async throws -> TransformationUnit {
        let id = unitIDs[object.id] ?? UnitID(-1)
        let name = string(object, Feature.name) ?? ""
        let parameters = try await readParameters(object)
        var mappings: [ParameterMapping] = []
        for mapping in references(object, Feature.parameterMappings) {
            guard let source = reference(mapping, Feature.source).flatMap({ parameterReferences[$0.id] }),
                let target = reference(mapping, Feature.target).flatMap({ parameterReferences[$0.id] })
            else {
                throw HenshinError.unresolvedReference(element: "unit '\(name)'", reference: "a parameter mapping end")
            }
            mappings.append(ParameterMapping(source: source, target: target))
        }
        let kind: UnitKind
        switch object.eClass.name {
        case Class.rule:
            kind = .rule(try await readRule(object))
        case Class.independentUnit:
            kind = .independent(try subUnits(object, Feature.subUnits, unit: name))
        case Class.priorityUnit:
            kind = .priority(try subUnits(object, Feature.subUnits, unit: name))
        case Class.sequentialUnit:
            kind = .sequential(
                try subUnits(object, Feature.subUnits, unit: name),
                strict: bool(object, Feature.strict, HenshinConstants.Defaults.sequentialStrict),
                rollback: bool(object, Feature.rollback, HenshinConstants.Defaults.sequentialRollback))
        case Class.conditionalUnit:
            guard let condition = try subUnits(object, Feature.if, unit: name).first,
                let then = try subUnits(object, Feature.then, unit: name).first
            else { throw HenshinError.malformed("conditional unit '\(name)' lacks its if or then unit") }
            kind = .conditional(if: condition, then: then, else: try subUnits(object, Feature.else, unit: name).first)
        case Class.iteratedUnit:
            guard let subUnit = try subUnits(object, Feature.subUnit, unit: name).first else {
                throw HenshinError.malformed("iterated unit '\(name)' lacks its sub-unit")
            }
            kind = .iterated(
                subUnit, iterations: string(object, Feature.iterations) ?? "",
                strict: bool(object, Feature.strict, HenshinConstants.Defaults.iteratedStrict),
                rollback: bool(object, Feature.rollback, HenshinConstants.Defaults.iteratedRollback))
        case Class.loopUnit:
            guard let subUnit = try subUnits(object, Feature.subUnit, unit: name).first else {
                throw HenshinError.malformed("loop unit '\(name)' lacks its sub-unit")
            }
            kind = .loop(subUnit)
        default:
            throw HenshinError.malformed("unit '\(name)' is of the unknown kind '\(object.eClass.name)'")
        }
        return TransformationUnit(
            id: id, name: name, description: string(object, Feature.description), parameters: parameters,
            parameterMappings: mappings, isActivated: bool(object, Feature.activated, HenshinConstants.Defaults.activated),
            kind: kind)
    }

    /// The identities of the sub-units that a feature of a unit refers to.
    private func subUnits(_ object: DynamicEObject, _ feature: String, unit: String) throws -> [UnitID] {
        try ModelGraph.identifiers(object.eGet(feature)).map { id in
            guard let subUnit = unitIDs[id] else {
                throw HenshinError.unresolvedReference(element: "unit '\(unit)'", reference: "its '\(feature)' unit")
            }
            return subUnit
        }
    }

    /// Reads the parameters of a unit.
    private mutating func readParameters(_ object: DynamicEObject) async throws -> [UnitParameter] {
        var parameters: [UnitParameter] = []
        for parameter in references(object, Feature.parameters) {
            let kind = string(parameter, Feature.kind).flatMap(ParameterKind.init(rawValue:)) ?? .unknown
            var typeName: String?
            if let type = parameter.eGet(Feature.type) {
                typeName = (try? await metamodelElement(type, for: "parameter"))
                    .flatMap { ($0 as? EClass)?.name ?? ($0 as? EDataType)?.name ?? ($0 as? EEnum)?.name }
            }
            parameters.append(UnitParameter(name: string(parameter, Feature.name) ?? "", kind: kind, typeName: typeName))
        }
        return parameters
    }

    // MARK: - Rules

    /// Reads a rule together with its multi-rules.
    private mutating func readRule(_ object: DynamicEObject) async throws -> Rule {
        let name = string(object, Feature.name) ?? ""
        guard let lhsObject = reference(object, Feature.lhs), let rhsObject = reference(object, Feature.rhs) else {
            throw HenshinError.malformed("rule '\(name)' lacks a left-hand or right-hand side")
        }
        let lhs = try await readGraph(lhsObject, rule: name)
        let rhs = try await readGraph(rhsObject, rule: name)
        var multiRules: [Rule] = []
        for multiRule in references(object, Feature.multiRules) { multiRules.append(try await readRule(multiRule)) }
        let conditions = references(object, Feature.attributeConditions).map {
            AttributeCondition(name: string($0, Feature.name), conditionText: string($0, Feature.conditionText) ?? "")
        }
        return Rule(
            name: name, description: string(object, Feature.description), parameters: try await readParameters(object), lhs: lhs,
            rhs: rhs, mappings: try mappings(object, Feature.mappings, rule: name), attributeConditions: conditions,
            checkDangling: bool(object, Feature.checkDangling, HenshinConstants.Defaults.checkDangling),
            injectiveMatching: bool(object, Feature.injectiveMatching, HenshinConstants.Defaults.injectiveMatching),
            multiRules: multiRules, multiMappings: try mappings(object, Feature.multiMappings, rule: name),
            isActivated: bool(object, Feature.activated, HenshinConstants.Defaults.activated),
            javaImports: values(object, Feature.javaImports).compactMap { $0 as? String })
    }

    /// Reads the mappings that a feature of an object holds.
    private mutating func mappings(_ object: DynamicEObject, _ feature: String, rule: String) throws -> [NodeMapping] {
        try references(object, feature).map { mapping in
            guard let origin = ModelGraph.identifiers(mapping.eGet(Feature.origin)).first,
                let image = ModelGraph.identifiers(mapping.eGet(Feature.image)).first
            else { throw HenshinError.unresolvedReference(element: "rule '\(rule)'", reference: "a mapping end") }
            return NodeMapping(origin: nodeID(origin), image: nodeID(image))
        }
    }

    /// The node identity of a node object, assigned on first use.
    private mutating func nodeID(_ object: EUUID) -> NodeID {
        if let known = nodeIDs[object] { return known }
        let id = NodeID(nodeIDs.count)
        nodeIDs[object] = id
        return id
    }

    /// Reads a graph with its nodes, edges and application condition.
    private mutating func readGraph(_ object: DynamicEObject, rule: String) async throws -> RuleGraph {
        var nodes: [RuleNode] = []
        for node in references(object, Feature.nodes) {
            let name = string(node, Feature.name)
            let element = "node '\(name ?? "")' of rule '\(rule)'"
            guard let type = try await metamodelElement(node.eGet(Feature.type), for: element) as? EClass else {
                throw HenshinError.unresolvedReference(element: element, reference: "its type")
            }
            var attributes: [RuleAttribute] = []
            for attribute in references(node, Feature.attributes) {
                guard let feature = try await metamodelElement(attribute.eGet(Feature.type), for: element) as? EAttribute else {
                    throw HenshinError.unresolvedReference(element: element, reference: "the type of an attribute")
                }
                let isNull = bool(attribute, Feature.null, false)
                let value = isNull ? HenshinConstants.nullLiteral : (string(attribute, Feature.value) ?? HenshinConstants.nullLiteral)
                attributes.append(RuleAttribute(feature: feature, value: value))
            }
            nodes.append(RuleNode(id: nodeID(node.id), name: name, type: type, attributes: attributes))
        }
        var edges: [RuleEdge] = []
        for edge in references(object, Feature.edges) {
            let element = "an edge of rule '\(rule)'"
            guard let source = ModelGraph.identifiers(edge.eGet(Feature.source)).first,
                let target = ModelGraph.identifiers(edge.eGet(Feature.target)).first
            else { throw HenshinError.unresolvedReference(element: element, reference: "its source or target") }
            guard let type = try await metamodelElement(edge.eGet(Feature.type), for: element) as? EReference else {
                throw HenshinError.unresolvedReference(element: element, reference: "its type")
            }
            let index = string(edge, Feature.index).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            edges.append(RuleEdge(source: nodeID(source), target: nodeID(target), type: type, index: index))
        }
        let formula = try await reference(object, Feature.formula).asyncMap { try await readFormula($0, rule: rule) }
        return RuleGraph(name: string(object, Feature.name), nodes: nodes, edges: edges, formula: formula)
    }

    /// Reads an application condition.
    private mutating func readFormula(_ object: DynamicEObject, rule: String) async throws -> Formula {
        /// Reads the operand of the formula that a feature holds.
        func operand(_ feature: String) async throws -> Formula {
            guard let child = reference(object, feature) else {
                throw HenshinError.malformed("a formula of rule '\(rule)' lacks its '\(feature)' operand")
            }
            return try await readFormula(child, rule: rule)
        }
        switch object.eClass.name {
        case Class.true: return .true
        case Class.not: return .not(try await operand(Feature.child))
        case Class.and: return .and(try await operand(Feature.left), try await operand(Feature.right))
        case Class.or: return .or(try await operand(Feature.left), try await operand(Feature.right))
        case Class.xor: return .xor(try await operand(Feature.left), try await operand(Feature.right))
        case Class.nestedCondition:
            guard let conclusion = reference(object, Feature.conclusion) else {
                throw HenshinError.malformed("a nested condition of rule '\(rule)' lacks its conclusion")
            }
            let graph = try await readGraph(conclusion, rule: rule)
            return .condition(NestedCondition(conclusion: graph, mappings: try mappings(object, Feature.mappings, rule: rule)))
        default:
            throw HenshinError.malformed("rule '\(rule)' has a formula of the unknown kind '\(object.eClass.name)'")
        }
    }

    // MARK: - Metamodel references

    /// Resolves a reference from the document to an element of a metamodel.
    ///
    /// - Parameters:
    ///   - value: The stored reference: an identity within the resource set or a proxy.
    ///   - element: A description of the referring element, for errors.
    /// - Returns: The element, or `nil` if there is no reference.
    /// - Throws: ``HenshinError/unresolvedReference(element:reference:)`` if the reference
    ///   cannot be resolved.
    private mutating func metamodelElement(_ value: (any EcoreValue)?, for element: String) async throws -> (any EObject)? {
        guard let value else { return nil }
        if let id = value as? EUUID {
            if let found = await resource.resolve(id), !(found is DynamicEObject) { return found }
            if let (found, holder) = await resourceSet.resolve(id) {
                guard let dynamic = found as? DynamicEObject else { return found }
                if let native = await nativeElement(for: dynamic, in: holder) { return native }
            }
            throw HenshinError.unresolvedReference(element: element, reference: id.uuidString)
        }
        guard let proxy = value as? ResourceProxy else { return nil }
        let key = "\(proxy.uri)\(HenshinConstants.fragmentMarker)\(proxy.fragment)"
        if let known = resolved[key] { return known }
        let packages = await rootPackages(of: proxy.uri)
        guard let found = Self.navigate(packages, fragment: proxy.fragment) else {
            throw HenshinError.unresolvedReference(element: element, reference: key)
        }
        resolved[key] = found
        return found
    }

    /// Finds the native counterpart of a metamodel element that was loaded as a dynamic
    /// object.
    ///
    /// An element of a metamodel loaded as dynamic objects is found by the names on its
    /// containment path below its root package, in the native packages registered under
    /// that package's namespace URI. A reference into the Ecore metamodel that names a
    /// feature, such as `ENamedElement/name`, is read by the XMI loader as a stand-in object
    /// without container whose name is that path; it is looked up in the native Ecore
    /// metamodel.
    private func nativeElement(for element: DynamicEObject, in holder: Resource) async -> (any EObject)? {
        let separator = String(HenshinConstants.fragmentSeparator)
        var names: [String] = []
        var current: any EObject = element
        while let container = await holder.eContainer(of: current) {
            guard let name = (current as? DynamicEObject)?.eGet(Feature.name) as? String else { return nil }
            names.insert(name, at: 0)
            current = container
        }
        guard let root = current as? DynamicEObject else { return nil }
        if let nsURI = root.eGet(HenshinConstants.nsURIFeature) as? String {
            return Self.navigate(await rootPackages(of: nsURI), fragment: separator + separator + names.joined(separator: separator))
        }
        guard names.isEmpty, let path = root.eGet(Feature.name) as? String, path.contains(HenshinConstants.fragmentSeparator) else {
            return nil
        }
        return Self.navigate([EcorePackage.instance], fragment: separator + separator + path)
    }

    /// Finds the root packages of a metamodel document or registered namespace.
    ///
    /// The Ecore metamodel itself is known by its namespace URI, so that rules over Ecore
    /// models can refer to its classes and features.
    private func rootPackages(of uri: String) async -> [EPackage] {
        if uri == EcorePackage.nsURI { return [EcorePackage.instance] }
        if let loaded = await resourceSet.getResource(uri: uri) {
            let packages = await loaded.getRootObjects().compactMap { $0 as? EPackage }
            if !packages.isEmpty { return packages }
        }
        if let registered = await resourceSet.getMetamodel(uri: uri) { return [registered] }
        guard let resource = try? await resourceSet.loadEcoreResource(uri: uri) else { return [] }
        return await resource.getRootObjects().compactMap { $0 as? EPackage }
    }

    /// Follows a fragment from the root packages of a metamodel document.
    ///
    /// A name-based fragment such as `//Bank/clients` starts at the first root package; a
    /// positional fragment such as `/2/Class` starts at the root package of that position.
    /// The remaining segments name subpackages, classifiers, features and literals.
    ///
    /// - Parameters:
    ///   - packages: The root packages of the document, in order.
    ///   - fragment: The fragment.
    /// - Returns: The element, or `nil` if the fragment does not lead to one.
    static func navigate(_ packages: [EPackage], fragment: String) -> (any EObject)? {
        let separator = String(HenshinConstants.fragmentSeparator)
        var path = Substring(fragment)
        var root = packages.first
        if !path.hasPrefix(separator + separator), path.hasPrefix(separator) {
            let rest = path.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            if let index = Int(digits) {
                guard packages.indices.contains(index) else { return nil }
                root = packages[index]
                path = rest.dropFirst(digits.count)
            }
        }
        guard let root else { return nil }
        let segments = path.split(separator: HenshinConstants.fragmentSeparator).map(String.init)
        var current: any EObject = root
        for segment in segments {
            if let package = current as? EPackage {
                if let classifier = package.getClassifier(segment) as? any EObject {
                    current = classifier
                } else if let subpackage = package.getSubpackage(segment) {
                    current = subpackage
                } else {
                    return nil
                }
            } else if let eClass = current as? EClass, let feature = eClass.getStructuralFeature(name: segment) as? any EObject {
                current = feature
            } else if let eEnum = current as? EEnum, let literal = eEnum.getLiteral(name: segment) {
                current = literal
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: - Feature access

    /// The objects of the document that a reference of an object refers to.
    private func references(_ object: DynamicEObject, _ feature: String) -> [DynamicEObject] {
        ModelGraph.identifiers(object.eGet(feature)).compactMap { objects[$0] }
    }

    /// The object of the document that a single-valued reference refers to.
    private func reference(_ object: DynamicEObject, _ feature: String) -> DynamicEObject? {
        references(object, feature).first
    }

    /// The values that a many-valued feature holds, each on its own.
    private func values(_ object: DynamicEObject, _ feature: String) -> [any EcoreValue] {
        guard let value = object.eGet(feature) else { return [] }
        if let array = value as? EcoreValueArray { return array.values }
        if let ids = value as? [EUUID] { return ids }
        if let proxies = value as? [ResourceProxy] { return proxies }
        if let list = value as? [any EcoreValue] { return list }
        return [value]
    }

    /// The text of an attribute of an object.
    private func string(_ object: DynamicEObject, _ feature: String) -> String? {
        object.eGet(feature) as? String
    }

    /// The truth value of an attribute of an object.
    private func bool(_ object: DynamicEObject, _ feature: String, _ defaultValue: Bool) -> Bool {
        switch object.eGet(feature) {
        case let flag as Bool: return flag
        case let text as String: return Bool(text) ?? defaultValue
        default: return defaultValue
        }
    }
}

extension Optional {
    /// Transforms the wrapped value with an asynchronous closure.
    ///
    /// - Parameter transform: The transformation.
    /// - Returns: The transformed value, or `nil` if there is no value.
    /// - Throws: The error of the transformation.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
