//
//  HenshinValidator+CleanUp.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// The checks that correspond to Henshin's clean-up operation.
///
/// Henshin's editor offers a clean-up operation for modules, units and rules that removes or
/// repairs inconsistent elements (Strüber et al., "[Henshin: A Usability-Focused Framework
/// for EMF Model Transformation Development](https://doi.org/10.1007/978-3-319-61470-0_12)",
/// ICGT 2017). The validator reports, as
/// warnings, each element that the operation would change, so that the problem can be
/// fixed in the document.
extension HenshinValidator {
    // MARK: - Rules

    /// Checks a rule or multi-rule for what Henshin's clean-up would repair.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - kernel: For a multi-rule, its kernel rule; `nil` otherwise.
    ///   - owner: The description of the rule in messages, such as `rule 'deposit'`.
    /// - Returns: The findings.
    static func cleanUpFindings(_ rule: Rule, kernel: Rule?, owner: String) -> [SourceDiagnostic] {
        var findings: [SourceDiagnostic] = []
        let subject = owner.capitalisedFirst
        if rule.rhs.formula != nil {
            findings.append(
                .henshin(.warning, .rightSideFormula, "The right-hand side of \(owner) has an application condition, which is never checked"))
        }
        findings += mappingListFindings(rule.mappings, signature: [(rule.lhs, rule.rhs)], kind: "mapping", owner: owner)
        for mapping in rule.mappings {
            if let origin = rule.lhs.node(mapping.origin), let image = rule.rhs.node(mapping.image), !sameClass(origin.type, image.type) {
                findings.append(
                    .henshin(.warning, .mappingTypeMismatch,
                        "\(subject) maps a node of class '\(origin.type.name)' to a node of class '\(image.type.name)'"))
            }
        }
        if let kernel {
            let signature = [(kernel.lhs, rule.lhs), (kernel.rhs, rule.rhs)]
            for mapping in rule.multiMappings {
                guard let (origin, image) = endpoints(of: mapping, in: signature) else {
                    findings.append(
                        .henshin(.warning, .invalidMultiMapping,
                            "A multi-mapping of \(owner) does not lead from a side of its kernel rule '\(kernel.name)' to the same side of the multi-rule"))
                    continue
                }
                if !sameClass(origin.type, image.type) {
                    findings.append(
                        .henshin(.warning, .mappingTypeMismatch,
                            "\(subject) maps a node of class '\(origin.type.name)' of its kernel rule to a node of class '\(image.type.name)'"))
                }
            }
            findings += ambiguityFindings(rule.multiMappings, graphs: [rule.lhs, rule.rhs], kind: "multi-mapping", owner: owner)
            findings += multiRuleEdgeFindings(kernel: kernel, multiRule: rule, owner: owner)
            for parameter in rule.parameters {
                guard let declared = kernel.parameter(named: parameter.name) else { continue }
                let typesDiffer = parameter.typeName != nil && declared.typeName != nil && parameter.typeName != declared.typeName
                if parameter.kind != declared.kind || typesDiffer {
                    findings.append(
                        .henshin(.warning, .multiRuleParameterMismatch,
                            "\(subject) declares parameter '\(parameter.name)' with another kind or type than its kernel rule '\(kernel.name)'"))
                }
            }
        } else if !rule.multiMappings.isEmpty {
            findings.append(.henshin(.warning, .invalidMultiMapping, "\(subject) has multi-mappings but is not a multi-rule"))
        }
        forEachCondition(in: rule.lhs) { condition, host in
            for mapping in condition.mappings {
                guard let origin = host.node(mapping.origin), let image = condition.conclusion.node(mapping.image) else {
                    findings.append(
                        .henshin(.warning, .invalidConditionMapping,
                            "A mapping of a nested condition of \(owner) does not lead from the graph that holds the condition to its conclusion"))
                    continue
                }
                if !sameClass(origin.type, image.type) && !origin.type.isSuperTypeOf(image.type) && !image.type.isSuperTypeOf(origin.type) {
                    findings.append(
                        .henshin(.warning, .mappingTypeMismatch,
                            "A nested condition of \(owner) maps a node of class '\(origin.type.name)' to a node of the unrelated class '\(image.type.name)'"))
                }
            }
            findings += ambiguityFindings(condition.mappings, graphs: [condition.conclusion], kind: "condition mapping", owner: owner)
            if isTrue(condition, host: host) {
                findings.append(.henshin(.warning, .trivialCondition, "A nested condition of \(owner) always holds"))
            } else if isFalse(condition) {
                findings.append(.henshin(.warning, .trivialCondition, "A nested condition of \(owner) can never hold"))
            }
        }
        for multiRule in rule.multiRules where isRedundant(multiRule, kernel: rule) {
            findings.append(
                .henshin(.warning, .redundantMultiRule, "Multi-rule '\(multiRule.name)' of \(owner) adds nothing to its kernel rule"))
        }
        return findings
    }

