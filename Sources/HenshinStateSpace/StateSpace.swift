//
//  StateSpace.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin

/// How the exploration decides that two models are the same state.
public enum StateEquivalence: String, Sendable, Hashable, CaseIterable {
    /// Models are the same state if they are isomorphic: equal up to the identities and
    /// order of their objects (the default, as in Henshin's state-space tools and GROOVE).
    case isomorphism
    /// Models are the same state only if they have the same objects, by identity, with the
    /// same attribute values and references.
    case identity
}

/// The options of a state-space exploration.
public struct ExplorationOptions: Sendable {
    /// The largest number of states to discover, or `nil` for no limit.
    ///
    /// When the limit is reached, the states whose successors were not all recorded stay
    /// open and the state space is incomplete.
    public var maximumStates: Int?

    /// The largest depth (number of steps from the initial state) of an explored state, or
    /// `nil` for no limit; states at that depth stay open.
    public var maximumDepth: Int?

    /// The largest number of objects of an explored state, or `nil` for no limit; larger
    /// states stay open.
    public var maximumObjects: Int?

    /// How states are told apart.
    public var equivalence: StateEquivalence

    /// The parameter values to try for each rule or unit, by name.
    ///
    /// A rule or unit is applied once for each listed assignment; without an entry it is
    /// applied with no values, and its parameters are bound by matching.
    public var parameterValues: [String: [ParameterValues]]

    /// The options of the transformation engine that applies the rules.
    public var engineOptions: EngineOptions

    /// The number of states expanded at once.
    public var concurrency: Int

    /// Creates options.
    ///
    /// - Parameters:
    ///   - maximumStates: The largest number of states (default 100 000).
    ///   - maximumDepth: The largest depth, if any.
    ///   - maximumObjects: The largest number of objects of an explored state, if any.
    ///   - equivalence: How states are told apart (default ``StateEquivalence/isomorphism``).
    ///   - parameterValues: The parameter values to try, by rule or unit name.
    ///   - engineOptions: The options of the engine (default options).
    ///   - concurrency: The number of states expanded at once (default 4).
    public init(
        maximumStates: Int? = 100_000, maximumDepth: Int? = nil, maximumObjects: Int? = nil,
        equivalence: StateEquivalence = .isomorphism, parameterValues: [String: [ParameterValues]] = [:],
        engineOptions: EngineOptions = EngineOptions(), concurrency: Int = 4
    ) {
        self.maximumStates = maximumStates
        self.maximumDepth = maximumDepth
        self.maximumObjects = maximumObjects
        self.equivalence = equivalence
        self.parameterValues = parameterValues
        self.engineOptions = engineOptions
        self.concurrency = max(concurrency, 1)
    }
}

/// A state of a state space: a model reachable from the initial model.
public struct ExploredState: Sendable, Identifiable {
    /// The number of the state; the initial state is 0, and states are numbered in the
    /// order in which a breadth-first search discovers them.
    public let id: Int

    /// The number of steps on a shortest path from the initial state.
    public let depth: Int

    /// The model of the state, as first reached.
    public let model: ResourceSnapshot

    /// The number of model objects of the state.
    public let objectCount: Int

    /// The certificate of the state: equal for states that are the same up to isomorphism.
    public let certificate: UInt64

    /// Whether the state was left unexplored, or explored only in part, because of a limit.
    public let isOpen: Bool

    /// The transition by which the state was first reached, or `nil` for the initial state.
    public let parent: Int?
}

/// A step between two states: the application of a rule at a match, or of a unit.
public struct StateTransition: Sendable, Identifiable, CustomStringConvertible {
    /// The number of the transition.
    public let id: Int

    /// The state the step starts from.
    public let source: Int

    /// The state the step leads to.
    public let target: Int

    /// The name of the applied rule or unit.
    public let label: String

    /// Whether the step applies a unit rather than a rule.
    public let isUnit: Bool

    /// The objects of the source state's model that the rule matched, by node: the node's
    /// name, or its identity such as `#3` for an unnamed node. Empty for units.
    public let match: [String: EUUID]

    /// The parameter values of the step: those given and, for a rule, those bound by the
    /// match.
    public let parameters: ParameterValues

    /// A description such as `pass(p=…, q=…)`.
    public var description: String {
        let bindings = match.keys.sorted().map { "\($0)=\(match[$0]!)" }
        let values = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }
        return "\(label)(\((bindings + values).joined(separator: ", ")))"
    }
}

/// Counts that describe the work of an exploration.
public struct ExplorationStatistics: Sendable, Hashable {
    /// The number of states whose successors were computed.
    public var expandedStates = 0

    /// The number of rule and unit applications.
    public var applications = 0

    /// The number of exact isomorphism checks between states with equal certificates.
    public var isomorphismChecks = 0

    /// The number of states with equal certificates that turned out not to be isomorphic.
    public var certificateCollisions = 0

    /// The time the exploration took, in seconds.
    public var duration: Double = 0

    /// Creates empty statistics.
    public init() {}
}

