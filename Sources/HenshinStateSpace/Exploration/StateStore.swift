//
//  StateStore.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin

/// The states and transitions found so far, with the index that finds a state again.
struct StateStore: Sendable {
    /// What is known about a state while the exploration runs.
    struct Record: Sendable {
        /// The model of the state.
        let model: ResourceSnapshot
        /// The graph of the model.
        let graph: StateGraph
        /// The depth of the state.
        let depth: Int
        /// The transition that first reached the state.
        let parent: Int?
        /// Whether a limit cut the exploration of the state short.
        var isOpen = false
    }

    /// The outcome of recording a successor.
    enum Insertion: Sendable {
        /// The successor is a new state.
        case new(Int)
        /// The successor is a known state.
        case existing(Int)
        /// The successor is new, but the state limit forbids recording it.
        case rejected
    }

    /// How states are told apart.
    let equivalence: StateEquivalence

    /// The states, by number.
    private(set) var records: [Record] = []

    /// The transitions, by number.
    private(set) var transitions: [StateTransition] = []

    /// The states by certificate, for isomorphism.
    private var byCertificate: [UInt64: [Int]] = [:]

    /// The states by identity form, for identity.
    private var byIdentity: [IdentityForm: Int] = [:]

    /// Creates an empty store.
    ///
    /// - Parameter equivalence: How states are told apart.
    init(equivalence: StateEquivalence) {
        self.equivalence = equivalence
    }

    /// Records the initial state.
    mutating func addInitial(_ model: ResourceSnapshot, graph: StateGraph) {
        add(Record(model: model, graph: graph, depth: 0, parent: nil))
    }

    /// The model of a state.
    func model(of state: Int) -> ResourceSnapshot { records[state].model }

    /// The depth of a state.
    func depth(of state: Int) -> Int { records[state].depth }

    /// The number of objects of a state.
    func objectCount(of state: Int) -> Int { records[state].graph.nodeCount }

    /// Marks a state as open.
    mutating func markOpen(_ state: Int) { records[state].isOpen = true }

    /// Records a successor of a state and the transition to it.
    ///
    /// - Parameters:
    ///   - successor: The successor.
    ///   - source: The state it was reached from.
    ///   - maximumStates: The largest number of states, if any.
    ///   - statistics: The statistics to update.
    /// - Returns: Whether the successor is a new or known state, or could not be recorded.
    mutating func insert(_ successor: Successor, from source: Int, maximumStates: Int?, statistics: inout ExplorationStatistics)
        -> Insertion
    {
        if let known = find(successor.graph, statistics: &statistics) {
            addTransition(successor, from: source, to: known)
            return .existing(known)
        }
        if let maximumStates, records.count >= maximumStates { return .rejected }
        let id = records.count
        let transition = transitions.count
        add(Record(model: successor.model, graph: successor.graph, depth: records[source].depth + 1, parent: transition))
        addTransition(successor, from: source, to: id)
        return .new(id)
    }

    /// Finds a known state that a graph is equivalent to.
    private func find(_ graph: StateGraph, statistics: inout ExplorationStatistics) -> Int? {
        switch equivalence {
        case .identity:
            return byIdentity[graph.identityForm]
        case .isomorphism:
            for candidate in byCertificate[graph.certificate] ?? [] {
                statistics.isomorphismChecks += 1
                if graph.isomorphism(to: records[candidate].graph) != nil { return candidate }
                statistics.certificateCollisions += 1
            }
            return nil
        }
    }

    /// Adds a state and indexes it.
    private mutating func add(_ record: Record) {
        let id = records.count
        records.append(record)
        switch equivalence {
        case .identity: byIdentity[record.graph.identityForm] = id
        case .isomorphism: byCertificate[record.graph.certificate, default: []].append(id)
        }
    }

    /// Adds a transition.
    private mutating func addTransition(_ successor: Successor, from source: Int, to target: Int) {
        transitions.append(
            StateTransition(
                id: transitions.count, source: source, target: target, label: successor.label, isUnit: successor.isUnit,
                match: successor.match, parameters: successor.parameters))
    }

    /// The finished state space.
    func stateSpace(statistics: ExplorationStatistics) -> StateSpace {
        let states = records.enumerated().map { id, record in
            ExploredState(
                id: id, depth: record.depth, model: record.model, objectCount: record.graph.nodeCount,
                certificate: record.graph.certificate, isOpen: record.isOpen, parent: record.parent)
        }
        return StateSpace(states: states, transitions: transitions, equivalence: equivalence, statistics: statistics)
    }
}