    /// Checks that a list of mappings leads only between the given pairs of graphs and that
    /// no node has two images in one graph or two origins.
    ///
    /// Mappings that lead between other graphs are left to the caller, which reports them
    /// with the appropriate severity.
    private static func mappingListFindings(
        _ mappings: [NodeMapping], signature: [(RuleGraph, RuleGraph)], kind: String, owner: String
    ) -> [SourceDiagnostic] {
        ambiguityFindings(mappings, graphs: signature.map(\.1), kind: kind, owner: owner)
    }

    /// Checks that no node has two images in the same graph and no node two origins.
    private static func ambiguityFindings(_ mappings: [NodeMapping], graphs: [RuleGraph], kind: String, owner: String) -> [SourceDiagnostic] {
        var findings: [SourceDiagnostic] = []
        for graph in graphs {
            let inGraph = mappings.filter { graph.contains($0.image) }
            var origins = Set<NodeID>()
            var images = Set<NodeID>()
            for mapping in inGraph {
                if !origins.insert(mapping.origin).inserted {
                    findings.append(.henshin(.warning, .ambiguousMapping, "A node of \(owner) has two \(kind) images in the same graph"))
                }
                if !images.insert(mapping.image).inserted {
                    findings.append(.henshin(.warning, .ambiguousMapping, "A node of \(owner) is the \(kind) image of two nodes"))
                }
            }
        }
        return findings
    }

    /// The nodes that a mapping connects, if it leads between one of the given pairs of
    /// graphs.
    private static func endpoints(of mapping: NodeMapping, in signature: [(RuleGraph, RuleGraph)]) -> (RuleNode, RuleNode)? {
        for (from, to) in signature {
            if let origin = from.node(mapping.origin), let image = to.node(mapping.image) { return (origin, image) }
        }
        return nil
    }

    /// Visits every nested condition of a graph's formula, including those in the
    /// conclusions, together with the graph that holds it.
    static func forEachCondition(in graph: RuleGraph, _ visit: (NestedCondition, RuleGraph) -> Void) {
        /// Visits the conditions of a formula held by a graph.
        func walk(_ formula: Formula?, host: RuleGraph) {
            switch formula {
            case .condition(let condition)?:
                visit(condition, host)
                walk(condition.conclusion.formula, host: condition.conclusion)
            case .not(let child)?:
                walk(child, host: host)
            case .and(let left, let right)?, .or(let left, let right)?, .xor(let left, let right)?:
                walk(left, host: host)
                walk(right, host: host)
            case .true?, nil:
                break
            }
        }
        walk(graph.formula, host: graph)
    }

    // MARK: - Trivial conditions and redundant multi-rules

    /// Whether a formula always holds, as Henshin decides it syntactically.
    private static func isTrue(_ formula: Formula, host: RuleGraph) -> Bool {
        switch formula {
        case .true: return true
        case .condition(let condition): return isTrue(condition, host: host)
        case .not(let child): return isFalse(child, host: host)
        case .and(let left, let right): return isTrue(left, host: host) && isTrue(right, host: host)
        case .or(let left, let right): return isTrue(left, host: host) || isTrue(right, host: host)
        case .xor(let left, let right):
            return (isTrue(left, host: host) && isFalse(right, host: host)) || (isFalse(left, host: host) && isTrue(right, host: host))
        }
    }

    /// Whether a formula can never hold, as Henshin decides it syntactically.
    private static func isFalse(_ formula: Formula, host: RuleGraph) -> Bool {
        switch formula {
        case .true: return false
        case .condition(let condition): return isFalse(condition)
        case .not(let child): return isTrue(child, host: host)
        case .and(let left, let right): return isFalse(left, host: host) || isFalse(right, host: host)
        case .or(let left, let right): return isFalse(left, host: host) && isFalse(right, host: host)
        case .xor(let left, let right):
            return (isTrue(left, host: host) && isTrue(right, host: host)) || (isFalse(left, host: host) && isFalse(right, host: host))
        }
    }

