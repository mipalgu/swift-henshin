//
//  HenshinValidator.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// Checks Henshin modules for problems that would make their rules fail or misbehave.
///
/// The validator reports, without applying anything, what the engine would reject or
/// cannot interpret: mappings that do not lead from the left-hand to the right-hand side,
/// nodes of abstract classes that rules create, edges and attributes whose features do not
/// belong to their node's class, assignments to unchangeable attributes, expressions
/// outside the supported JavaScript subset, duplicate parameters, missing sub-units and
/// edge positions, which are not interpreted.
///
/// It also applies Henshin's checks of well-definedness and consistency. As errors: rules
/// and units with the same name and parameter list, variable parameters that occur nowhere
/// in a rule's left-hand side, and units that pass no value to an input or input-output
/// parameter of a sub-unit. As warnings: rules that delete a node without its containment
/// edge while checking the dangling condition, and rule graphs that hold a containment
/// cycle.
///
/// Finally, it reports as warnings what Henshin's clean-up operation would remove or repair:
/// unused parameters, mappings that lead between the wrong graphs or classes, multi-rules
/// that disagree with their kernel rules, trivial nested conditions, conditions of
/// right-hand sides, iterated units without a number of iterations, parameter mappings to
/// units other than direct sub-units, and metamodel imports that are unused or missing.
public enum HenshinValidator {
    /// Validates a module.
    ///
    /// - Parameters:
    ///   - module: The module.
    ///   - metamodels: The metamodel packages whose classes the rules use, including nested
    ///     packages; when given, imports that no node uses and packages of node classes that
    ///     the module does not import are reported (default none, which skips these checks).
    /// - Returns: The findings, in the order of the units; empty if there are none.
    public static func validate(_ module: HenshinModule, metamodels: [EPackage] = []) -> [SourceDiagnostic] {
        var findings = signatureFindings(module.units)
        for unit in module.units {
            findings += parameterFindings(unit.parameters, owner: "unit '\(unit.name)'")
            findings += passingFindings(unit, in: module)
            findings += parameterMappingFindings(unit, in: module)
            if unit.rule == nil { findings += unusedParameterFindings(of: unit) }
            if case .iterated(_, let iterations, _, _) = unit.kind, iterations.trimmingCharacters(in: .whitespaces).isEmpty {
                findings.append(
                    .henshin(.warning, .emptyIterations, "Iterated unit '\(unit.name)' gives no number of iterations; Henshin's clean-up sets it to 1"))
            }
            for subUnit in unit.kind.subUnits where module.unit(subUnit) == nil {
                findings.append(.henshin(.error, .unknownSubUnit, "Unit '\(unit.name)' refers to the missing unit \(subUnit)"))
            }
            if case .iterated(_, let iterations, _, _) = unit.kind, Int(iterations) == nil {
                findings += expressionFindings(iterations, variables: Set(unit.parameters.map(\.name)), owner: "unit '\(unit.name)'")
            }
            if let rule = unit.rule { findings += validate(rule) }
        }
        if !metamodels.isEmpty { findings += importFindings(module, metamodels: metamodels) }
        return findings
    }

    /// Validates a rule and its multi-rules.
    ///
    /// - Parameter rule: The rule.
    /// - Returns: The findings.
    public static func validate(_ rule: Rule) -> [SourceDiagnostic] {
        validate(rule, kernelParameters: [], kernel: nil) + unusedParameterFindings(of: rule)
    }

