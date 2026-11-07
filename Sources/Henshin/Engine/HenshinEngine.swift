//
//  HenshinEngine.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// Applies Henshin rules and units to models held in resources.
///
/// The engine follows the semantics of Henshin's interpreter, which rests on algebraic
/// graph transformation with the double-pushout approach: a rule is applied at a match of
/// its left-hand side that satisfies its application conditions, and, when the dangling
/// condition is checked, only if deleting objects leaves no reference dangling. Units
/// combine rules into sequences, choices, conditionals and loops.
///
/// The engine is a value: it holds only its options, and every call works on the resource
/// it is given. While a call runs, it expects to be the only writer of that resource.
///
/// ## Example
///
/// ```swift
/// let resourceSet = ResourceSet()
/// let module = try await HenshinModuleLoader.load(url: rulesURL, resourceSet: resourceSet)
/// let model = try await ModelIO.load(url: modelURL, resourceSet: resourceSet).resource
/// let engine = HenshinEngine()
/// let result = try await engine.apply(unitNamed: "createAccount", of: module, to: model,
///                                     parameters: ["client": "Alice", "accountId": 4])
/// print(result.succeeded, result.appliedRules.map(\.ruleName))
/// ```
public struct HenshinEngine: Sendable {
    /// The options of the engine.
    public var options: EngineOptions

    /// Creates an engine.
    ///
    /// - Parameter options: The options of the engine (default options).
    public init(options: EngineOptions = EngineOptions()) {
        self.options = options
    }

    /// Applies a unit of a module to a resource.
    ///
    /// - Parameters:
    ///   - name: The name of the unit.
    ///   - module: The module that holds the unit.
    ///   - resource: The resource whose model the unit transforms.
    ///   - parameters: The values of the unit's parameters; objects may be given as their
    ///     identities or as themselves.
    /// - Returns: The outcome of the application.
    /// - Throws: ``HenshinError/unknownUnit(_:)`` if the module has no such unit, and the
    ///   errors of ``apply(unit:of:to:parameters:)``.
    public func apply(
        unitNamed name: String, of module: HenshinModule, to resource: Resource, parameters: ParameterValues = [:]
    ) async throws -> UnitApplication {
        guard let unit = module.unit(named: name) else { throw HenshinError.unknownUnit(name) }
        return try await apply(unit: unit.id, of: module, to: resource, parameters: parameters)
    }

    /// Applies a unit of a module to a resource.
    ///
    /// - Parameters:
    ///   - unit: The identity of the unit.
    ///   - module: The module that holds the unit.
    ///   - resource: The resource whose model the unit transforms.
    ///   - parameters: The values of the unit's parameters; objects may be given as their
    ///     identities or as themselves.
    /// - Returns: The outcome of the application.
    /// - Throws: ``HenshinError`` if a parameter is missing or not accepted, a value does
    ///   not suit the declared data type of its parameter, a rule is malformed, an expression cannot be evaluated or the model cannot be changed, and
    ///   `CancellationError` if the task is cancelled. Unless
    ///   ``EngineOptions/restoresOnError`` is turned off, the resource is then as it was
    ///   before the call.
    public func apply(
        unit: UnitID, of module: HenshinModule, to resource: Resource, parameters: ParameterValues = [:]
    ) async throws -> UnitApplication {
        guard let transformationUnit = module.unit(unit) else { throw HenshinError.unknownUnit(unit.description) }
        for name in parameters.keys {
            guard let parameter = transformationUnit.parameter(named: name), parameter.kind.acceptsInput else {
                throw HenshinError.invalidParameter(unit: transformationUnit.name, parameter: name)
            }
        }
        let given = try ParameterTypeCheck.checked(parameters, against: transformationUnit.parameters, of: transformationUnit.name)
        var session = await ApplicationSession(module: module, resource: resource, options: options)
        let start = options.restoresOnError ? await session.checkpoint() : nil
        do {
            let outcome = try await session.execute(unit, ParameterBindings(given))
            return UnitApplication(
                unitName: transformationUnit.name, succeeded: outcome.succeeded,
                parameters: outcome.result.parameterValues.filter {
                    transformationUnit.parameter(named: $0.key)?.kind.isVisibleToCaller ?? true
                },
                appliedRules: session.applied, diagnostics: session.diagnostics, statistics: session.statistics)
        } catch {
            if let start { await session.restore(start) }
            throw error
        }
    }

    /// Applies a rule to a resource.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - resource: The resource whose model the rule transforms.
    ///   - parameters: The values of the rule's parameters.
    /// - Returns: The outcome of the application.
    /// - Throws: The errors of ``apply(unit:of:to:parameters:)``.
    public func apply(_ rule: Rule, to resource: Resource, parameters: ParameterValues = [:]) async throws -> UnitApplication {
        try await apply(unit: UnitID(0), of: HenshinModule(rules: [rule]), to: resource, parameters: parameters)
    }

    /// Finds the matches of a rule in a resource without changing it.
    ///
    /// Each match satisfies the application conditions and, if the rule checks it, the
    /// dangling condition, and carries the matches of the rule's multi-rules.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - resource: The resource to search.
    ///   - parameters: Values that fix parameters, and with them nodes and attributes.
    ///   - limit: The largest number of matches to return, or `nil` for all.
    /// - Returns: The matches, in the order in which they are found.
    /// - Throws: ``HenshinError`` if a value does not suit the declared data type of its
    ///   parameter, the rule is malformed or an expression cannot be evaluated.
    public func findMatches(
        of rule: Rule, in resource: Resource, parameters: ParameterValues = [:], limit: Int? = nil
    ) async throws -> [Match] {
        let given = try ParameterTypeCheck.checked(parameters, against: rule.parameters, of: rule.name)
        var session = await ApplicationSession(module: HenshinModule(rules: [rule]), resource: resource, options: options)
        let compiled = try session.compile(rule, unit: nil)
        return try await session.findMatches(compiled, parameters: ParameterBindings(given), limit: limit)
            .map { $0.publicMatch(of: compiled) }
    }
}
