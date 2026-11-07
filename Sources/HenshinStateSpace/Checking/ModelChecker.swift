//
//  ModelChecker.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin

/// The outcome of checking a property on a state space.
public struct CheckResult: Sendable, CustomStringConvertible {
    /// A description of the property.
    public let property: String

    /// Whether the property holds on the explored states.
    public let holds: Bool

    /// The state that shows the outcome: a witness of reachability, or a counterexample to
    /// an invariant or to deadlock freedom; `nil` if there is none.
    public let state: Int?

    /// A shortest path of rule and unit applications from the initial state to ``state``.
    public let path: [StateTransition]

    /// Whether the outcome holds for the whole state space and not just its explored part.
    ///
    /// A witness or counterexample is always conclusive; the absence of one is conclusive
    /// only if the state space is complete.
    public let isConclusive: Bool

    /// Creates a result.
    ///
    /// - Parameters:
    ///   - property: A description of the property.
    ///   - holds: Whether the property holds.
    ///   - state: The witness or counterexample state, if any.
    ///   - path: A path to the state.
    ///   - isConclusive: Whether the outcome holds for the whole state space.
    public init(property: String, holds: Bool, state: Int?, path: [StateTransition], isConclusive: Bool) {
        self.property = property
        self.holds = holds
        self.state = state
        self.path = path
        self.isConclusive = isConclusive
    }

    /// A report of the outcome and the path, one step per line.
    public var description: String {
        var lines = ["\(property): \(holds ? "holds" : "does not hold")\(isConclusive ? "" : " (inconclusive: state space incomplete)")"]
        if let state {
            lines.append("  state \(state) after \(path.count) step(s)")
            lines += path.map { "    \($0.source) -> \($0.target): \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Checks properties on an explored state space.
///
/// Properties are reachability of a state that satisfies a predicate, invariants that every
/// state satisfies, and freedom from deadlocks. Predicates are patterns given as rules
/// (with their application conditions), expressions of the Acceleo Query Language, or
/// functions of the model (see ``StatePredicate``). Witnesses and counterexamples come with
/// a shortest path of rule applications, with matches, from the initial state.
public struct ModelChecker: Sendable {
    /// The state space.
    public let stateSpace: StateSpace

    /// The resource set whose metamodels AQL expressions refer to, if any.
    public let resourceSet: ResourceSet?

    /// The options of the engine that matches patterns.
    public var engineOptions: EngineOptions

    /// Creates a checker.
    ///
    /// - Parameters:
    ///   - stateSpace: The state space.
    ///   - resourceSet: The resource set of the models, for AQL expressions that name
    ///     metamodel types (optional).
    ///   - engineOptions: The options of the engine that matches patterns (default options).
    public init(stateSpace: StateSpace, resourceSet: ResourceSet? = nil, engineOptions: EngineOptions = EngineOptions()) {
        self.stateSpace = stateSpace
        self.resourceSet = resourceSet
        self.engineOptions = engineOptions
    }

    /// The states that satisfy a predicate, in order.
    ///
    /// - Parameter predicate: The predicate.
    /// - Returns: The numbers of the states.
    /// - Throws: ``StateSpaceError/invalidProperty(_:)`` for an expression that cannot be
    ///   evaluated, and the errors of `HenshinEngine` for patterns.
    public func states(satisfying predicate: StatePredicate) async throws -> [Int] {
        var evaluation = await Evaluation(checker: self)
        var result: [Int] = []
        for state in stateSpace.states where try await evaluation.holds(predicate, at: state.id) {
            result.append(state.id)
        }
        return result
    }

    /// Checks whether a state that satisfies a predicate is reachable.
    ///
    /// - Parameter predicate: The predicate of the target states.
    /// - Returns: The outcome, with a shortest path to a witness if there is one.
    /// - Throws: The errors of ``states(satisfying:)``.
    public func checkReachable(_ predicate: StatePredicate) async throws -> CheckResult {
        var evaluation = await Evaluation(checker: self)
        for state in stateSpace.states where try await evaluation.holds(predicate, at: state.id) {
            return CheckResult(
                property: "reachable \(predicate)", holds: true, state: state.id, path: stateSpace.path(to: state.id),
                isConclusive: true)
        }
        return CheckResult(
            property: "reachable \(predicate)", holds: false, state: nil, path: [], isConclusive: stateSpace.isComplete)
    }

    /// Checks whether every state satisfies a predicate.
    ///
    /// - Parameter predicate: The invariant.
    /// - Returns: The outcome, with a shortest path to a counterexample if there is one.
    /// - Throws: The errors of ``states(satisfying:)``.
    public func checkInvariant(_ predicate: StatePredicate) async throws -> CheckResult {
        var evaluation = await Evaluation(checker: self)
        for state in stateSpace.states where try await !evaluation.holds(predicate, at: state.id) {
            return CheckResult(
                property: "invariant \(predicate)", holds: false, state: state.id, path: stateSpace.path(to: state.id),
                isConclusive: true)
        }
        return CheckResult(
            property: "invariant \(predicate)", holds: true, state: nil, path: [], isConclusive: stateSpace.isComplete)
    }

    /// Checks that no explored state is a deadlock.
    ///
    /// - Returns: The outcome, with a shortest path to a deadlock if there is one.
    public func checkDeadlockFreedom() -> CheckResult {
        if let deadlock = stateSpace.deadlocks.first {
            return CheckResult(
                property: "deadlock freedom", holds: false, state: deadlock, path: stateSpace.path(to: deadlock),
                isConclusive: true)
        }
        return CheckResult(property: "deadlock freedom", holds: true, state: nil, path: [], isConclusive: stateSpace.isComplete)
    }

    /// The evaluation of predicates over the states, with the resources it needs.
    struct Evaluation {
        /// The checker.
        let checker: ModelChecker
        /// The resource into which models are restored for matching patterns.
        let resource: Resource
        /// The evaluator of AQL expressions, created when first needed.
        var aql: AQLStateEvaluator?

        /// Creates an evaluation.
        init(checker: ModelChecker) async {
            self.checker = checker
            resource = Resource(uri: "pattern://state")
            await resource.setResourceSet(checker.resourceSet)
        }

        /// Whether a predicate holds at a state.
        mutating func holds(_ predicate: StatePredicate, at state: Int) async throws -> Bool {
            let model = checker.stateSpace.states[state].model
            switch predicate {
            case .pattern(let rule, let parameters):
                await resource.restore(model)
                return try await !HenshinEngine(options: checker.engineOptions)
                    .findMatches(of: rule, in: resource, parameters: parameters, limit: 1).isEmpty
            case .aql(let expression):
                if aql == nil { aql = await AQLStateEvaluator(resourceSet: checker.resourceSet) }
                return try await aql!.holds(expression, on: model)
            case .custom(_, let function):
                return function(model)
            case .deadlock:
                return !checker.stateSpace.states[state].isOpen && checker.stateSpace.outgoing(state).isEmpty
            case .not(let inner):
                return try await !holds(inner, at: state)
            case .and(let lhs, let rhs):
                guard try await holds(lhs, at: state) else { return false }
                return try await holds(rhs, at: state)
            case .or(let lhs, let rhs):
                if try await holds(lhs, at: state) { return true }
                return try await holds(rhs, at: state)
            }
        }
    }
}
