//
//  PinnedRule.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Henshin

/// A rule whose left-hand side nodes can be fixed to objects, so that it is applied at one
/// given match.
///
/// The engine binds a node to the parameter of the same name. A pinned rule gives every
/// left-hand side node such a parameter and makes every parameter optional, so that
/// applying it with the objects of a match applies the original rule at exactly that match.
struct PinnedRule: Sendable {
    /// The rule as given.
    let original: Rule

    /// The rule with a parameter for every left-hand side node.
    let rule: Rule

    /// The parameter that fixes each left-hand side node, by node identity.
    let parameters: [NodeID: String]

    /// The name under which each left-hand side node is reported, by node identity.
    let displayNames: [NodeID: String]

    /// The prefix of the parameters added for unnamed nodes or nodes whose names are not
    /// parameters.
    static let parameterPrefix = "__pin"

    /// Pins a rule.
    ///
    /// - Parameter rule: The rule.
    init(_ rule: Rule) {
        original = rule
        var copy = rule
        let declared = Set(rule.parameters.map(\.name))
        copy.parameters = rule.parameters.map { UnitParameter(name: $0.name, kind: .unknown, typeName: $0.typeName) }
        var parameters: [NodeID: String] = [:]
        var displayNames: [NodeID: String] = [:]
        for index in copy.lhs.nodes.indices {
            let node = copy.lhs.nodes[index]
            displayNames[node.id] = node.name ?? node.id.description
            if let name = node.name, declared.contains(name) {
                parameters[node.id] = name
                continue
            }
            let name = "\(Self.parameterPrefix)\(node.id.rawValue)"
            copy.lhs.nodes[index].name = name
            copy.parameters.append(UnitParameter(name: name, kind: .unknown))
            parameters[node.id] = name
        }
        self.rule = copy
        self.parameters = parameters
        self.displayNames = displayNames
    }

    /// The parameter values that apply the rule at a match.
    ///
    /// - Parameters:
    ///   - match: A match of the original rule.
    ///   - given: The parameter values the match was found with.
    /// - Returns: The given values with every matched node fixed.
    func arguments(for match: Match, given: ParameterValues) -> ParameterValues {
        var result = given
        for (node, object) in match.nodes {
            if let name = parameters[node] { result[name] = object }
        }
        return result
    }

    /// The matched objects by reported node name.
    ///
    /// - Parameter match: A match of the original rule.
    /// - Returns: The objects by node name.
    func reportedMatch(_ match: Match) -> [String: EUUID] {
        var result: [String: EUUID] = [:]
        for (node, object) in match.nodes {
            if let name = displayNames[node] { result[name] = object }
        }
        return result
    }

    /// The parameter values of a match that the caller may see: those declared by the rule
    /// and not hidden as variables.
    ///
    /// - Parameter match: A match of the original rule.
    /// - Returns: The visible parameter values.
    func reportedParameters(_ match: Match) -> ParameterValues {
        var result: ParameterValues = [:]
        for parameter in original.parameters where parameter.kind.isVisibleToCaller {
            if let value = match.parameters[parameter.name] { result[parameter.name] = value }
        }
        return result
    }
}