    /// Validates a rule, or a multi-rule within its kernel rule, and its multi-rules.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - kernelParameters: The names of the parameters that the kernel rules declare;
    ///     their variable parameters are checked together with the kernel.
    ///   - kernel: For a multi-rule, its kernel rule, with which the deletion of nodes copied
    ///     from the kernel and the multi-mappings are checked; `nil` for a rule of a unit.
    /// - Returns: The findings.
    private static func validate(_ rule: Rule, kernelParameters: Set<String>, kernel: Rule?) -> [SourceDiagnostic] {
        let isMultiRule = kernel != nil
        var findings: [SourceDiagnostic] = []
        let owner = "rule '\(rule.name)'"
        let names = Set(rule.parameters.map(\.name))
        findings += parameterFindings(rule.parameters, owner: owner)
        for parameter in rule.parameters
        where parameter.kind == .var && !kernelParameters.contains(parameter.name) && !occursOnLeftSide(parameter.name, of: rule) {
            findings.append(
                .henshin(.error, .varParameterNotInLeftSide,
                    "\(owner.capitalisedFirst) never matches its VAR parameter '\(parameter.name)' in its left-hand side"))
        }
        findings += deletionFindings(rule, isMultiRule: isMultiRule, owner: owner)
        for mapping in rule.mappings where !rule.lhs.contains(mapping.origin) || !rule.rhs.contains(mapping.image) {
            findings.append(.henshin(.error, .invalidMapping, "A mapping of \(owner) does not lead from its left-hand to its right-hand side"))
        }
        for node in rule.rhs.nodes where rule.origin(of: node.id) == nil && !rule.multiMappings.contains(where: { $0.image == node.id }) {
            if node.type.isAbstract || node.type.isInterface {
                findings.append(.henshin(.error, .abstractCreation, "\(owner.capitalisedFirst) creates a node of the abstract class '\(node.type.name)'"))
            }
        }
        for graph in graphs(of: rule) {
            findings += graphFindings(graph, variables: names, owner: owner)
            if hasContainmentCycle(graph) {
                findings.append(.henshin(.warning, .containmentCycle, "A graph of \(owner) holds a cycle of containment edges"))
            }
        }
        for node in rule.rhs.nodes {
            for attribute in node.attributes where attribute.feature.derived || !attribute.feature.changeable {
                let unchanged = rule.origin(of: node.id).flatMap { rule.lhs.node($0)?.attribute(named: attribute.feature.name)?.value } == attribute.value
                if !unchanged {
                    findings.append(
                        .henshin(.error, .unchangeableFeature, "\(owner.capitalisedFirst) assigns the unchangeable attribute '\(attribute.feature.name)'"))
                }
            }
        }
        for condition in rule.attributeConditions {
            findings += expressionFindings(condition.conditionText, variables: names, owner: owner)
        }
        findings += cleanUpFindings(rule, kernel: kernel, owner: owner)
        for multiRule in rule.multiRules {
            findings += validate(multiRule, kernelParameters: kernelParameters.union(names), kernel: rule)
        }
        return findings
    }

    /// The graphs of a rule: both sides and the conclusions of all nested conditions.
    private static func graphs(of rule: Rule) -> [RuleGraph] {
        [rule.lhs, rule.rhs] + conclusions(of: rule.lhs.formula)
    }

    /// The conclusions of the nested conditions of a formula, including those nested in
    /// the conclusions, in document order.
    static func conclusions(of formula: Formula?) -> [RuleGraph] {
        switch formula {
        case .condition(let condition)?:
            return [condition.conclusion] + conclusions(of: condition.conclusion.formula)
        case .not(let child)?:
            return conclusions(of: child)
        case .and(let left, let right)?, .or(let left, let right)?, .xor(let left, let right)?:
            return conclusions(of: left) + conclusions(of: right)
        case .true?, nil:
            return []
        }
    }

    /// Whether a parameter occurs in the left-hand side of a rule or of its multi-rules, as
    /// the name of a node, the whole value of an attribute or the position of an edge,
    /// including the conclusions of nested conditions.
    private static func occursOnLeftSide(_ name: String, of rule: Rule) -> Bool {
        ([rule.lhs] + conclusions(of: rule.lhs.formula)).contains { graph in
            graph.nodes.contains { node in
                node.name == name || node.attributes.contains { $0.value.trimmingCharacters(in: .whitespaces) == name }
            } || graph.edges.contains { $0.index?.trimmingCharacters(in: .whitespaces) == name }
        } || rule.multiRules.contains { occursOnLeftSide(name, of: $0) }
    }

    /// Checks that a rule deletes each node together with the containment edge that holds
    /// it, if the rule checks the dangling condition.
    ///
    /// Nodes of a multi-rule that copy a node of the kernel rule are checked with the kernel.
    private static func deletionFindings(_ rule: Rule, isMultiRule: Bool, owner: String) -> [SourceDiagnostic] {
        guard rule.checkDangling else { return [] }
        let copied = isMultiRule ? Set(rule.multiMappings.map(\.image)) : []
        return rule.lhs.nodes.compactMap { node in
            guard rule.image(of: node.id) == nil, !copied.contains(node.id) else { return nil }
            let contained = rule.lhs.edges.contains { edge in
                (edge.target == node.id && edge.type.containment) || (edge.source == node.id && edge.type.container)
            }
            return contained
                ? nil
                : .henshin(.warning, .deletionWithoutContainment,
                    "\(owner.capitalisedFirst) deletes a node of class '\(node.type.name)' without its containment edge")
        }
    }

