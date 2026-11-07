//
//  HenshinTextWriter.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// The Henshin Text that describes a module, with what could not be expressed.
public struct HenshinTextWriting: Sendable {
    /// The document.
    public var text: String

    /// What the writer could not express or had to change, such as positions of edges or
    /// parameters added so that every call passes all arguments.
    public var diagnostics: [SourceDiagnostic]

    /// Whether the module was written without losing anything that changes its meaning.
    public var isFaithful: Bool { !diagnostics.contains { $0.severity != .information } }
}

/// The writing of modules as Henshin Text.
extension HenshinText {
    /// Writes a module as a Henshin Text document in canonical form.
    ///
    /// Rules are written as single graphs whose nodes, edges and attributes carry actions;
    /// application conditions are written as matching formulas over condition graphs; and
    /// units as calls within control structures. Reading the document back gives a module
    /// with the same behaviour, and writing that module again gives the same document.
    ///
    /// - Parameters:
    ///   - module: The module.
    ///   - packages: The metamodel packages of the module's classes, with which imports and
    ///     class names are written.
    /// - Returns: The document and the diagnostics of what could not be expressed.
    public static func write(_ module: HenshinModule, packages: [EPackage]) -> HenshinTextWriting {
        var writer = HenshinTextWriter(module: module, packages: packages)
        return writer.write()
    }

    /// Writes a module as a Henshin Text document in canonical form, with the metamodels that
    /// a resource set knows.
    ///
    /// - Parameters:
    ///   - module: The module.
    ///   - resourceSet: The resource set whose metamodels the module uses.
    /// - Returns: The document and the diagnostics of what could not be expressed.
    public static func write(_ module: HenshinModule, resourceSet: ResourceSet) async -> HenshinTextWriting {
        write(module, packages: await HenshinTextLoader.knownPackages(in: resourceSet))
    }
}

/// Writes a ``HenshinModule`` as Henshin Text.
struct HenshinTextWriter {
    /// Shorthand for the keywords.
    private typealias Keyword = HenshinTextConstants.Keyword

    /// The module.
    private let module: HenshinModule
    /// The available packages with their qualified names.
    private let packages: [(name: String, package: EPackage)]
    /// The imported packages with their qualified names.
    private var imported: [(name: String, package: EPackage)] = []
    /// The problems found so far.
    private var diagnostics: [SourceDiagnostic] = []
    /// The document written so far.
    private var output = ""
    /// The declared or inferred types of the unit parameters.
    private var parameterTypes: [ParameterReference: String] = [:]

    /// Creates a writer.
    ///
    /// - Parameters:
    ///   - module: The module.
    ///   - packages: The metamodel packages of the module's classes.
    init(module: HenshinModule, packages: [EPackage]) {
        self.module = module
        var named: [(String, EPackage)] = []
        /// Records a package and its nested packages under their qualified names.
        func record(_ package: EPackage, prefix: String) {
            let name = prefix.isEmpty ? package.name : prefix + String(HenshinTextConstants.qualifier) + package.name
            named.append((name, package))
            for nested in package.eSubpackages { record(nested, prefix: name) }
        }
        for package in packages { record(package, prefix: "") }
        self.packages = named
    }

    /// Reports a problem.
    private mutating func report(_ severity: DiagnosticSeverity, _ code: HenshinTextDiagnosticCode, _ message: String) {
        diagnostics.append(.henshinText(severity, code, message))
    }

    /// Appends an indented line.
    private mutating func line(_ indent: Int, _ text: String) {
        output += String(repeating: "\t", count: indent) + text + "\n"
    }

    /// Writes the module.
    ///
    /// - Returns: The document and its diagnostics.
    mutating func write() -> HenshinTextWriting {
        writeImports()
        inferParameterTypes()
        var names = Set<String>()
        for unit in module.units where !names.insert(unit.name).inserted {
            report(.error, .notExpressible, "Two units are named '\(unit.name)'; Henshin Text refers to units by name")
        }
        for unit in module.units {
            output += "\n"
            if let description = unit.description, !description.isEmpty {
                for text in description.split(whereSeparator: \.isNewline) { line(0, "// " + text) }
            }
            if !unit.isActivated {
                report(.warning, .notExpressible, "Henshin Text cannot deactivate '\(unit.name)'; it is written as active")
            }
            if let rule = unit.rule { writeRule(rule, unit: unit.id) } else { writeUnit(unit) }
        }
        return HenshinTextWriting(text: output, diagnostics: diagnostics)
    }

    // MARK: - Names

    /// A name as an identifier, escaped if it is a keyword.
    private func identifier(_ name: String) -> String {
        HenshinTextConstants.keywords.contains(name) ? String(HenshinTextConstants.escape) + name : name
    }