    /// Whether a nested condition always holds: its conclusion repeats the part of its host
    /// graph that it maps, and its own formula always holds.
    private static func isTrue(_ condition: NestedCondition, host: RuleGraph) -> Bool {
        if let formula = condition.conclusion.formula, !isTrue(formula, host: condition.conclusion) { return false }
        return isOnto(condition.mappings, image: condition.conclusion, origins: [host])
    }

    /// Whether a nested condition can never hold because its conclusion's formula cannot.
    private static func isFalse(_ condition: NestedCondition) -> Bool {
        guard let formula = condition.conclusion.formula else { return false }
        return isFalse(formula, host: condition.conclusion)
    }

    /// Whether every node, attribute and edge of a graph is the image of a mapping from one
    /// of the origin graphs, with the same class, value and reference.
    private static func isOnto(_ mappings: [NodeMapping], image: RuleGraph, origins: [RuleGraph]) -> Bool {
        /// The origin of a node of the image graph, with the graph that holds it.
        func origin(of node: NodeID) -> (RuleNode, RuleGraph)? {
            for mapping in mappings where mapping.image == node {
                for graph in origins { if let found = graph.node(mapping.origin) { return (found, graph) } }
            }
            return nil
        }
        for node in image.nodes {
            guard let (original, _) = origin(of: node.id), sameClass(original.type, node.type) else { return false }
            for attribute in node.attributes {
                guard let source = original.attribute(named: attribute.feature.name),
                    source.value.trimmingCharacters(in: .whitespaces) == attribute.value.trimmingCharacters(in: .whitespaces)
                else { return false }
            }
        }
        for edge in image.edges {
            guard let (source, graph) = origin(of: edge.source), let (target, _) = origin(of: edge.target),
                graph.edges.contains(where: { $0.source == source.id && $0.target == target.id && sameReference($0.type, edge.type) })
            else { return false }
        }
        return true
    }

    /// Whether a multi-rule repeats its kernel rule exactly, so that Henshin's clean-up
    /// removes it.
    private static func isRedundant(_ multiRule: Rule, kernel: Rule) -> Bool {
        guard multiRule.multiRules.allSatisfy({ isRedundant($0, kernel: multiRule) }),
            isOnto(multiRule.multiMappings, image: multiRule.lhs, origins: [kernel.lhs]),
            isOnto(multiRule.multiMappings, image: multiRule.rhs, origins: [kernel.rhs])
        else { return false }
        var allTrue = true
        forEachCondition(in: multiRule.lhs) { condition, host in
            if !isTrue(condition, host: host) { allTrue = false }
        }
        return allTrue
    }

    // MARK: - Multi-rule edges

    /// Checks that a multi-rule treats the copies of its kernel's edges as the kernel does.
    ///
    /// A kernel edge that is deleted must not be preserved by the multi-rule, and one that is
    /// preserved must not be deleted; likewise for created edges.
    private static func multiRuleEdgeFindings(kernel: Rule, multiRule: Rule, owner: String) -> [SourceDiagnostic] {
        var findings: [SourceDiagnostic] = []
        let subject = owner.capitalisedFirst
        let multi = multiRule.multiMappings
        for edge in kernel.lhs.edges {
            guard let copy = image(of: edge, from: kernel.lhs, through: multi, in: multiRule.lhs) else { continue }
            let kernelKeeps = image(of: edge, from: kernel.lhs, through: kernel.mappings, in: kernel.rhs) != nil
            let multiKeeps = image(of: copy, from: multiRule.lhs, through: multiRule.mappings, in: multiRule.rhs) != nil
            let multiCanKeep = multiRule.image(of: copy.source) != nil && multiRule.image(of: copy.target) != nil
            if kernelKeeps != multiKeeps && (multiKeeps || multiCanKeep) {
                findings.append(
                    .henshin(.warning, .multiRuleEdgeMismatch,
                        "\(subject) \(multiKeeps ? "preserves" : "deletes") an edge '\(edge.type.name)' that its kernel rule '\(kernel.name)' \(kernelKeeps ? "preserves" : "deletes")"))
            }
        }
        for edge in kernel.rhs.edges {
            guard let copy = image(of: edge, from: kernel.rhs, through: multi, in: multiRule.rhs) else { continue }
            let kernelCreates = origin(of: edge, in: kernel.lhs, through: kernel.mappings) == nil
            let multiCreates = origin(of: copy, in: multiRule.lhs, through: multiRule.mappings) == nil
            let multiCanPreserve = multiRule.origin(of: copy.source) != nil && multiRule.origin(of: copy.target) != nil
            if kernelCreates && !multiCreates {
                findings.append(
                    .henshin(.warning, .multiRuleEdgeMismatch,
                        "\(subject) preserves an edge '\(edge.type.name)' that its kernel rule '\(kernel.name)' creates"))
            } else if !kernelCreates && multiCreates && multiCanPreserve {
                findings.append(
                    .henshin(.warning, .multiRuleEdgeMismatch,
                        "\(subject) creates an edge '\(edge.type.name)' that its kernel rule '\(kernel.name)' preserves"))
            }
        }
        return findings
    }

