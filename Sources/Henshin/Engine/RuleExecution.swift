//
//  RuleExecution.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// An elementary change to a model that a rule application makes.
enum ModelOperation: Sendable {
    /// Removes a reference instance.
    case removeEdge(source: EUUID, reference: String, target: EUUID)
    /// Deletes an object together with its contents and the references to them.
    case delete(EUUID)
    /// Adds a new object to the resource.
    case create(DynamicEObject)
    /// Adds a reference instance.
    case addEdge(source: EUUID, reference: String, target: EUUID)
    /// Sets an attribute value.
    case setAttribute(object: EUUID, attribute: String, value: SendableValue)
}

/// The outcome of performing model operations on a resource.
struct PerformedOperations: Sendable {
    /// The changes made, in order.
    let changes: [ResourceChange]
    /// The new state of every object that the changes touched; `nil` for deleted objects.
    let objects: [(id: EUUID, object: DynamicEObject?)]
}

extension Resource {
    /// Performs model operations, all or nothing.
    ///
    /// Opposite references and containment are maintained by the resource's editing
    /// operations. If an operation fails, the resource is restored to its state before the
    /// first operation.
    ///
    /// - Parameter operations: The operations, in order.
    /// - Returns: The changes made and the new state of the objects they touched.
    /// - Throws: The error of the operation that failed.
    func perform(_ operations: [ModelOperation]) async throws -> PerformedOperations {
        let before = snapshot()
        var changes: [ResourceChange] = []
        do {
            for operation in operations {
                switch operation {
                case .removeEdge(let source, let reference, let target):
                    guard let object = resolve(source) as? DynamicEObject,
                        let feature = object.eClass.getEReference(name: reference)
                    else { continue }
                    if feature.isMany {
                        if let removed = try await removeValue(objectId: source, feature: reference, value: target) {
                            changes += removed.changes
                        }
                    } else if ModelGraph.identifiers(object.eGet(feature)).first == target {
                        changes += try await eSetWithChanges(objectId: source, feature: reference, value: nil)
                    }
                case .delete(let id):
                    changes += await delete([id])
                case .create(let object):
                    changes += eCreate(object)
                case .addEdge(let source, let reference, let target):
                    guard let object = resolve(source) as? DynamicEObject,
                        let feature = object.eClass.getEReference(name: reference)
                    else { throw HenshinError.malformed("class '\((resolve(source)?.eClass as? EClass)?.name ?? "")' has no reference '\(reference)'") }
                    let current = ModelGraph.identifiers(object.eGet(feature))
                    if feature.isMany {
                        if !current.contains(target) {
                            changes += try await eAdd(objectId: source, feature: reference, value: target)
                        }
                    } else if current.first != target {
                        changes += try await eSetWithChanges(objectId: source, feature: reference, value: target)
                    }
                case .setAttribute(let object, let attribute, let value):
                    changes += try await eSetWithChanges(objectId: object, feature: attribute, value: value.value)
                }
            }
        } catch {
            restore(before)
            throw error
        }
        var touched: [EUUID] = []
        var seen = Set<EUUID>()
        for change in changes where seen.insert(change.objectID).inserted { touched.append(change.objectID) }
        for operation in operations {
            if case .create(let object) = operation, seen.insert(object.id).inserted { touched.append(object.id) }
        }
        return PerformedOperations(changes: changes, objects: touched.map { ($0, resolve($0) as? DynamicEObject) })
    }
}

/// The operations of an amalgamated rule application, grouped by kind.
struct ChangePlan: Sendable {
    /// The reference instances to remove.
    var removedEdges: [ModelOperation] = []
    /// The objects to delete.
    var deletedObjects: [EUUID] = []
    /// The objects to create.
    var createdObjects: [DynamicEObject] = []
    /// The reference instances to add.
    var addedEdges: [ModelOperation] = []
    /// The attribute values to set.
    var attributes: [ModelOperation] = []

    /// The operations in the order in which they are performed.
    ///
    /// References are removed first, so that deleting an object never takes a preserved
    /// child with it, and objects are created before references to them are added.
    var operations: [ModelOperation] {
        var result = removedEdges
        var seen = Set<EUUID>()
        for id in deletedObjects where seen.insert(id).inserted { result.append(.delete(id)) }
        result += createdObjects.map { .create($0) }
        result += addedEdges
        result += attributes
        return result
    }
}

