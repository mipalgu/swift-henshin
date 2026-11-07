//
//  StatePredicate.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import AQL
import ECore
import EMFBase
import Henshin

/// A property of a single state.
public indirect enum StatePredicate: Sendable, CustomStringConvertible {
    /// Holds if a rule's left-hand side, with its application conditions, has a match in the
    /// state's model: a pattern given as a rule.
    case pattern(Rule, parameters: ParameterValues = [:])
    /// Holds if an expression of the Acceleo Query Language evaluates to `true`, with `self`
    /// bound to the first root object of the state's model.
    case aql(String)
    /// Holds if a function of the state's model returns `true`.
    case custom(name: String, @Sendable (ResourceSnapshot) -> Bool)
    /// Holds if the state cannot be left: no rule or unit applies.
    case deadlock
    /// Holds if the inner predicate does not.
    case not(StatePredicate)
    /// Holds if both predicates do.
    case and(StatePredicate, StatePredicate)
    /// Holds if either predicate does.
    case or(StatePredicate, StatePredicate)

    /// A description such as `pattern twoCritical` or `not aql(self.count > 0)`.
    public var description: String {
        switch self {
        case .pattern(let rule, _): return "pattern \(rule.name)"
        case .aql(let expression): return "aql(\(expression))"
        case .custom(let name, _): return name
        case .deadlock: return "deadlock"
        case .not(let inner): return "not \(inner)"
        case .and(let lhs, let rhs): return "(\(lhs) and \(rhs))"
        case .or(let lhs, let rhs): return "(\(lhs) or \(rhs))"
        }
    }

    /// The predicate that holds where no match of a pattern exists: a forbidden pattern.
    ///
    /// - Parameters:
    ///   - rule: The pattern, given as a rule.
    ///   - parameters: Values that fix parameters of the pattern.
    /// - Returns: The predicate.
    public static func forbidden(_ rule: Rule, parameters: ParameterValues = [:]) -> StatePredicate {
        .not(.pattern(rule, parameters: parameters))
    }
}

/// Evaluates expressions of the Acceleo Query Language on state models.
///
/// The evaluator owns a resource into which it restores each model. Every evaluation uses an
/// execution engine and context of its own, registered with that resource, so that
/// navigation resolves references and whole-model services such as `allInstances` see the
/// model, and nothing cached for one state is used for another.
@MainActor
final class AQLStateEvaluator {
    /// The resource that holds the model being evaluated.
    private let resource: Resource

    /// The parsed expressions, by text.
    private var parsed: [String: any AQLExpression] = [:]

    /// Creates an evaluator.
    ///
    /// - Parameter resourceSet: The resource set whose metamodels the expressions refer to,
    ///   if any.
    init(resourceSet: ResourceSet?) async {
        resource = Resource(uri: "aql://state")
        await resource.setResourceSet(resourceSet)
    }

    /// Evaluates a Boolean expression on a model.
    ///
    /// - Parameters:
    ///   - expression: The expression.
    ///   - model: The model; `self` is bound to its first root object.
    /// - Returns: Whether the expression evaluates to `true`.
    /// - Throws: ``StateSpaceError/invalidProperty(_:)`` if the expression cannot be parsed
    ///   or evaluated, or does not yield a truth value.
    func holds(_ expression: String, on model: ResourceSnapshot) async throws -> Bool {
        let query: any AQLExpression
        if let known = parsed[expression] {
            query = known
        } else {
            let result = AQLParser().parse(expression)
            guard let parsedQuery = result.expression, !result.diagnostics.contains(where: { $0.severity == .error }) else {
                throw StateSpaceError.invalidProperty(result.diagnostics.map(\.message).joined(separator: "; "))
            }
            parsed[expression] = parsedQuery
            query = parsedQuery
        }
        await resource.restore(model)
        let engine = ECoreExecutionEngine(models: [Self.modelAlias: ResourceModelWrapper(resource: resource)])
        let context = AQLExecutionContext(executionEngine: engine, options: .standard)
        context.addResource(resource)
        context.setVariable(Self.selfVariable, value: model.roots.first as? DynamicEObject)
        let value: (any EcoreValue)?
        do {
            value = try await query.evaluate(in: context)
        } catch {
            throw StateSpaceError.invalidProperty("\(expression): \(error)")
        }
        guard let truth = value as? Bool else {
            throw StateSpaceError.invalidProperty("\(expression) does not yield a truth value")
        }
        return truth
    }

    /// The alias under which the state's model is registered with the execution engine.
    static let modelAlias = "state"

    /// The variable bound to the first root object of the model.
    static let selfVariable = "self"
}
