//
//  IndexedModel.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// A model indexed for matching, so that rules can be matched and applied to it again and
/// again without indexing it anew.
///
/// ``HenshinEngine/findMatches(of:in:parameters:limit:)`` and the engine's `apply` methods
/// index the model of their resource on every call. An indexed model indexes it once, when
/// it is created with ``HenshinEngine/index(_:)``, and keeps the index in step with the
/// changes that its own rule applications make, so that objects they create are matched
/// and objects they delete are not.
///
/// The indexed model, not the resource, is authoritative: ``model`` is the model that the
/// index describes, and ``apply(_:at:parameters:)`` first returns the resource to that
/// model before it changes it. Changes made to the resource in other ways are therefore
/// not seen by the index, and are replaced when a rule is next applied.
///
/// An indexed model is a value. A copy keeps the model and index of the original and
/// changes independently of it, which makes it cheap to apply a rule at each of several
/// matches of the same model. Copies share the resource, so rules should be applied to
/// one copy at a time.
///
/// ## Example
///
/// ```swift
/// let engine = HenshinEngine()
/// var indexed = await engine.index(resource)
/// var successors: [ResourceSnapshot] = []
/// for match in try await indexed.findMatches(of: rule) {
///     var step = indexed
///     if try await step.apply(rule, at: match).succeeded { successors.append(step.model) }
/// }
/// ```
public struct IndexedModel: Sendable {
    /// The resource that rule applications change.
    public let resource: Resource

    /// The model that the index describes.
    ///
    /// It is the model of the resource when the index was created, as changed by every rule
    /// application of this value since.
    public private(set) var model: ResourceSnapshot

    /// The index and the caches of matching and application.
    private var session: ApplicationSession

    /// Indexes the model of a resource.
    ///
    /// - Parameters:
    ///   - resource: The resource.
    ///   - options: The options of matching and application.
    init(resource: Resource, options: EngineOptions) async {
        let snapshot = await resource.snapshot()
        self.resource = resource
        model = snapshot
        session = ApplicationSession(module: HenshinModule(rules: []), resource: resource, objects: snapshot.objects, options: options)
    }

    /// Finds the matches of a rule in the indexed model.
    ///
    /// Each match satisfies the application conditions and, if the rule checks it, the
    /// dangling condition, and carries the matches of the rule's multi-rules, as with
    /// ``HenshinEngine/findMatches(of:in:parameters:limit:)``.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - parameters: Values that fix parameters, and with them nodes and attributes.
    ///   - limit: The largest number of matches to return, or `nil` for all.
    /// - Returns: The matches, in the order in which they are found.
    /// - Throws: ``HenshinError`` if a value does not suit the declared data type of its
    ///   parameter, the rule is malformed or an expression cannot be evaluated.
    public mutating func findMatches(of rule: Rule, parameters: ParameterValues = [:], limit: Int? = nil) async throws -> [Match] {
        let given = try ParameterTypeCheck.checked(parameters, against: rule.parameters, of: rule.name)
        let compiled = try session.compile(rule, unit: nil)
        session.random = ApplicationSession.generator(for: session.options)
        return try await session.findMatches(compiled, parameters: ParameterBindings(given), limit: limit)
            .map { $0.publicMatch(of: compiled) }
    }

    /// Applies a rule at a match in the indexed model.
    ///
    /// The nodes of the match stay fixed to their objects, and the rule is applied only if
    /// the match still holds in the indexed model: a match found before an earlier
    /// application that deleted or changed its objects is not applied. Nodes that the match
    /// leaves out are matched as usual, and the matches of multi-rules are found anew. The
    /// parameter values of the match are used together with the given values, which take
    /// precedence.
    ///
    /// The resource is first returned to ``model``. If the rule is applied, the resource
    /// and ``model`` then hold the changed model, and the index is brought up to date with
    /// the change; otherwise they stay as they were. As with
    /// ``HenshinEngine/apply(_:to:parameters:)``, a rule that is not activated succeeds
    /// without changing the model.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - match: A match of the rule, as found by ``findMatches(of:parameters:limit:)``.
    ///   - parameters: Values of the rule's parameters in addition to those of the match.
    /// - Returns: The outcome of the application, which succeeds if the match holds.
    /// - Throws: ``HenshinError`` if a value does not suit the declared data type of its
    ///   parameter, the rule is malformed, an expression cannot be evaluated or the model
    ///   cannot be changed, and `CancellationError` if the task is cancelled. The model is
    ///   then as it was before the call.
    public mutating func apply(_ rule: Rule, at match: Match, parameters: ParameterValues = [:]) async throws -> UnitApplication {
        try Task.checkCancellation()
        let given = try ParameterTypeCheck.checked(parameters, against: rule.parameters, of: rule.name)
        var bindings = ParameterBindings(match.parameters)
        for (name, value) in given { bindings.bind(name, value) }
        session.random = ApplicationSession.generator(for: session.options)
        session.statistics = MatchStatistics()
        session.applied = []
        var application: RuleApplication?
        if rule.isActivated {
            let compiled = try session.compile(rule, unit: nil)
            if let found = try await session.findMatches(compiled, parameters: bindings, fixing: match.nodes, limit: 1).first {
                await resource.restore(model)
                let applied = try await session.apply(compiled, at: found)
                model = await resource.snapshot()
                bindings = ParameterBindings(applied.parameters)
                application = applied
            }
        }
        session.applied = []
        return UnitApplication(
            unitName: rule.name, succeeded: !rule.isActivated || application != nil,
            parameters: bindings.parameterValues.filter { rule.parameter(named: $0.key)?.kind.isVisibleToCaller ?? true },
            appliedRules: application.map { [$0] } ?? [], diagnostics: session.diagnostics, statistics: session.statistics)
    }
}

extension HenshinEngine {
    /// Indexes the model of a resource for repeated matching and rule application.
    ///
    /// The returned value matches rules and applies them with the options of this engine,
    /// without indexing the model again for each call.
    ///
    /// - Parameter resource: The resource whose model is indexed, and which rule
    ///   applications change.
    /// - Returns: The indexed model.
    public func index(_ resource: Resource) async -> IndexedModel {
        await IndexedModel(resource: resource, options: options)
    }
}