extension ApplicationSession {
    /// Applies a rule at the first match that the parameters allow.
    ///
    /// - Parameters:
    ///   - rule: The compiled rule.
    ///   - parameters: The parameter values given.
    /// - Returns: The application, or `nil` if the rule has no match.
    /// - Throws: ``HenshinError`` if an expression cannot be evaluated or the model cannot
    ///   be changed.
    mutating func applyRule(_ rule: CompiledRule, parameters: ParameterBindings) async throws -> RuleApplication? {
        guard let match = try await findMatches(rule, parameters: parameters, limit: 1).first else { return nil }
        return try await apply(rule, at: match)
    }

    /// Applies a rule at a match.
    ///
    /// - Parameters:
    ///   - rule: The compiled rule.
    ///   - match: The match, with the matches of its multi-rules.
    /// - Returns: The application.
    /// - Throws: ``HenshinError`` if an expression cannot be evaluated or the model cannot
    ///   be changed.
    mutating func apply(_ rule: CompiledRule, at match: MatchInstance) async throws -> RuleApplication {
        var plan = ChangePlan()
        let result = try await planChanges(rule, match, kernel: [:], into: &plan)
        let performed: PerformedOperations
        do {
            performed = try await resource.perform(plan.operations)
        } catch let error as HenshinError {
            throw error
        } catch {
            throw HenshinError.changeFailed(rule: rule.rule.name, reason: "\(error)")
        }
        graph.update(performed.objects)
        var parameters = match.parameters
        for node in rule.rule.rhs.nodes {
            if let name = node.name, rule.rule.parameter(named: name) != nil, let object = result[node.id] {
                parameters.bind(name, object)
            }
        }
        let application = RuleApplication(
            ruleName: rule.rule.name, match: match.publicMatch(of: rule), resultNodes: result,
            parameters: parameters.parameterValues, createdObjects: plan.createdObjects.map(\.id),
            deletedObjects: performed.changes.filter { $0.kind == .delete }.map(\.objectID), changes: performed.changes)
        applied.append(application)
        return application
    }

    /// Plans the changes of a rule application and of its multi-rule applications.
    ///
    /// - Returns: The objects that the right-hand side nodes of the rule stand for.
    private mutating func planChanges(
        _ rule: CompiledRule, _ match: MatchInstance, kernel: [NodeID: EUUID], into plan: inout ChangePlan
    ) async throws -> [NodeID: EUUID] {
        var result: [NodeID: EUUID] = [:]
        for (rhs, lhs) in rule.preservedNodes { result[rhs] = match.binding[rule.lhs.nodes[lhs].id] }
        for (rhs, kernelNode) in rule.kernelImages { result[rhs] = kernel[kernelNode] }
        for node in rule.createdNodes {
            guard !node.type.isAbstract, !node.type.isInterface else {
                throw HenshinError.changeFailed(rule: rule.rule.name, reason: "class '\(node.type.name)' is abstract")
            }
            let object = DynamicEObject(eClass: modelClass(like: node.type))
            result[node.id] = object.id
            plan.createdObjects.append(object)
        }
        for position in rule.deletedNodes {
            if let object = match.binding[rule.lhs.nodes[position].id] { plan.deletedObjects.append(object) }
        }
        for edge in rule.deletedEdges {
            guard let source = match.binding[rule.lhs.nodes[edge.source].id],
                let target = match.binding[rule.lhs.nodes[edge.target].id]
            else { continue }
            plan.removedEdges.append(.removeEdge(source: source, reference: edge.reference, target: target))
        }
        for edge in rule.createdEdges {
            guard let source = result[edge.source], let target = result[edge.target] else {
                throw HenshinError.changeFailed(rule: rule.rule.name, reason: "an end of the new '\(edge.reference)' reference is missing")
            }
            plan.addedEdges.append(.addEdge(source: source, reference: edge.reference, target: target))
        }
        for assignment in rule.assignments {
            guard let object = result[assignment.node] else { continue }
            let value = ValueSemantics.cast(try await evaluate(assignment.expression, match.parameters), to: assignment.feature)
            plan.attributes.append(.setAttribute(object: object, attribute: assignment.feature.name, value: SendableValue(value: value)))
        }
        for (index, multi) in rule.multiRules.enumerated() where index < match.multiMatches.count {
            for multiMatch in match.multiMatches[index] {
                _ = try await planChanges(multi.rule, multiMatch, kernel: result, into: &plan)
            }
        }
        return result
    }

    /// The class of the model that corresponds to a class of a rule.
    ///
    /// The model's own class of the same name is preferred, so that new objects belong to
    /// the same metamodel as the objects around them.
    private func modelClass(like type: EClass) -> EClass {
        if graph.classes[type.id] != nil { return type }
        return graph.classes.values.first { $0.name == type.name } ?? type
    }
}