    /// Whether the containment edges of a graph form a cycle.
    private static func hasContainmentCycle(_ graph: RuleGraph) -> Bool {
        var children: [NodeID: [NodeID]] = [:]
        for edge in graph.edges where edge.type.containment { children[edge.source, default: []].append(edge.target) }
        var finished = Set<NodeID>()
        var onPath = Set<NodeID>()
        /// Whether a cycle is reachable from a node, by depth-first search.
        func reachesCycle(_ node: NodeID) -> Bool {
            if onPath.contains(node) { return true }
            if finished.contains(node) { return false }
            onPath.insert(node)
            defer {
                onPath.remove(node)
                finished.insert(node)
            }
            return children[node, default: []].contains { reachesCycle($0) }
        }
        return children.keys.sorted().contains { reachesCycle($0) }
    }

    /// Checks that no two units share their name and parameter list.
    ///
    /// The parameter list is compared by the names and declared types of the parameters,
    /// in order.
    private static func signatureFindings(_ units: [TransformationUnit]) -> [SourceDiagnostic] {
        var seen = Set<[String]>()
        return units.compactMap { unit in
            let signature = [unit.name] + unit.parameters.map { "\($0.name):\($0.typeName ?? "")" }
            return seen.insert(signature).inserted
                ? nil
                : .henshin(.error, .duplicateSignature,
                    "\(unit.kind.className) '\(unit.name)' has the same name and parameters as another unit")
        }
    }

    /// Checks that a unit passes a value to every input and input-output parameter of each
    /// of its sub-units.
    private static func passingFindings(_ unit: TransformationUnit, in module: HenshinModule) -> [SourceDiagnostic] {
        var checked = Set<UnitID>()
        var findings: [SourceDiagnostic] = []
        for subUnitID in unit.kind.subUnits where checked.insert(subUnitID).inserted {
            guard let subUnit = module.unit(subUnitID) else { continue }
            for parameter in subUnit.parameters where parameter.kind.isRequired {
                let passed = unit.parameterMappings.contains {
                    $0.source.unit == unit.id && $0.target == ParameterReference(unit: subUnitID, name: parameter.name)
                }
                if !passed {
                    findings.append(
                        .henshin(.error, .unpassedParameter,
                            "Unit '\(unit.name)' passes no value to the \(parameter.kind.rawValue) parameter '\(parameter.name)' of '\(subUnit.name)'"))
                }
            }
        }
        return findings
    }

    /// Checks the edges and attributes of a graph.
    private static func graphFindings(_ graph: RuleGraph, variables: Set<String>, owner: String) -> [SourceDiagnostic] {
        var findings: [SourceDiagnostic] = []
        for edge in graph.edges {
            guard let source = graph.node(edge.source), graph.contains(edge.target) else {
                findings.append(.henshin(.error, .invalidEdgeType, "An edge '\(edge.type.name)' of \(owner) leaves its graph"))
                continue
            }
            if source.type.getEReference(name: edge.type.name) == nil {
                findings.append(
                    .henshin(.error, .invalidEdgeType, "Class '\(source.type.name)' of \(owner) has no reference '\(edge.type.name)'"))
            }
            if edge.index != nil {
                findings.append(.henshin(.warning, .edgeIndexIgnored, "The position of an edge '\(edge.type.name)' of \(owner) is not interpreted"))
            }
        }
        for node in graph.nodes {
            for attribute in node.attributes {
                if node.type.getEAttribute(name: attribute.feature.name) == nil {
                    findings.append(
                        .henshin(.error, .invalidAttributeType, "Class '\(node.type.name)' of \(owner) has no attribute '\(attribute.feature.name)'"))
                }
                findings += expressionFindings(attribute.value, variables: variables, owner: owner)
            }
        }
        return findings
    }

    /// Checks that an expression can be translated.
    private static func expressionFindings(_ text: String, variables: Set<String>, owner: String) -> [SourceDiagnostic] {
        do {
            _ = try JavaScriptTranslator(variables: variables).translate(text)
            return []
        } catch {
            let code: HenshinDiagnosticCode = error.description.contains("is not a parameter") ? .unknownVariable : .unsupportedExpression
            return [.henshin(.error, code, "In \(owner): \(error.description)")]
        }
    }

    /// Checks that parameter names are unique.
    private static func parameterFindings(_ parameters: [UnitParameter], owner: String) -> [SourceDiagnostic] {
        var seen = Set<String>()
        return parameters.compactMap { parameter in
            seen.insert(parameter.name).inserted
                ? nil : .henshin(.error, .duplicateParameter, "\(owner.capitalisedFirst) declares parameter '\(parameter.name)' twice")
        }
    }
}

extension String {
    /// The text with its first character in upper case.
    var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}
