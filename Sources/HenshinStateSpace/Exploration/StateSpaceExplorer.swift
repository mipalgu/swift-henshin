//
//  StateSpaceExplorer.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation
import Henshin

/// The errors of a state-space exploration.
public enum StateSpaceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The module has no rule or unit of the name.
    case unknownUnit(String)
    /// A rule or unit could not be applied because a parameter has no value; give values
    /// with ``ExplorationOptions/parameterValues``.
    case unboundParameter(unit: String, parameter: String)
    /// An expression of a property could not be parsed or evaluated.
    case invalidProperty(String)

    /// A description of the error.
    public var description: String {
        switch self {
        case .unknownUnit(let name): return "The module has no rule or unit named \(name)"
        case .unboundParameter(let unit, let parameter):
            return "\(unit) needs a value for its parameter \(parameter); give values for it"
        case .invalidProperty(let reason): return "The property cannot be evaluated: \(reason)"
        }
    }
}

/// Explores the states that rules and units reach from a model.
///
/// Starting from a model, the explorer applies every active rule at every match, and every
/// chosen unit, to every state it reaches, breadth first, and records each resulting model
/// as a state and each application as a transition. States are identified up to
/// isomorphism, with certificates computed by colour refinement and confirmed by an exact
/// isomorphism search (see ``StateEquivalence``), following the approach of GROOVE
/// (Rensink, AGTIVE 2003) and Henshin's state-space tools. Limits on the number of states,
/// the depth and the size of models bound the exploration; states cut off by a limit stay
/// open.
///
/// A unit is applied as one atomic step, with the deterministic semantics of the engine, so
/// it contributes at most one successor per parameter assignment.
///
/// ## Example
///
/// ```swift
/// let explorer = try StateSpaceExplorer(module: module, rules: ["request", "enter", "leave", "pass"])
/// let space = try await explorer.explore(from: model)
/// print(space)  // 12 states, 32 transitions, complete
/// ```
public struct StateSpaceExplorer: Sendable {
    /// The module that holds the units.
    public let module: HenshinModule

    /// The rules that the explorer applies at every match.
    public let rules: [Rule]

    /// The names of the units that the explorer applies as atomic steps.
    public let units: [String]

    /// The options of the exploration.
    public var options: ExplorationOptions

    /// Creates an explorer for rules and units of a module.
    ///
    /// - Parameters:
    ///   - module: The module.
    ///   - rules: The names of the rules to apply at every match, or `nil` for every active
    ///     rule of the module.
    ///   - units: The names of units to apply as atomic steps.
    ///   - options: The options of the exploration (default options).
    /// - Throws: ``StateSpaceError/unknownUnit(_:)`` if a name is not that of a rule or unit
    ///   of the module.
    public init(module: HenshinModule, rules: [String]? = nil, units: [String] = [], options: ExplorationOptions = ExplorationOptions())
        throws
    {
        self.module = module
        if let rules {
            self.rules = try rules.map { name in
                guard let rule = module.unit(named: name)?.rule else { throw StateSpaceError.unknownUnit(name) }
                return rule
            }
        } else {
            self.rules = module.rules.filter(\.isActivated)
        }
        for name in units where module.unit(named: name) == nil { throw StateSpaceError.unknownUnit(name) }
        self.units = units
        self.options = options
    }

    /// Creates an explorer for rules.
    ///
    /// - Parameters:
    ///   - rules: The rules to apply at every match.
    ///   - options: The options of the exploration (default options).
    public init(rules: [Rule], options: ExplorationOptions = ExplorationOptions()) {
        module = HenshinModule(rules: rules)
        self.rules = rules
        units = []
        self.options = options
    }

    /// Explores the states reachable from the model of a resource.
    ///
    /// The resource is not changed: the explorer works on copies of its model.
    ///
    /// - Parameter resource: The resource that holds the initial model.
    /// - Returns: The state space.
    /// - Throws: ``StateSpaceError/unboundParameter(unit:parameter:)`` if a rule or unit needs
    ///   a parameter value that is not given, the errors of `HenshinEngine` for rules that
    ///   cannot be applied, and `CancellationError` if the task is cancelled.
    public func explore(from resource: Resource) async throws -> StateSpace {
        try checkParameters()
        let start = Date()
        let initial = await resource.snapshot()
        let resourceSet = await resource.resourceSet
        var workers: [Resource] = []
        for index in 0..<options.concurrency {
            let worker = Resource(uri: "\(resource.uri)#state-space-\(index)")
            await worker.setResourceSet(resourceSet)
            workers.append(worker)
        }
        var store = StateStore(equivalence: options.equivalence)
        var statistics = ExplorationStatistics()
        store.addInitial(initial, graph: StateGraph(initial))
        var frontier = [0]
        let pinned = rules.map(PinnedRule.init)
        while !frontier.isEmpty {
            try Task.checkCancellation()
            var expandable: [Int] = []
            for state in frontier {
                if let limit = options.maximumDepth, store.depth(of: state) >= limit {
                    store.markOpen(state)
                } else if let limit = options.maximumObjects, store.objectCount(of: state) > limit {
                    store.markOpen(state)
                } else {
                    expandable.append(state)
                }
            }
            let expansions = try await expand(expandable, store: store, pinned: pinned, workers: workers)
            var next: [Int] = []
            for (state, successors) in zip(expandable, expansions) {
                statistics.expandedStates += 1
                statistics.applications += successors.count
                for successor in successors {
                    switch store.insert(successor, from: state, maximumStates: options.maximumStates, statistics: &statistics) {
                    case .new(let id): next.append(id)
                    case .existing: break
                    case .rejected: store.markOpen(state)
                    }
                }
            }
            frontier = next
        }
        statistics.duration = Date().timeIntervalSince(start)
        return store.stateSpace(statistics: statistics)
    }

