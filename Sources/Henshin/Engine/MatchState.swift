//
//  MatchState.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// The values bound to parameters during matching and application.
///
/// A parameter is bound once it has a value, which may be the null value; an unbound
/// parameter has no entry.
struct ParameterBindings: Sendable {
    /// The bound values, by parameter name.
    private(set) var values: [String: SendableValue] = [:]

    /// Creates bindings without values.
    init() {}

    /// Creates bindings from parameter values, giving objects by identity.
    ///
    /// - Parameter values: The parameter values; objects may be given as themselves.
    init(_ values: ParameterValues) {
        for (name, value) in values { self.values[name] = SendableValue(value: Self.normalised(value)) }
    }

    /// Whether a parameter has a value.
    ///
    /// - Parameter name: The name of the parameter.
    /// - Returns: `true` if the parameter is bound.
    func isBound(_ name: String) -> Bool { values[name] != nil }

    /// The value of a parameter.
    ///
    /// - Parameter name: The name of the parameter.
    /// - Returns: The value, or `nil` if the parameter is unbound or bound to null.
    func value(_ name: String) -> (any EcoreValue)? { values[name]?.value }

    /// Binds a parameter.
    ///
    /// - Parameters:
    ///   - name: The name of the parameter.
    ///   - value: The value; an object is stored as its identity.
    mutating func bind(_ name: String, _ value: (any EcoreValue)?) {
        values[name] = SendableValue(value: value.map(Self.normalised))
    }

    /// Removes the value of a parameter.
    ///
    /// - Parameter name: The name of the parameter.
    mutating func unbind(_ name: String) { values[name] = nil }

    /// The bound values as public parameter values, leaving out null values.
    var parameterValues: ParameterValues {
        var result: ParameterValues = [:]
        for (name, value) in values { if let value = value.value { result[name] = value } }
        return result
    }

    /// Replaces an object by its identity; other values stay as they are.
    static func normalised(_ value: any EcoreValue) -> any EcoreValue {
        if let object = value as? DynamicEObject { return object.id }
        return value
    }
}

/// A check that waits until the parameters it refers to have values.
enum PendingCheck: Sendable {
    /// An attribute check of a node, by node position and check position.
    case attribute(node: Int, check: Int)
    /// An attribute condition of the rule, by position.
    case condition(Int)
}

/// The state of a search for a match of a pattern.
struct MatchState: Sendable {
    /// The object bound to each node, by node position.
    var binding: [EUUID?]
    /// The objects that injective matching must not use again.
    var used: Set<EUUID> = []
    /// The parameter values bound so far.
    var parameters: ParameterBindings
    /// The positions of nodes bound through mappings, which are exempt from injectivity.
    var mapped: Set<Int> = []
    /// The checks that wait for parameter values.
    var pending: [PendingCheck] = []

    /// Creates the state of a search over a pattern of a given size.
    ///
    /// - Parameters:
    ///   - size: The number of nodes of the pattern.
    ///   - parameters: The parameter values known when the search starts.
    init(size: Int, parameters: ParameterBindings) {
        binding = Array(repeating: nil, count: size)
        self.parameters = parameters
    }
}

/// A match found by a search, before it is turned into a public ``Match``.
struct MatchInstance: Sendable {
    /// The matched objects by rule node identity.
    let binding: [NodeID: EUUID]
    /// The parameter values after matching.
    let parameters: ParameterBindings
    /// The matches of each multi-rule.
    var multiMatches: [[MatchInstance]] = []

    /// The public form of the match.
    ///
    /// - Parameter rule: The rule that was matched.
    /// - Returns: The match.
    func publicMatch(of rule: CompiledRule) -> Match {
        Match(
            ruleName: rule.rule.name, nodes: binding, parameters: parameters.parameterValues,
            multiMatches: zip(rule.multiRules, multiMatches).map { multi, matches in
                matches.map { $0.publicMatch(of: multi.rule) }
            })
    }
}

/// Where a search takes the candidates for a node from.
enum CandidateSource: Sendable {
    /// The node is bound before the search starts.
    case fixed
    /// All objects of the node's type.
    case extent
    /// The objects that a bound node refers to through a reference.
    case forward(from: Int, reference: String)
    /// The objects that refer to a bound node through a reference.
    case backward(from: Int, reference: String)
}

/// One step of a search plan: a node, its candidates and the edges to check.
struct PlanStep: Sendable {
    /// The position of the node.
    let node: Int
    /// Where the candidates come from.
    let source: CandidateSource
    /// The edges to check once the node is bound: those whose other end is bound earlier.
    let edgeChecks: [Int]
}

/// A small, fast, seedable random number generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator, Sendable {
    /// The state of the generator.
    private var state: UInt64

    /// Creates a generator.
    ///
    /// - Parameter seed: The seed.
    init(seed: UInt64) { state = seed }

    /// Produces the next random number.
    ///
    /// - Returns: A pseudo-random 64-bit number.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
