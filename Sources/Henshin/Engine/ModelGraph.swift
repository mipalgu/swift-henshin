//
//  ModelGraph.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import OrderedCollections

/// A reference instance between two model objects.
struct EdgeKey: Hashable, Sendable {
    /// The referring object.
    let source: EUUID
    /// The name of the reference.
    let reference: String
    /// The referenced object.
    let target: EUUID
}

/// A reference that points at an object, seen from the object.
struct InverseEdge: Hashable, Sendable {
    /// The referring object.
    let source: EUUID
    /// The name of the reference.
    let reference: String
}

/// What the engine knows about a reference of a class.
struct ReferenceInfo: Sendable {
    /// The reference.
    let reference: EReference
    /// The name of the opposite reference, if the reference has one.
    let oppositeName: String?
    /// Whether the opposite reference is single-valued.
    let oppositeIsSingle: Bool
}

/// An indexed, value-typed view of the dynamic objects of a resource, used for matching.
///
/// The graph keeps the objects in the resource's order together with the indices that rule
/// matching needs: the objects of each class, the references that point at each object
/// and the set of all reference instances. It is brought up to date with the objects that
/// each rule application changes, so it never has to be rebuilt from the resource.
struct ModelGraph: Sendable {
    /// The dynamic objects, in the order of the resource.
    private(set) var objects: OrderedDictionary<EUUID, DynamicEObject> = [:]

    /// The objects of each class, by class identity, in the order of the resource.
    private var extents: [EUUID: OrderedSet<EUUID>] = [:]

    /// The classes of the objects, by class identity.
    private(set) var classes: OrderedDictionary<EUUID, EClass> = [:]

    /// The references that point at each object.
    private var inverse: [EUUID: [InverseEdge]] = [:]

    /// Every reference instance between objects of the graph.
    private var edges: Set<EdgeKey> = []

    /// The number of objects that are not dynamic objects and so take no part in matching.
    private(set) var foreignObjectCount = 0

    /// Creates an empty graph.
    init() {}

    /// Creates a graph of the given objects.
    ///
    /// - Parameter objects: The objects of a resource, in order.
    init(objects: [any EObject]) {
        for object in objects {
            guard let dynamic = object as? DynamicEObject else {
                foreignObjectCount += 1
                continue
            }
            self.objects[dynamic.id] = dynamic
        }
        for object in self.objects.values { index(object) }
    }

    /// The number of objects of the graph.
    var count: Int { objects.count }

    /// The object with an identity.
    ///
    /// - Parameter id: The identity of the object.
    /// - Returns: The object, or `nil` if the graph does not hold it.
    func object(_ id: EUUID) -> DynamicEObject? { objects[id] }

    /// Whether the graph holds an object.
    ///
    /// - Parameter id: The identity of the object.
    /// - Returns: `true` if the object belongs to the graph.
    func contains(_ id: EUUID) -> Bool { objects[id] != nil }

    /// The objects of a class, without those of its subclasses.
    ///
    /// - Parameter classID: The identity of the class.
    /// - Returns: The identities of the objects, in the order of the resource.
    func extent(ofClass classID: EUUID) -> OrderedSet<EUUID> { extents[classID] ?? [] }

    /// The objects whose class conforms to a type.
    ///
    /// - Parameters:
    ///   - type: The type.
    ///   - types: The type conformance cache.
    /// - Returns: The identities of the objects, in the order of the resource.
    func instances(of type: EClass, types: inout TypeCatalogue) -> [EUUID] {
        var result: [EUUID] = []
        for (classID, eClass) in classes where types.conforms(eClass, to: type) {
            result.append(contentsOf: extents[classID] ?? [])
        }
        if result.count > 1, classes.count > 1 {
            let order = Dictionary(uniqueKeysWithValues: result.map { ($0, objects.index(forKey: $0) ?? 0) })
            result.sort { order[$0, default: 0] < order[$1, default: 0] }
        }
        return result
    }