    /// The edge of a graph that corresponds to an edge of another graph under a list of
    /// mappings: the edge of the same reference between the images of its ends.
    private static func image(of edge: RuleEdge, from graph: RuleGraph, through mappings: [NodeMapping], in target: RuleGraph) -> RuleEdge? {
        /// The image of a node in the target graph.
        func image(_ node: NodeID) -> NodeID? { mappings.first { $0.origin == node && target.contains($0.image) }?.image }
        guard graph.contains(edge.source), let source = image(edge.source), let destination = image(edge.target) else { return nil }
        return target.edges.first { $0.source == source && $0.target == destination && sameReference($0.type, edge.type) }
    }

    /// The edge of a graph whose image under a list of mappings is an edge.
    private static func origin(of edge: RuleEdge, in graph: RuleGraph, through mappings: [NodeMapping]) -> RuleEdge? {
        /// The origin of a node in the graph.
        func origin(_ node: NodeID) -> NodeID? { mappings.first { $0.image == node && graph.contains($0.origin) }?.origin }
        guard let source = origin(edge.source), let destination = origin(edge.target) else { return nil }
        return graph.edges.first { $0.source == source && $0.target == destination && sameReference($0.type, edge.type) }
    }

    // MARK: - Parameters

    /// Checks that every parameter of a rule and its multi-rules is used somewhere in the
    /// rule: as the name of a node, in an attribute value, edge position or attribute
    /// condition of any of its graphs or multi-rules.
    ///
    /// Henshin's clean-up removes parameters that name no node and are no whole attribute
    /// value; parameters that expressions use are counted as used here, so that a value
    /// that only takes part in a computation is not reported.
    static func unusedParameterFindings(of rule: Rule) -> [SourceDiagnostic] {
        var used = Set<String>()
        collectUsedNames(of: rule, into: &used)
        var findings: [SourceDiagnostic] = []
        /// Reports the unused parameters of a rule and its multi-rules.
        func check(_ rule: Rule) {
            for parameter in rule.parameters where !used.contains(parameter.name) {
                findings.append(
                    .henshin(.warning, .unusedParameter, "Rule '\(rule.name)' declares parameter '\(parameter.name)' but uses it nowhere"))
            }
            rule.multiRules.forEach(check)
        }
        check(rule)
        return findings
    }

    /// Collects the names that a rule and its multi-rules use.
    private static func collectUsedNames(of rule: Rule, into used: inout Set<String>) {
        for graph in [rule.lhs, rule.rhs] + conclusions(of: rule.lhs.formula) {
            for node in graph.nodes {
                if let name = node.name { used.insert(name) }
                for attribute in node.attributes { used.formUnion(identifiers(in: attribute.value)) }
            }
            for edge in graph.edges { if let index = edge.index { used.formUnion(identifiers(in: index)) } }
        }
        for condition in rule.attributeConditions { used.formUnion(identifiers(in: condition.conditionText)) }
        for multiRule in rule.multiRules { collectUsedNames(of: multiRule, into: &used) }
    }

