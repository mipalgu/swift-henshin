//
//  EngineOptions.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// The options that control how a ``HenshinEngine`` finds matches and applies units.
public struct EngineOptions: Sendable, Hashable {
    /// Whether matches are found and sub-units are tried in a fixed order.
    ///
    /// Deterministic application (the default, as in Henshin) tries candidate objects in the
    /// order of the resource and the sub-units of an independent unit in the order of the
    /// unit. Otherwise candidates and sub-units are shuffled with a random number generator
    /// seeded by ``randomSeed``.
    public var deterministic: Bool

    /// The seed of the random number generator used when matching is not deterministic.
    ///
    /// `nil` seeds the generator from the system's source of randomness; a fixed seed makes
    /// non-deterministic applications reproducible.
    public var randomSeed: UInt64?

    /// Overrides the injective matching setting of every rule, if given.
    public var injectiveMatching: Bool?

    /// Overrides the dangling condition setting of every rule, if given.
    public var checkDangling: Bool?

    /// The largest number of iterations that a loop unit performs, or `nil` for no limit.
    ///
    /// A loop whose sub-unit always succeeds never ends; the limit stops it with a warning.
    public var iterationLimit: Int?

    /// Whether a failed or cancelled application restores the model to its state before
    /// the application.
    ///
    /// A unit that simply does not succeed is not a failure: its effects follow Henshin's
    /// rules for each kind of unit. This option concerns errors, such as an expression
    /// that cannot be evaluated, and cancellation.
    public var restoresOnError: Bool

    /// Creates options.
    ///
    /// - Parameters:
    ///   - deterministic: Whether matching and unit choice follow a fixed order (default
    ///     `true`).
    ///   - randomSeed: The seed for non-deterministic application, if any.
    ///   - injectiveMatching: Overrides the injectivity of every rule, if given.
    ///   - checkDangling: Overrides the dangling condition of every rule, if given.
    ///   - iterationLimit: The largest number of loop iterations, if any.
    ///   - restoresOnError: Whether errors and cancellation restore the model (default
    ///     `true`).
    public init(
        deterministic: Bool = true, randomSeed: UInt64? = nil, injectiveMatching: Bool? = nil,
        checkDangling: Bool? = nil, iterationLimit: Int? = nil, restoresOnError: Bool = true
    ) {
        self.deterministic = deterministic
        self.randomSeed = randomSeed
        self.injectiveMatching = injectiveMatching
        self.checkDangling = checkDangling
        self.iterationLimit = iterationLimit
        self.restoresOnError = restoresOnError
    }
}

/// The values of parameters by name.
///
/// Objects are given and returned as their identities (`EUUID`); other values are Ecore
/// values such as `Int`, `Double`, `String` or `Bool`. A parameter without a value has no
/// entry.
public typealias ParameterValues = [String: any EcoreValue]

/// A match of a rule: the objects that its left-hand side nodes are bound to.
public struct Match: Sendable {
    /// The name of the rule.
    public let ruleName: String

    /// The objects matched by the left-hand side nodes, by node identity.
    public let nodes: [NodeID: EUUID]

    /// The values of the rule's parameters after matching.
    public let parameters: ParameterValues

    /// The matches of each multi-rule, in the order of the rule's multi-rules.
    public let multiMatches: [[Match]]

    /// Creates a match.
    ///
    /// - Parameters:
    ///   - ruleName: The name of the rule.
    ///   - nodes: The matched objects by node identity.
    ///   - parameters: The parameter values after matching.
    ///   - multiMatches: The matches of each multi-rule.
    public init(ruleName: String, nodes: [NodeID: EUUID], parameters: ParameterValues, multiMatches: [[Match]] = []) {
        self.ruleName = ruleName
        self.nodes = nodes
        self.parameters = parameters
        self.multiMatches = multiMatches
    }

    /// The object matched by a node.
    ///
    /// - Parameter node: The identity of a left-hand side node.
    /// - Returns: The identity of the matched object, or `nil` if the node is not matched.
    public subscript(node: NodeID) -> EUUID? { nodes[node] }
}

/// The application of a rule: what it matched and what it changed.
public struct RuleApplication: Sendable {
    /// The name of the rule.
    public let ruleName: String

    /// The match at which the rule was applied.
    public let match: Match

    /// The objects that the right-hand side nodes stand for after the application, by node
    /// identity, including those of the multi-rules.
    public let resultNodes: [NodeID: EUUID]

    /// The parameter values after the application.
    public let parameters: ParameterValues

    /// The identities of the objects that the application created.
    public let createdObjects: [EUUID]

    /// The identities of the objects that the application deleted.
    public let deletedObjects: [EUUID]

    /// The changes that the application made to the resource, in order.
    public let changes: [ResourceChange]
}

/// The outcome of applying a transformation unit.
public struct UnitApplication: Sendable {
    /// The name of the unit.
    public let unitName: String

    /// Whether the unit succeeded.
    public let succeeded: Bool

    /// The parameter values after the application.
    ///
    /// For a rule these are all its parameters except variable ones; for other units, as
    /// in Henshin, the output and input-output parameters. The values of variable
    /// parameters are hidden from the caller; the rule applications in ``appliedRules``
    /// still record them.
    public let parameters: ParameterValues

    /// The rule applications that took effect, in order.
    ///
    /// Applications that a unit rolled back are not listed.
    public let appliedRules: [RuleApplication]

    /// What the engine noticed while applying the unit, such as rollbacks and iteration
    /// limits.
    public let diagnostics: [SourceDiagnostic]

    /// Statistics of the search for matches.
    public let statistics: MatchStatistics
}

/// Counts that describe the work of match finding.
public struct MatchStatistics: Sendable, Hashable {
    /// The number of searches for a match of a rule.
    public var searches = 0

    /// The number of candidate objects tried for nodes.
    public var candidates = 0

    /// The number of nested condition checks.
    public var conditionChecks = 0

    /// The number of expressions evaluated as AQL queries.
    public var queries = 0

    /// Creates empty statistics.
    public init() {}
}