/// The states reachable from a model and the steps between them: a labelled transition
/// system.
public struct StateSpace: Sendable, CustomStringConvertible {
    /// The states, by number.
    public let states: [ExploredState]

    /// The transitions, by number.
    public let transitions: [StateTransition]

    /// How states were told apart.
    public let equivalence: StateEquivalence

    /// Statistics of the exploration.
    public let statistics: ExplorationStatistics

    /// The positions in ``transitions`` of the transitions that leave each state.
    private let outgoingIndex: [[Int]]

    /// The positions in ``transitions`` of the transitions that enter each state.
    private let incomingIndex: [[Int]]

    /// Creates a state space.
    ///
    /// - Parameters:
    ///   - states: The states, numbered from 0.
    ///   - transitions: The transitions, numbered from 0.
    ///   - equivalence: How states were told apart.
    ///   - statistics: Statistics of the exploration.
    public init(
        states: [ExploredState], transitions: [StateTransition], equivalence: StateEquivalence,
        statistics: ExplorationStatistics
    ) {
        self.states = states
        self.transitions = transitions
        self.equivalence = equivalence
        self.statistics = statistics
        var outgoing = Array(repeating: [Int](), count: states.count)
        var incoming = Array(repeating: [Int](), count: states.count)
        for transition in transitions {
            outgoing[transition.source].append(transition.id)
            incoming[transition.target].append(transition.id)
        }
        outgoingIndex = outgoing
        incomingIndex = incoming
    }

    /// The number of the initial state.
    public var initialState: Int { 0 }

    /// The states that were not fully explored because of a limit.
    public var openStates: [Int] { states.filter(\.isOpen).map(\.id) }

    /// Whether every reachable state was explored, so that checks are conclusive.
    public var isComplete: Bool { !states.contains { $0.isOpen } }

    /// The transitions that leave a state.
    ///
    /// - Parameter state: The number of the state.
    /// - Returns: The transitions, in the order in which they were found.
    public func outgoing(_ state: Int) -> [StateTransition] { outgoingIndex[state].map { transitions[$0] } }

    /// The transitions that enter a state.
    ///
    /// - Parameter state: The number of the state.
    /// - Returns: The transitions, in the order in which they were found.
    public func incoming(_ state: Int) -> [StateTransition] { incomingIndex[state].map { transitions[$0] } }

    /// The explored states that no rule or unit can leave.
    public var deadlocks: [Int] {
        states.filter { !$0.isOpen && outgoingIndex[$0.id].isEmpty }.map(\.id)
    }

    /// A shortest path from the initial state to a state.
    ///
    /// Each step's match refers to the model of its source state, and each state's model is
    /// the result of the step before it, so the path can be replayed on the initial model.
    ///
    /// - Parameter state: The number of the state.
    /// - Returns: The transitions of the path, in order; empty for the initial state.
    public func path(to state: Int) -> [StateTransition] {
        var result: [StateTransition] = []
        var current = state
        while let parent = states[current].parent {
            let transition = transitions[parent]
            result.append(transition)
            current = transition.source
        }
        return result.reversed()
    }

    /// A summary such as `12 states, 30 transitions, complete`.
    public var description: String {
        let open = openStates.count
        return "\(states.count) states, \(transitions.count) transitions, "
            + (open == 0 ? "complete" : "\(open) open")
    }

    /// The state space in the DOT language of GraphViz.
    ///
    /// The initial state is drawn with a double circle, open states dashed and deadlocks as
    /// boxes. Transitions between the same states with the same label are drawn once.
    ///
    /// - Parameters:
    ///   - name: The name of the graph (default `statespace`).
    ///   - highlighted: States to draw in bold, such as those of a counterexample.
    ///   - stateLabel: The label of a state (default: its number).
    /// - Returns: The DOT text.
    public func dot(
        name: String = "statespace", highlighted: Set<Int> = [], stateLabel: (ExploredState) -> String = { "\($0.id)" }
    ) -> String {
        let deadlockSet = Set(deadlocks)
        var lines = ["digraph \(Self.quoted(name)) {", "  node [shape=circle];"]
        for state in states {
            var attributes = ["label=\(Self.quoted(stateLabel(state)))"]
            if state.id == initialState {
                attributes.append("shape=doublecircle")
            } else if deadlockSet.contains(state.id) {
                attributes.append("shape=box")
            }
            var styles: [String] = []
            if state.isOpen { styles.append("dashed") }
            if highlighted.contains(state.id) { styles.append("bold") }
            if !styles.isEmpty { attributes.append("style=\(Self.quoted(styles.joined(separator: ",")))") }
            lines.append("  s\(state.id) [\(attributes.joined(separator: ", "))];")
        }
        var drawn = Set<String>()
        for transition in transitions {
            let key = "\(transition.source) \(transition.target) \(transition.label)"
            guard drawn.insert(key).inserted else { continue }
            lines.append("  s\(transition.source) -> s\(transition.target) [label=\(Self.quoted(transition.label))];")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// A DOT string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