    /// Whether a text is a valid identifier of Henshin Text.
    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first.isASCII, first == "_" || first.properties.isAlphabetic else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || $0.properties.numericType != nil) }
    }

    /// The package that holds a class, with its qualified name.
    ///
    /// The class is looked for by identity and, for a copy of the metamodel loaded
    /// separately, by name, in the imported packages first.
    private func package(of type: EClass) -> (name: String, package: EPackage)? {
        packages.first { entry in entry.package.eClassifiers.contains { ($0 as? EClass)?.id == type.id } }
            ?? imported.first { $0.package.getEClass(type.name) != nil }
            ?? packages.first { $0.package.getEClass(type.name) != nil }
    }

    /// The name of a class as Henshin Text refers to it: simple if an imported package holds
    /// it and no other imported package has a class of that name, else qualified.
    private mutating func className(_ type: EClass) -> String {
        let owners = imported.filter { $0.package.getEClass(type.name) != nil }
        if owners.count == 1, let owner = package(of: type), owner.package.nsURI == owners[0].package.nsURI { return identifier(type.name) }
        guard let owner = package(of: type) else {
            report(.warning, .notExpressible, "The package of class '\(type.name)' is unknown; its simple name is written")
            return identifier(type.name)
        }
        return owner.name.split(separator: HenshinTextConstants.qualifier).map { identifier(String($0)) }.joined(separator: ".") + "."
            + identifier(type.name)
    }

    // MARK: - Imports and parameters

    /// Writes the metamodel imports.
    private mutating func writeImports() {
        for uri in module.imports {
            guard let entry = packages.first(where: { $0.package.nsURI == uri }) else {
                report(.warning, .notExpressible, "The imported package '\(uri)' is unknown and is left out")
                continue
            }
            if !imported.contains(where: { $0.package.nsURI == uri }) { imported.append(entry) }
        }
        /// Imports the packages of the node classes of a rule that are not yet imported.
        func importClasses(of rule: Rule, into writer: inout HenshinTextWriter) {
            for graph in [rule.lhs, rule.rhs] + HenshinValidator.conclusions(of: rule.lhs.formula) {
                for node in graph.nodes {
                    guard let owner = writer.package(of: node.type), !writer.imported.contains(where: { $0.package.nsURI == owner.package.nsURI }) else { continue }
                    writer.imported.append(owner)
                    writer.report(.information, .adjusted, "The package '\(owner.name)' of class '\(node.type.name)' is imported")
                }
            }
            for multiRule in rule.multiRules { importClasses(of: multiRule, into: &writer) }
        }
        for rule in module.rules { importClasses(of: rule, into: &self) }
        if imported.isEmpty { report(.error, .notExpressible, "The module imports no known metamodel package") }
        for entry in imported {
            line(0, "\(Keyword.ePackageImport) " + entry.name.split(separator: HenshinTextConstants.qualifier).map { identifier(String($0)) }.joined(separator: "."))
        }
    }

    /// Infers the types of untyped parameters.
    ///
    /// A rule parameter that is the whole value of an attribute takes the attribute's data
    /// type; a unit parameter that an iteration count uses is an integer; and any parameter
    /// takes the type of a parameter that it is mapped to.
    private mutating func inferParameterTypes() {
        for unit in module.units {
            for parameter in unit.parameters {
                let reference = ParameterReference(unit: unit.id, name: parameter.name)
                if let type = parameter.typeName {
                    parameterTypes[reference] = type
                } else if let rule = unit.rule, let type = attributeType(of: parameter.name, in: rule) {
                    parameterTypes[reference] = type
                } else if case .iterated(_, let iterations, _, _) = unit.kind, HenshinValidator.identifiers(in: iterations).contains(parameter.name) {
                    parameterTypes[reference] = EcoreDataType.eInt.rawValue
                }
            }
        }
        var changed = true
        while changed {
            changed = false
            for unit in module.units {
                for mapping in unit.parameterMappings {
                    for (from, to) in [(mapping.source, mapping.target), (mapping.target, mapping.source)] where parameterTypes[to] == nil {
                        if let type = parameterTypes[from] {
                            parameterTypes[to] = type
                            changed = true
                        }
                    }
                }
            }
        }
    }

    /// The data type of the attributes whose whole value is a parameter, in a rule and its
    /// multi-rules, if Henshin Text can name it.
    private func attributeType(of name: String, in rule: Rule) -> String? {
        for graph in [rule.lhs, rule.rhs] + HenshinValidator.conclusions(of: rule.lhs.formula) {
            for node in graph.nodes {
                for attribute in node.attributes where attribute.value.trimmingCharacters(in: .whitespaces) == name {
                    if HenshinTextConstants.dataTypes.contains(attribute.feature.eType.name) { return attribute.feature.eType.name }
                }
            }
        }
        return rule.multiRules.lazy.compactMap { attributeType(of: name, in: $0) }.first
    }

    /// A parameter declaration.
    private mutating func parameter(_ parameter: UnitParameter, of unit: UnitID?, owner: String) -> String {
        let kind = parameter.kind == .unknown ? "" : parameter.kind.rawValue + " "
        var type = parameter.typeName ?? unit.flatMap { parameterTypes[ParameterReference(unit: $0, name: parameter.name)] }
        if type == nil {
            report(
                .information, .adjusted,
                "Parameter '\(parameter.name)' of \(owner) has no type; it is written as \(HenshinTextConstants.fallbackParameterType)")
            type = HenshinTextConstants.fallbackParameterType
        }
        return kind + identifier(parameter.name) + ":" + typeName(type ?? HenshinTextConstants.fallbackParameterType, owner: owner)
    }

    /// The name of a parameter type: a data type keyword or the name of a class.
    private mutating func typeName(_ name: String, owner: String) -> String {
        if HenshinTextConstants.dataTypes.contains(name) { return name }
        for entry in imported + packages {
            if let type = entry.package.getEClass(name) { return className(type) }
        }
        report(
            .warning, .notExpressible,
            "Henshin Text cannot name the parameter type '\(name)' of \(owner); it is written as \(HenshinTextConstants.fallbackParameterType)")
        return HenshinTextConstants.fallbackParameterType
    }

    // MARK: - Rules

    /// The names of the nodes of a rule and its multi-rules and condition graphs.
    struct Naming {
        /// The names of the rule parameters, which nodes only use if they already have them.
        var reserved: Set<String>
        /// The names given so far.
        var used: Set<String> = []
        /// The names of the nodes, by identity.
        var names: [NodeID: String] = [:]
        /// The names of the condition graphs given so far.
        var graphs: Set<String> = []
    }

    /// Gives nodes a unique name, preferring the name they have.
    ///
    /// - Returns: The name.
    private mutating func name(_ ids: [NodeID], preferred: String?, type: EClass, naming: inout Naming) -> String {
        var name: String
        if let preferred, Self.isIdentifier(preferred), !naming.used.contains(preferred) {
            name = preferred
        } else {
            let base = type.name.prefix(1).lowercased() + type.name.dropFirst()
            let stem = Self.isIdentifier(base) ? base : "node"
            var counter = 1
            name = stem
            while naming.used.contains(name) || naming.reserved.contains(name) || HenshinTextConstants.keywords.contains(name) {
                counter += 1
                name = "\(stem)\(counter)"
            }
            if let preferred {
                report(.information, .adjusted, "A node named '\(preferred)' is renamed '\(name)' so that its name is unique")
            }
        }
        naming.used.insert(name)
        for id in ids { naming.names[id] = name }
        return name
    }

    /// Writes a rule.
    private mutating func writeRule(_ rule: Rule, unit: UnitID) {
        var naming = Naming(reserved: Set(rule.parameters.map(\.name)))
        let owner = "rule '\(rule.name)'"
        let parameters = rule.parameters.map { parameter($0, of: unit, owner: owner) }
        line(0, "\(Keyword.rule) \(identifier(rule.name))(\(parameters.joined(separator: ", "))) {")
        writeBody(rule, kernel: nil, naming: &naming, scope: Set(rule.parameters.map(\.name)), indent: 1)
        line(0, "}")
    }

    /// Writes the elements of a rule or multi-rule.
    private mutating func writeBody(_ rule: Rule, kernel: Rule?, naming: inout Naming, scope: Set<String>, indent: Int) {
        let owner = "rule '\(rule.name)'"
        for javaImport in rule.javaImports { line(indent, "\(Keyword.javaImport) \(javaImport)") }
        if !rule.checkDangling { line(indent, "\(Keyword.checkDangling) \(Keyword.false)") }
        if !rule.injectiveMatching { line(indent, "\(Keyword.injectiveMatching) \(Keyword.false)") }
        if !rule.attributeConditions.isEmpty {
            let conditions = rule.attributeConditions.map { expression($0.conditionText, scope: scope, owner: owner) }
            line(indent, "\(Keyword.conditions) [" + conditions.joined(separator: ", ") + "]")
        }
        line(indent, "\(Keyword.graph) {")
        let inner = indent + 1
        var copiedLeft = Set<NodeID>()
        var copiedRight = Set<NodeID>()
        if let kernel {
            for mapping in rule.multiMappings {
                guard let name = naming.names[mapping.origin] else { continue }
                if rule.lhs.contains(mapping.image), kernel.lhs.contains(mapping.origin) {
                    copiedLeft.insert(mapping.image)
                    naming.names[mapping.image] = name
                } else if rule.rhs.contains(mapping.image), kernel.rhs.contains(mapping.origin) {
                    copiedRight.insert(mapping.image)
                    naming.names[mapping.image] = name
                }
            }
            let missing = kernel.lhs.nodes.filter { node in !rule.multiMappings.contains { $0.origin == node.id } }
            if !missing.isEmpty {
                report(.information, .adjusted, "Multi-rule '\(rule.name)' receives all nodes of its kernel rule '\(kernel.name)'")
            }
            let extra = rule.parameters.filter { parameter in !scope.contains(parameter.name) }
            if !extra.isEmpty {
                report(.warning, .notExpressible, "Multi-rule '\(rule.name)' takes the parameters of its kernel rule; its own are left out")
            }
        }
        let ownLeft = rule.lhs.nodes.filter { !copiedLeft.contains($0.id) }
        let ownRight = rule.rhs.nodes.filter { !copiedRight.contains($0.id) }
        var preserved: [(RuleNode, RuleNode)] = []
        var deleted: [RuleNode] = []
        for node in ownLeft {
            if let imageID = rule.image(of: node.id), let image = ownRight.first(where: { $0.id == imageID }) {
                preserved.append((node, image))
            } else {
                deleted.append(node)
            }
        }
        let created = ownRight.filter { node in !preserved.contains { $0.1.id == node.id } }
        for (left, right) in preserved { _ = name([left.id, right.id], preferred: left.name ?? right.name, type: left.type, naming: &naming) }
        for node in created { _ = name([node.id], preferred: node.name, type: node.type, naming: &naming) }
        for node in deleted { _ = name([node.id], preferred: node.name, type: node.type, naming: &naming) }
        for (left, right) in preserved {
            if !HenshinValidator.sameClass(left.type, right.type) {
                report(.warning, .notExpressible, "A node of \(owner) changes its class, which Henshin Text cannot express")
            }
            let values = keptAttributes(left, right, scope: scope, owner: owner)
            writeNode(nil, naming.names[left.id] ?? "", left.type, values, indent: inner)
        }
        for node in created {
            writeNode(.create, naming.names[node.id] ?? "", node.type, node.attributes.map { (nil, $0.feature.name, expression($0.value, scope: scope, owner: owner)) }, indent: inner)
        }
        for node in deleted {
            writeNode(.delete, naming.names[node.id] ?? "", node.type, node.attributes.map { (nil, $0.feature.name, expression($0.value, scope: scope, owner: owner)) }, indent: inner)
        }
        if let kernel { writeReuses(rule, kernel: kernel, copiedLeft: copiedLeft, copiedRight: copiedRight, naming: naming, scope: scope, indent: inner) }
        writeEdges(rule, kernel: kernel, naming: naming, indent: inner)
        if let formula = rule.lhs.formula { writeFormula(formula, host: rule.lhs, naming: &naming, scope: scope, owner: owner, indent: inner) }
        if rule.rhs.formula != nil { report(.warning, .notExpressible, "The application condition of the right-hand side of \(owner) is left out") }
        for multiRule in rule.multiRules {
            line(inner, "\(Keyword.multiRule) \(identifier(multiRule.name)) {")
            writeBody(multiRule, kernel: rule, naming: &naming, scope: scope, indent: inner + 1)
            line(inner, "}")
        }
        line(indent, "}")
    }

    /// The attributes of a kept node: kept, changed, deleted and created values.
    private mutating func keptAttributes(_ left: RuleNode, _ right: RuleNode, scope: Set<String>, owner: String) -> [(String?, String, String)] {
        var kept: [(String?, String, String)] = []
        var removed: [(String?, String, String)] = []
        var changed: [(String?, String, String)] = []
        var features = Set<String>()
        for attribute in left.attributes {
            let name = attribute.feature.name
            if !features.insert(name).inserted {
                report(.warning, .notExpressible, "A node of \(owner) has two attributes '\(name)'; Henshin Text allows one")
            }
            let value = expression(attribute.value, scope: scope, owner: owner)
            if let image = right.attribute(named: name) {
                kept.append((nil, name, value))
                if image.value.trimmingCharacters(in: .whitespaces) != attribute.value.trimmingCharacters(in: .whitespaces) {
                    changed.append((Keyword.set, name, expression(image.value, scope: scope, owner: owner)))
                }
            } else {
                removed.append((Keyword.delete, name, value))
            }
        }
        let added = right.attributes.filter { left.attribute(named: $0.feature.name) == nil }.map {
            (Optional(Keyword.create), $0.feature.name, expression($0.value, scope: scope, owner: owner))
        }
        return kept + removed + changed + added
    }

    /// Writes a node declaration with its attributes, each given as its action or `set`, its
    /// feature and its value.
    private mutating func writeNode(_ action: TextAction?, _ name: String, _ type: EClass, _ attributes: [(String?, String, String)], indent: Int) {
        let head = (action.map { $0.rawValue + " " } ?? "") + "\(Keyword.node) \(identifier(name)):\(className(type))"
        writeBlock(head, attributes, indent: indent)
    }

    /// Writes a head followed by braced attributes, or the head alone if there are none.
    private mutating func writeBlock(_ head: String, _ attributes: [(String?, String, String)], indent: Int) {
        guard !attributes.isEmpty else {
            line(indent, head)
            return
        }
        line(indent, head + " {")
        for (prefix, feature, value) in attributes {
            line(indent + 1, (prefix.map { $0 + " " } ?? "") + "\(identifier(feature)) = \(value)")
        }
        line(indent, "}")
    }

    /// Writes the `reuse` elements of a multi-rule for kernel nodes whose copies carry
    /// attributes.
    private mutating func writeReuses(
        _ rule: Rule, kernel: Rule, copiedLeft: Set<NodeID>, copiedRight: Set<NodeID>, naming: Naming, scope: Set<String>, indent: Int
    ) {
        let owner = "rule '\(rule.name)'"
        var written = Set<String>()
        for node in rule.lhs.nodes.filter({ copiedLeft.contains($0.id) }) + rule.rhs.nodes.filter({ copiedRight.contains($0.id) }) {
            guard let name = naming.names[node.id], written.insert(name).inserted else { continue }
            let left = rule.lhs.nodes.first { copiedLeft.contains($0.id) && naming.names[$0.id] == name }
            let right = rule.rhs.nodes.first { copiedRight.contains($0.id) && naming.names[$0.id] == name }
            var values: [(String?, String, String)] = []
            switch (left, right) {
            case (let left?, let right?):
                if rule.image(of: left.id) != right.id {
                    report(.warning, .notExpressible, "Multi-rule '\(rule.name)' treats kernel node '\(name)' differently from its kernel rule")
                }
                for attribute in left.attributes {
                    let value = expression(attribute.value, scope: scope, owner: owner)
                    if let image = right.attribute(named: attribute.feature.name) {
                        if image.value.trimmingCharacters(in: .whitespaces) == attribute.value.trimmingCharacters(in: .whitespaces) {
                            values.append((Keyword.preserve, attribute.feature.name, value))
                        } else {
                            values.append((Keyword.delete, attribute.feature.name, value))
                            values.append((Keyword.create, attribute.feature.name, expression(image.value, scope: scope, owner: owner)))
                        }
                    } else {
                        values.append((Keyword.delete, attribute.feature.name, value))
                    }
                }
                for attribute in right.attributes where left.attribute(named: attribute.feature.name) == nil {
                    values.append((Keyword.create, attribute.feature.name, expression(attribute.value, scope: scope, owner: owner)))
                }
            case (let only?, nil), (nil, let only?):
                values = only.attributes.map { (nil, $0.feature.name, expression($0.value, scope: scope, owner: owner)) }
            case (nil, nil):
                continue
            }
            if !values.isEmpty { writeBlock("\(Keyword.reuse) \(identifier(name))", values, indent: indent) }
        }
    }

    /// Writes the edges of a rule: kept, deleted and created ones, leaving out the copies of
    /// the kernel's edges in a multi-rule.
    private mutating func writeEdges(_ rule: Rule, kernel: Rule?, naming: Naming, indent: Int) {
        /// Whether two edges connect the same names with the same reference.
        func same(_ edge: RuleEdge, _ other: RuleEdge) -> Bool {
            naming.names[edge.source] == naming.names[other.source] && naming.names[edge.target] == naming.names[other.target]
                && HenshinValidator.sameReference(edge.type, other.type)
        }
        var kernelLeft = kernel?.lhs.edges ?? []
        var kernelRight = kernel?.rhs.edges ?? []
        var right = rule.rhs.edges
        var written: [String] = []
        for edge in rule.lhs.edges {
            if let index = kernelLeft.firstIndex(where: { same($0, edge) }) {
                kernelLeft.remove(at: index)
                if let image = right.firstIndex(where: { same($0, edge) }), let copy = kernelRight.firstIndex(where: { same($0, edge) }) {
                    right.remove(at: image)
                    kernelRight.remove(at: copy)
                }
                continue
            }
            if let image = right.firstIndex(where: { same($0, edge) }) {
                right.remove(at: image)
                written.append(edgeText(nil, edge, rule.lhs, naming))
            } else {
                written.append(edgeText(.delete, edge, rule.lhs, naming))
            }
        }
        for edge in right {
            if let copy = kernelRight.firstIndex(where: { same($0, edge) }) {
                kernelRight.remove(at: copy)
                continue
            }
            written.append(edgeText(.create, edge, rule.rhs, naming))
        }
        writeEdgeList(written, indent: indent)
    }

    /// Writes an `edges` list.
    private mutating func writeEdgeList(_ edges: [String], indent: Int) {
        guard !edges.isEmpty else { return }
        line(indent, "\(Keyword.edges) [")
        for (index, edge) in edges.enumerated() { line(indent + 1, edge + (index < edges.count - 1 ? "," : "")) }
        line(indent, "]")
    }

    /// The text of an edge.
    private mutating func edgeText(_ action: TextAction?, _ edge: RuleEdge, _ graph: RuleGraph, _ naming: Naming) -> String {
        if edge.index != nil { report(.warning, .notExpressible, "The position of an edge '\(edge.type.name)' is left out") }
        let source = naming.names[edge.source] ?? ""
        let target = naming.names[edge.target] ?? ""
        if let type = graph.node(edge.source)?.type, type.getEReference(name: edge.type.name) == nil {
            report(.warning, .notExpressible, "Class '\(type.name)' has no reference '\(edge.type.name)'")
        }
        return "(" + (action.map { $0.rawValue + " " } ?? "") + "\(identifier(source))->\(identifier(target)):\(identifier(edge.type.name)))"
    }

    // MARK: - Application conditions

    /// Writes an application condition as a matching formula.
    private mutating func writeFormula(_ formula: Formula, host: RuleGraph, naming: inout Naming, scope: Set<String>, owner: String, indent: Int) {
        guard let simplified = simplify(formula) else { return }
        var conditions: [(String, NestedCondition)] = []
        let logic = render(simplified, level: 0, naming: &naming, conditions: &conditions)
        line(indent, "\(Keyword.matchingFormula) {")
        line(indent + 1, "\(Keyword.formula) \(logic)")
        for (name, condition) in conditions {
            writeCondition(condition, named: name, host: host, naming: &naming, scope: scope, owner: owner, indent: indent + 1)
        }
        line(indent, "}")
    }

    /// A formula without operands that always hold, or `nil` if it always holds.
    private mutating func simplify(_ formula: Formula) -> Formula? {
        switch formula {
        case .true: return nil
        case .condition: return formula
        case .not(let child):
            guard let inner = simplify(child) else {
                report(.warning, .notExpressible, "A formula that never holds cannot be expressed; it is left out")
                return nil
            }
            return .not(inner)
        case .and(let left, let right):
            switch (simplify(left), simplify(right)) {
            case (let left?, let right?): return .and(left, right)
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        case .or(let left, let right):
            guard let left = simplify(left), let right = simplify(right) else { return nil }
            return .or(left, right)
        case .xor(let left, let right):
            switch (simplify(left), simplify(right)) {
            case (let left?, let right?): return .xor(left, right)
            case (let only?, nil), (nil, let only?): return .not(only)
            case (nil, nil):
                report(.warning, .notExpressible, "A formula that never holds cannot be expressed; it is left out")
                return nil
            }
        }
    }

    /// The text of a formula, collecting its nested conditions with the names of their
    /// condition graphs.
    ///
    /// The level is 0 for disjunctions, 1 for conjunctions and 2 for negations and names.
    private mutating func render(_ formula: Formula, level: Int, naming: inout Naming, conditions: inout [(String, NestedCondition)]) -> String {
        /// Puts parentheses around a text if its level is looser than required.
        func wrap(_ text: String, _ own: Int) -> String { own < level ? "(\(text))" : text }
        switch formula {
        case .true:
            return ""
        case .condition(let condition):
            var name = condition.conclusion.name.flatMap { Self.isIdentifier($0) ? $0 : nil } ?? "condition"
            let stem = name
            var counter = 1
            while naming.graphs.contains(name) {
                counter += 1
                name = "\(stem)\(counter)"
            }
            naming.graphs.insert(name)
            conditions.append((name, condition))
            return identifier(name)
        case .not(let child):
            return "!" + render(child, level: 2, naming: &naming, conditions: &conditions)
        case .and(let left, let right):
            let text = render(left, level: 1, naming: &naming, conditions: &conditions) + " \(Keyword.and) "
                + render(right, level: 2, naming: &naming, conditions: &conditions)
            return wrap(text, 1)
        case .or(let left, let right), .xor(let left, let right):
            let keyword: String
            if case .or = formula { keyword = Keyword.or } else { keyword = Keyword.xor }
            let text = render(left, level: 0, naming: &naming, conditions: &conditions) + " \(keyword) "
                + render(right, level: 1, naming: &naming, conditions: &conditions)
            return wrap(text, 0)
        }
    }

    /// Writes a nested condition as a condition graph.
    private mutating func writeCondition(
        _ condition: NestedCondition, named name: String, host: RuleGraph, naming: inout Naming, scope: Set<String>, owner: String, indent: Int
    ) {
        line(indent, "\(Keyword.conditionGraph) \(identifier(name)) {")
        var reused: [(RuleNode, String)] = []
        var origins = Set<NodeID>()
        for node in condition.conclusion.nodes {
            guard let mapping = condition.mappings.first(where: { $0.image == node.id }) else { continue }
            guard let original = host.node(mapping.origin), let hostName = naming.names[original.id], origins.insert(original.id).inserted else {
                report(.warning, .notExpressible, "A mapping of a nested condition of \(owner) cannot be expressed; its node is written as a new node")
                continue
            }
            if !HenshinValidator.sameClass(original.type, node.type) {
                report(.warning, .notExpressible, "A node of a condition of \(owner) refines the class of its host node, which Henshin Text cannot express")
            }
            naming.names[node.id] = hostName
            reused.append((node, hostName))
        }
        let reusedIDs = Set(reused.map(\.0.id))
        for node in condition.conclusion.nodes where !reusedIDs.contains(node.id) {
            let nodeName = self.name([node.id], preferred: node.name, type: node.type, naming: &naming)
            writeBlock(
                "\(Keyword.node) \(identifier(nodeName)):\(className(node.type))",
                node.attributes.map { (nil, $0.feature.name, expression($0.value, scope: scope, owner: owner)) }, indent: indent + 1)
        }
        for (node, hostName) in reused {
            writeBlock(
                "\(Keyword.reuse) \(identifier(hostName))",
                node.attributes.map { (nil, $0.feature.name, expression($0.value, scope: scope, owner: owner)) }, indent: indent + 1)
        }
        var edges: [String] = []
        for edge in condition.conclusion.edges { edges.append(edgeText(nil, edge, condition.conclusion, naming)) }
        writeEdgeList(edges, indent: indent + 1)
        if let formula = condition.conclusion.formula {
            writeFormula(formula, host: condition.conclusion, naming: &naming, scope: scope, owner: owner, indent: indent + 1)
        }
        line(indent, "}")
    }

    // MARK: - Units

    /// Writes a composite unit.
    private mutating func writeUnit(_ unit: TransformationUnit) {
        let owner = "unit '\(unit.name)'"
        var parameters = unit.parameters
        var body: [String] = []
        /// The text of a call of a sub-unit, adding variables for parameters that the unit
        /// does not pass.
        func call(_ subUnitID: UnitID, writer: inout HenshinTextWriter) -> String {
            guard let subUnit = writer.module.unit(subUnitID) else {
                writer.report(.error, .notExpressible, "\(owner.capitalisedFirst) calls a unit that is not in the module")
                return ""
            }
            var arguments: [String] = []
            for target in subUnit.parameters where target.kind != .var {
                let linked = unit.parameterMappings.compactMap { mapping -> String? in
                    if mapping.source.unit == unit.id, mapping.target == ParameterReference(unit: subUnitID, name: target.name) { return mapping.source.name }
                    if mapping.target.unit == unit.id, mapping.source == ParameterReference(unit: subUnitID, name: target.name) { return mapping.target.name }
                    return nil
                }
                var distinct: [String] = []
                for name in linked where !distinct.contains(name) { distinct.append(name) }
                if distinct.count > 1 {
                    writer.report(
                        .warning, .notExpressible,
                        "\(owner.capitalisedFirst) passes several parameters to '\(target.name)' of '\(subUnit.name)'; only '\(distinct[0])' is written")
                }
                if let first = distinct.first {
                    arguments.append(writer.identifier(first))
                    continue
                }
                var name = target.name
                var counter = 1
                while parameters.contains(where: { $0.name == name }) {
                    counter += 1
                    name = "\(target.name)\(counter)"
                }
                let type = target.typeName ?? writer.parameterTypes[ParameterReference(unit: subUnitID, name: target.name)]
                parameters.append(UnitParameter(name: name, kind: .var, typeName: type))
                writer.report(
                    target.kind.isRequired ? .warning : .information, .adjusted,
                    "\(owner.capitalisedFirst) receives the variable '\(name)' to pass to parameter '\(target.name)' of '\(subUnit.name)'")
                arguments.append(writer.identifier(name))
            }
            for mapping in unit.parameterMappings where (mapping.source.unit == subUnitID || mapping.target.unit == subUnitID) {
                let end = mapping.source.unit == subUnitID ? mapping.source : mapping.target
                if subUnit.parameter(named: end.name)?.kind == .var {
                    writer.report(.warning, .notExpressible, "\(owner.capitalisedFirst) maps the variable '\(end.name)' of '\(subUnit.name)', which Henshin Text cannot express")
                }
            }
            return writer.identifier(subUnit.name) + "(" + arguments.joined(separator: ", ") + ")"
        }
        switch unit.kind {
        case .rule:
            return
        case .sequential(let subUnits, let strict, let rollback):
            if !strict || subUnits.isEmpty { body.append("\(Keyword.strict) \(strict ? Keyword.true : Keyword.false)") }
            if !rollback { body.append("\(Keyword.rollback) \(Keyword.false)") }
            for subUnit in subUnits { body.append(call(subUnit, writer: &self)) }
        case .conditional(let test, let then, let otherwise):
            body.append("\(Keyword.if) (\(call(test, writer: &self))) \(Keyword.then) {")
            body.append("\t" + call(then, writer: &self))
            if let otherwise {
                body.append("} \(Keyword.else) {")
                body.append("\t" + call(otherwise, writer: &self))
            }
            body.append("}")
        case .priority(let subUnits), .independent(let subUnits):
            if subUnits.isEmpty { report(.error, .notExpressible, "\(owner.capitalisedFirst) has no sub-units, which Henshin Text cannot express") }
            let keyword: String
            if case .priority = unit.kind { keyword = Keyword.priority } else { keyword = Keyword.independent }
            body.append("\(keyword) [" + subUnits.map { call($0, writer: &self) }.joined(separator: ", ") + "]")
        case .iterated(let subUnit, let iterations, let strict, let rollback):
            if strict != HenshinConstants.Defaults.iteratedStrict || rollback != HenshinConstants.Defaults.iteratedRollback {
                report(.warning, .notExpressible, "Henshin Text cannot express the strictness or rollback of \(owner); the defaults are written")
            }
            let count = expression(iterations, scope: Set(unit.parameters.map(\.name)), owner: owner)
            body.append("\(Keyword.for) (\(count)) {")
            body.append("\t" + call(subUnit, writer: &self))
            body.append("}")
        case .loop(let subUnit):
            body.append("\(Keyword.while) {")
            body.append("\t" + call(subUnit, writer: &self))
            body.append("}")
        }
        let signature = parameters.map { parameter($0, of: unit.id, owner: owner) }
        line(0, "\(Keyword.unit) \(identifier(unit.name))(\(signature.joined(separator: ", "))) {")
        for text in body { line(1, text) }
        line(0, "}")
    }

    // MARK: - Expressions

    /// The Henshin Text of a JavaScript expression.
    ///
    /// The expression is read with the parser of ``JavaScriptTranslator`` and written with
    /// Henshin Text's operators (`AND`, `OR`), single-quoted strings and the fewest
    /// parentheses. What Henshin Text cannot express, such as `null`, `%` or `?:`, is
    /// reported and written as it is.
    private mutating func expression(_ text: String, scope: Set<String>, owner: String) -> String {
        do {
            var lexer = ScriptLexer(text)
            var parser = ScriptParser(tokens: try lexer.tokens())
            let node = try parser.parseExpression()
            try parser.expectEnd()
            return try render(node, scope: scope, owner: owner)
        } catch let failure as ScriptFailure {
            report(.error, .notExpressible, "The expression '\(text)' of \(owner) cannot be written in Henshin Text: \(failure.reason)")
        } catch {
            report(.error, .notExpressible, "The expression '\(text)' of \(owner) cannot be written in Henshin Text")
        }
        return text
    }

    /// The precedence of a JavaScript operator in Henshin Text, or `nil` if Henshin Text has
    /// no such operator.
    private static func precedence(_ op: ScriptBinaryOperator) -> Int? {
        op == .remainder ? nil : op.precedence
    }

    /// The precedence of an expression: that of its operator, or the tightest for others.
    private static func precedence(of node: ScriptNode) -> Int {
        if case .binary(let op, _, _) = node { return op.precedence }
        if case .unary(.negate, _) = node { return ScriptBinaryOperator.subtract.precedence }
        return Int.max
    }

    /// Writes an expression node.
    private mutating func render(_ node: ScriptNode, scope: Set<String>, owner: String) throws -> String {
        switch node {
        case .literal(let value):
            switch value {
            case .integer(let number): return String(number)
            case .real(let number):
                let text = String(number)
                guard text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }), text.contains(".") else {
                    throw ScriptFailure("the number \(text) has no decimal form")
                }
                return text
            case .string: return JavaScriptTranslator.render(value)
            case .boolean(let flag): return flag ? Keyword.true : Keyword.false
            case .null: throw ScriptFailure("Henshin Text has no null value")
            }
        case .identifier(let name):
            if !scope.contains(name) {
                report(.warning, .notExpressible, "'\(name)' in an expression of \(owner) is not a parameter")
            }
            return identifier(name)
        case .unary(let op, let operand):
            let inner = try render(operand, scope: scope, owner: owner)
            switch op {
            case .not: return "!" + (Self.precedence(of: operand) == Int.max ? inner : "(\(inner))")
            case .plus: return inner
            case .negate:
                let right = Self.precedence(of: operand) > ScriptBinaryOperator.subtract.precedence ? inner : "(\(inner))"
                return "0 - " + right
            }
        case .binary(let op, let left, let right):
            guard let level = Self.precedence(op) else { throw ScriptFailure("Henshin Text has no operator '\(op.rawValue)'") }
            var leftText = try render(left, scope: scope, owner: owner)
            var rightText = try render(right, scope: scope, owner: owner)
            if Self.precedence(of: left) < level { leftText = "(\(leftText))" }
            if Self.precedence(of: right) <= level { rightText = "(\(rightText))" }
            let symbol: String
            switch op {
            case .or: symbol = Keyword.or
            case .and: symbol = Keyword.and
            default: symbol = op.rawValue
            }
            return "\(leftText) \(symbol) \(rightText)"
        case .conditional:
            throw ScriptFailure("Henshin Text has no conditional expression")
        case .member(let receiver, let name):
            guard case .identifier(let base) = receiver else { throw ScriptFailure("a property of a computed value cannot be written") }
            return identifier(base) + "." + identifier(name)
        case .call(let callee, let arguments):
            let rendered = try arguments.map { try render($0, scope: scope, owner: owner) }
            return try path(of: callee) + "(" + rendered.joined(separator: ", ") + ")"
        }
    }

    /// The dotted name of a called function or method.
    private func path(of callee: ScriptNode) throws -> String {
        switch callee {
        case .identifier(let name): return identifier(name)
        case .member(let receiver, let name): return try path(of: receiver) + "." + identifier(name)
        default: throw ScriptFailure("a method of a computed value cannot be written")
        }
    }
}