    /// Checks that every required parameter of a rule has a value, given or bound by
    /// matching.
    ///
    /// A parameter is bound by matching if a left-hand side node has its name or an
    /// attribute of a left-hand side node is the parameter itself.
    ///
    /// - Throws: ``StateSpaceError/unboundParameter(unit:parameter:)`` for the first
    ///   parameter without a value.
    func checkParameters() throws {
        for rule in rules {
            let bound = Set(rule.lhs.nodes.compactMap(\.name)).union(
                rule.lhs.nodes.flatMap { $0.attributes.map { $0.value.trimmingCharacters(in: .whitespaces) } })
            for parameter in rule.parameters where parameter.kind.isRequired && !bound.contains(parameter.name) {
                for given in options.parameterValues[rule.name] ?? [[:]] where given[parameter.name] == nil {
                    throw StateSpaceError.unboundParameter(unit: rule.name, parameter: parameter.name)
                }
            }
        }
    }

    /// Computes the successors of states, several at a time.
    private func expand(_ states: [Int], store: StateStore, pinned: [PinnedRule], workers: [Resource]) async throws -> [[Successor]] {
        var results = Array(repeating: [Successor](), count: states.count)
        var position = 0
        while position < states.count {
            let batch = Array(states[position..<min(position + workers.count, states.count)].enumerated())
            let base = position
            try await withThrowingTaskGroup(of: (Int, [Successor]).self) { group in
                for (offset, state) in batch {
                    let model = store.model(of: state)
                    let worker = workers[offset]
                    group.addTask { (base + offset, try await self.successors(of: model, pinned: pinned, worker: worker)) }
                }
                for try await (index, successors) in group { results[index] = successors }
            }
            position += workers.count
        }
        return results
    }

    /// Computes the successors of one state.
    ///
    /// - Parameters:
    ///   - model: The model of the state.
    ///   - pinned: The rules, pinned.
    ///   - worker: The resource to apply rules in.
    /// - Returns: The successors, rules first and in order, then units.
    func successors(of model: ResourceSnapshot, pinned: [PinnedRule], worker: Resource) async throws -> [Successor] {
        let engine = HenshinEngine(options: options.engineOptions)
        var result: [Successor] = []
        for rule in pinned {
            for given in options.parameterValues[rule.original.name] ?? [[:]] {
                await worker.restore(model)
                let matches = try await engine.findMatches(of: rule.original, in: worker, parameters: given)
                for match in matches {
                    try Task.checkCancellation()
                    await worker.restore(model)
                    let application: UnitApplication
                    do {
                        application = try await engine.apply(rule.rule, to: worker, parameters: rule.arguments(for: match, given: given))
                    } catch HenshinError.unboundParameter(_, let parameter) {
                        throw StateSpaceError.unboundParameter(unit: rule.original.name, parameter: parameter)
                    }
                    guard application.succeeded else { continue }
                    let successor = await worker.snapshot()
                    var parameters = given
                    for (name, value) in rule.reportedParameters(match) { parameters[name] = value }
                    result.append(
                        Successor(
                            label: rule.original.name, isUnit: false, match: rule.reportedMatch(match), parameters: parameters,
                            model: successor, graph: StateGraph(successor)))
                }
            }
        }
        for name in units {
            for given in options.parameterValues[name] ?? [[:]] {
                try Task.checkCancellation()
                await worker.restore(model)
                let application: UnitApplication
                do {
                    application = try await engine.apply(unitNamed: name, of: module, to: worker, parameters: given)
                } catch HenshinError.missingParameter(_, let parameter) {
                    throw StateSpaceError.unboundParameter(unit: name, parameter: parameter)
                } catch HenshinError.unboundParameter(_, let parameter) {
                    throw StateSpaceError.unboundParameter(unit: name, parameter: parameter)
                }
                guard application.succeeded else { continue }
                let successor = await worker.snapshot()
                result.append(
                    Successor(
                        label: name, isUnit: true, match: [:], parameters: given.merging(application.parameters) { $1 },
                        model: successor, graph: StateGraph(successor)))
            }
        }
        return result
    }
}

/// A model reached from a state, with the step that reached it.
struct Successor: Sendable {
    /// The name of the applied rule or unit.
    let label: String
    /// Whether a unit was applied.
    let isUnit: Bool
    /// The matched objects by node name.
    let match: [String: EUUID]
    /// The parameter values of the step.
    let parameters: ParameterValues
    /// The resulting model.
    let model: ResourceSnapshot
    /// The graph of the resulting model.
    let graph: StateGraph
}