    /// The number of objects whose class conforms to a type.
    ///
    /// - Parameters:
    ///   - type: The type.
    ///   - types: The type conformance cache.
    /// - Returns: The number of objects.
    func instanceCount(of type: EClass, types: inout TypeCatalogue) -> Int {
        var total = 0
        for (classID, eClass) in classes where types.conforms(eClass, to: type) { total += extents[classID]?.count ?? 0 }
        return total
    }

    /// The objects that a reference of an object refers to, in order.
    ///
    /// - Parameters:
    ///   - id: The identity of the referring object.
    ///   - reference: The name of the reference.
    /// - Returns: The identities of the referenced objects that belong to the graph.
    func targets(of id: EUUID, _ reference: String) -> [EUUID] {
        guard let object = objects[id] else { return [] }
        return Self.identifiers(object.eGet(reference)).filter { objects[$0] != nil }
    }

    /// The objects that refer to an object through a reference.
    ///
    /// - Parameters:
    ///   - id: The identity of the referenced object.
    ///   - reference: The name of the reference.
    /// - Returns: The identities of the referring objects.
    func sources(of id: EUUID, _ reference: String) -> [EUUID] {
        (inverse[id] ?? []).filter { $0.reference == reference }.map(\.source)
    }

    /// The references that point at an object.
    ///
    /// - Parameter id: The identity of the object.
    /// - Returns: The referring objects and references.
    func incoming(_ id: EUUID) -> [InverseEdge] { inverse[id] ?? [] }

    /// Whether a reference instance exists.
    ///
    /// - Parameters:
    ///   - source: The referring object.
    ///   - reference: The name of the reference.
    ///   - target: The referenced object.
    /// - Returns: `true` if the source refers to the target through the reference.
    func hasEdge(_ source: EUUID, _ reference: String, _ target: EUUID) -> Bool {
        edges.contains(EdgeKey(source: source, reference: reference, target: target))
    }

    /// The reference instances that start at an object, for every reference of its class.
    ///
    /// - Parameter id: The identity of the object.
    /// - Returns: The reference instances to objects of the graph.
    func outgoing(_ id: EUUID) -> [EdgeKey] {
        guard let object = objects[id] else { return [] }
        var result: [EdgeKey] = []
        for reference in object.eClass.eAllReferences where !reference.derived {
            for target in Self.identifiers(object.eGet(reference)) where objects[target] != nil {
                result.append(EdgeKey(source: id, reference: reference.name, target: target))
            }
        }
        return result
    }

    /// The value of an attribute of an object.
    ///
    /// - Parameters:
    ///   - id: The identity of the object.
    ///   - feature: The attribute.
    /// - Returns: The value, the attribute's default if it is unset, or `nil`.
    func attribute(of id: EUUID, _ feature: EAttribute) -> (any EcoreValue)? {
        guard let object = objects[id] else { return nil }
        if let own = object.eClass.getEAttribute(name: feature.name) {
            return object.eGetWithDefault(own)
        }
        return object.eGet(feature.name)
    }

    // MARK: - Updates

    /// Brings the graph up to date with objects that a rule application changed.
    ///
    /// - Parameter changes: The new state of each changed object, or `nil` for an object
    ///   that no longer exists.
    mutating func update(_ changes: [(id: EUUID, object: DynamicEObject?)]) {
        for change in changes {
            if let old = objects[change.id] { unindex(old) }
            if let object = change.object {
                objects[change.id] = object
            } else {
                objects.removeValue(forKey: change.id)
            }
        }
        for change in changes {
            if let object = change.object { index(object) }
        }
    }

    /// Adds the index entries of an object.
    private mutating func index(_ object: DynamicEObject) {
        let classID = object.eClass.id
        if classes[classID] == nil { classes[classID] = object.eClass }
        extents[classID, default: []].append(object.id)
        for reference in object.eClass.eAllReferences where !reference.derived {
            for target in Self.identifiers(object.eGet(reference)) {
                inverse[target, default: []].append(InverseEdge(source: object.id, reference: reference.name))
                edges.insert(EdgeKey(source: object.id, reference: reference.name, target: target))
            }
        }
    }