    /// Checks that every parameter of a composite unit takes part in one of its parameter
    /// mappings or in its number of iterations.
    static func unusedParameterFindings(of unit: TransformationUnit) -> [SourceDiagnostic] {
        var used = Set<String>()
        for mapping in unit.parameterMappings {
            for end in [mapping.source, mapping.target] where end.unit == unit.id { used.insert(end.name) }
        }
        if case .iterated(_, let iterations, _, _) = unit.kind { used.formUnion(identifiers(in: iterations)) }
        return unit.parameters.filter { !used.contains($0.name) }.map { parameter in
            .henshin(.warning, .unusedParameter, "Unit '\(unit.name)' declares parameter '\(parameter.name)' but uses it nowhere")
        }
    }

    /// Checks that the parameter mappings of a unit lead between the unit and its direct
    /// sub-units, and between parameters that those units declare.
    static func parameterMappingFindings(_ unit: TransformationUnit, in module: HenshinModule) -> [SourceDiagnostic] {
        let allowed = Set([unit.id] + unit.kind.subUnits)
        var findings: [SourceDiagnostic] = []
        for mapping in unit.parameterMappings {
            for end in [mapping.source, mapping.target] {
                guard allowed.contains(end.unit), let owner = module.unit(end.unit) else {
                    findings.append(
                        .henshin(.warning, .invalidParameterMapping,
                            "A parameter mapping of unit '\(unit.name)' refers to a unit that is not the unit itself or one of its direct sub-units"))
                    continue
                }
                if owner.parameter(named: end.name) == nil {
                    findings.append(
                        .henshin(.warning, .invalidParameterMapping,
                            "A parameter mapping of unit '\(unit.name)' refers to parameter '\(end.name)', which '\(owner.name)' does not declare"))
                }
            }
        }
        return findings
    }

    /// The names that an expression refers to, excluding the names of properties and
    /// methods after a dot.
    ///
    /// Text that is not a JavaScript expression counts as a single name.
    static func identifiers(in expression: String) -> Set<String> {
        var lexer = ScriptLexer(expression)
        guard let tokens = try? lexer.tokens() else { return [expression.trimmingCharacters(in: .whitespaces)] }
        var names = Set<String>()
        for (index, token) in tokens.enumerated() {
            guard case .identifier(let name) = token else { continue }
            if index > 0, tokens[index - 1] == .symbol(".") { continue }
            names.insert(name)
        }
        return names
    }

    // MARK: - Imports

    /// Checks that a module imports exactly the metamodel packages of its node classes.
    ///
    /// Node classes whose package is not among the given packages are not considered.
    static func importFindings(_ module: HenshinModule, metamodels: [EPackage]) -> [SourceDiagnostic] {
        let packages = metamodels.flatMap { [$0] + nestedPackages(of: $0) }
        var required: [String] = []
        /// Records the package of a class.
        func require(_ type: EClass) {
            guard let package = packages.first(where: { package in package.eClassifiers.contains { ($0 as? EClass)?.id == type.id } }),
                !required.contains(package.nsURI)
            else { return }
            required.append(package.nsURI)
        }
        /// Records the packages of the node classes of a rule and its multi-rules.
        func visit(_ rule: Rule) {
            for graph in [rule.lhs, rule.rhs] + conclusions(of: rule.lhs.formula) { graph.nodes.forEach { require($0.type) } }
            rule.multiRules.forEach(visit)
        }
        module.rules.forEach(visit)
        guard !required.isEmpty else { return [] }
        var findings: [SourceDiagnostic] = []
        for uri in module.imports where !required.contains(uri) {
            findings.append(.henshin(.warning, .unusedImport, "The module imports the package '\(uri)', which none of its nodes uses"))
        }
        for uri in required where !module.imports.contains(uri) {
            findings.append(.henshin(.warning, .missingImport, "The module uses classes of the package '\(uri)' without importing it"))
        }
        return findings
    }

    /// The packages nested in a package, depth first.
    private static func nestedPackages(of package: EPackage) -> [EPackage] {
        package.eSubpackages.flatMap { [$0] + nestedPackages(of: $0) }
    }

    // MARK: - Identity

    /// Whether two classes are the same, by identity or, for copies of a metamodel, by name.
    static func sameClass(_ first: EClass, _ second: EClass) -> Bool {
        first.id == second.id || first.name == second.name
    }

    /// Whether two references are the same, by identity or by name.
    static func sameReference(_ first: EReference, _ second: EReference) -> Bool {
        first.id == second.id || first.name == second.name
    }
}