    /// Removes the index entries of an object.
    private mutating func unindex(_ object: DynamicEObject) {
        extents[object.eClass.id]?.remove(object.id)
        for reference in object.eClass.eAllReferences where !reference.derived {
            for target in Self.identifiers(object.eGet(reference)) {
                if var sources = inverse[target],
                    let position = sources.firstIndex(of: InverseEdge(source: object.id, reference: reference.name))
                {
                    sources.remove(at: position)
                    inverse[target] = sources.isEmpty ? nil : sources
                }
                edges.remove(EdgeKey(source: object.id, reference: reference.name, target: target))
            }
        }
    }

    /// The identities that a reference value holds.
    ///
    /// - Parameter value: The value of a reference.
    /// - Returns: The identities, in order; a single identity is a list of one.
    static func identifiers(_ value: (any EcoreValue)?) -> [EUUID] {
        guard let value else { return [] }
        if let id = value as? EUUID { return [id] }
        if let ids = value as? [EUUID] { return ids }
        if let array = value as? EcoreValueArray { return array.values.flatMap { identifiers($0) } }
        if let object = value as? DynamicEObject { return [object.id] }
        return []
    }
}

/// Decides and remembers whether classes conform to types.
///
/// A class conforms to a type if it is the type or a subclass of it. Classes are compared
/// by identity and, failing that, by name, so that a rule whose metamodel was loaded
/// separately from the model still matches the model's objects.
struct TypeCatalogue: Sendable {
    /// The decisions made so far, by class and type identity.
    private var conformance: [Pair: Bool] = [:]

    /// The references of each class, by class identity and reference name.
    private var references: [EUUID: [String: ReferenceInfo]] = [:]

    /// A pair of class identities.
    private struct Pair: Hashable, Sendable {
        /// The class of an object.
        let subject: EUUID
        /// The type it is checked against.
        let type: EUUID
    }

    /// Creates an empty catalogue.
    init() {}

    /// Whether a class conforms to a type.
    ///
    /// - Parameters:
    ///   - eClass: The class of an object.
    ///   - type: The type of a node.
    /// - Returns: `true` if the class is the type or one of its subclasses.
    mutating func conforms(_ eClass: EClass, to type: EClass) -> Bool {
        if eClass.id == type.id { return true }
        let key = Pair(subject: eClass.id, type: type.id)
        if let known = conformance[key] { return known }
        let result = Self.same(eClass, type) || eClass.eAllSuperTypes.contains { Self.same($0, type) }
        conformance[key] = result
        return result
    }

    /// Whether two classes are the same, by identity or name.
    static func same(_ lhs: EClass, _ rhs: EClass) -> Bool {
        lhs.id == rhs.id || lhs.name == rhs.name
    }

    /// What is known about a reference of a class.
    ///
    /// - Parameters:
    ///   - name: The name of the reference.
    ///   - eClass: The class of the referring object.
    /// - Returns: The reference information, or `nil` if the class has no such reference.
    mutating func reference(_ name: String, of eClass: EClass) -> ReferenceInfo? {
        if let known = references[eClass.id]?[name] { return known }
        guard let reference = eClass.getEReference(name: name) else { return nil }
        var oppositeName: String?
        var oppositeIsSingle = false
        if let oppositeID = reference.opposite, let targetClass = reference.eType as? EClass,
            let opposite = targetClass.eAllReferences.first(where: { $0.id == oppositeID })
        {
            oppositeName = opposite.name
            oppositeIsSingle = !opposite.isMany
        }
        let info = ReferenceInfo(reference: reference, oppositeName: oppositeName, oppositeIsSingle: oppositeIsSingle)
        references[eClass.id, default: [:]][name] = info
        return info
    }
}
