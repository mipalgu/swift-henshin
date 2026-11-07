//
//  HenshinTextTranslator.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// The module that a Henshin Text document describes, with the problems found in it.
public struct HenshinTextTranslation: Sendable {
    /// The module, as far as the document could be translated.
    public var module: HenshinModule

    /// The syntax errors and the problems of translation, with their positions.
    public var diagnostics: [SourceDiagnostic]

    /// The outline of the document.
    public var outline: [OutlineNode]

    /// Whether the document was read and translated without errors.
    public var isValid: Bool { !diagnostics.contains { $0.severity == .error } }
}

/// The translation of Henshin Text into the module model.
extension HenshinText {
    /// Reads a Henshin Text document and translates it into a module.
    ///
    /// The translation follows Henshin's own translation of Henshin Text: each rule's
    /// single graph becomes a left-hand side, a right-hand side and mappings between them;
    /// `forbid` and `require` elements become negative and positive application conditions;
    /// matching formulas become nested conditions; multi-rules copy the nodes and edges of
    /// their kernel rule; and nested blocks of units become units of their own.
    ///
    /// - Parameters:
    ///   - text: The document.
    ///   - packages: The metamodel packages that the document may import, by name; nested
    ///     packages are found through their parents.
    /// - Returns: The module and the diagnostics of reading and translating it.
    public static func translate(_ text: String, packages: [EPackage]) -> HenshinTextTranslation {
        translate(parsed: parse(text), packages: packages)
    }

    /// Translates a read Henshin Text document into a module.
    ///
    /// - Parameters:
    ///   - parsed: The result of reading the document.
    ///   - packages: The metamodel packages that the document may import.
    /// - Returns: The module and the diagnostics of reading and translating it.
    public static func translate(parsed: HenshinTextParseResult, packages: [EPackage]) -> HenshinTextTranslation {
        var translator = HenshinTextTranslator(packages: packages)
        let module = translator.translate(parsed.document)
        return HenshinTextTranslation(module: module, diagnostics: parsed.diagnostics + translator.diagnostics, outline: parsed.outline)
    }
}

/// Translates the syntax tree of a Henshin Text document into a ``HenshinModule``.
struct HenshinTextTranslator {
    /// The available packages by qualified name, such as `bank` or `bank.accounts`.
    private let packagesByName: [(name: String, package: EPackage)]
    /// The imported packages, in order.
    private var imported: [EPackage] = []
    /// The next node identity.
    private var nextNode = 0
    /// The problems found so far.
    private(set) var diagnostics: [SourceDiagnostic] = []
    /// The rules and units by name, with their identities and parameters.
    var declarations: [String: (id: UnitID, parameters: [TextParameter])] = [:]
    /// The units translated so far, by identity.
    var units: [TransformationUnit?] = []

    /// Creates a translator.
    ///
    /// - Parameter packages: The metamodel packages that the document may import.
    init(packages: [EPackage]) {
        var named: [(String, EPackage)] = []
        /// Records a package and its nested packages under their qualified names.
        func record(_ package: EPackage, prefix: String) {
            let name = prefix.isEmpty ? package.name : prefix + String(HenshinTextConstants.qualifier) + package.name
            named.append((name, package))
            for nested in package.eSubpackages { record(nested, prefix: name) }
        }
        for package in packages { record(package, prefix: "") }
        packagesByName = named
    }

    /// Reports a problem.
    mutating func report(_ severity: DiagnosticSeverity, _ code: HenshinTextDiagnosticCode, _ message: String, at range: SourceRange?) {
        diagnostics.append(.henshinText(severity, code, message, at: range))
    }

    /// A fresh node identity.
    mutating func freshNode() -> NodeID {
        defer { nextNode += 1 }
        return NodeID(nextNode)
    }

    // MARK: - Document

    /// Translates a document.
    ///
    /// - Parameter document: The syntax tree.
    /// - Returns: The module.
    mutating func translate(_ document: TextDocument) -> HenshinModule {
        for name in document.imports {
            if let package = packagesByName.first(where: { $0.name == name.text })?.package {
                imported.append(package)
            } else {
                report(.error, .unknownMetamodelElement, "No metamodel package named '\(name.text)' is known", at: name.range)
            }
        }
        for declaration in document.declarations {
            let name = declaration.name
            if declarations[name.text] != nil {
                report(.error, .duplicateName, "A rule or unit named '\(name.text)' is already declared", at: name.range)
                continue
            }
            declarations[name.text] = (UnitID(units.count), declaration.parameters)
            units.append(nil)
        }
        for declaration in document.declarations {
            guard let entry = declarations[declaration.name.text], units[entry.id.rawValue] == nil else { continue }
            switch declaration {
            case .rule(let text):
                units[entry.id.rawValue] = TransformationUnit(id: entry.id, rule: translate(text))
            case .unit(let text):
                let parameters = text.parameters.map { unitParameter($0, owner: "unit '\(text.name.text)'") }
                translateUnit(text, id: entry.id, parameters: parameters)
            }
        }
        return HenshinModule(
            name: HenshinTextConstants.moduleName, imports: imported.map(\.nsURI), units: units.compactMap { $0 })
    }

    /// Translates a parameter declaration.
    mutating func unitParameter(_ parameter: TextParameter, owner: String) -> UnitParameter {
        if parameter.kind == nil {
            report(
                .warning, .missingParameterKind,
                "Parameter '\(parameter.name.text)' of \(owner) has no kind; Henshin deprecates parameters without IN, OUT, INOUT or VAR",
                at: parameter.name.range)
        }
        var typeName = parameter.type.text
        if !parameter.isDataType {
            if let type = resolveClass(parameter.type) { typeName = type.name }
        }
        return UnitParameter(name: parameter.name.text, kind: parameter.kind ?? .unknown, typeName: typeName)
    }

    // MARK: - Metamodel names

    /// Resolves the name of a class: a simple name in an imported package or a name
    /// qualified by its package.
    mutating func resolveClass(_ name: TextName) -> EClass? {
        let segments = name.segments
        if segments.count == 1 {
            for package in imported { if let found = package.getEClass(name.text) { return found } }
        } else {
            let packageName = segments.dropLast().joined(separator: String(HenshinTextConstants.qualifier))
            let candidates = packagesByName.filter { $0.name == packageName }.map(\.package)
                + imported.compactMap { package in
                    segments.dropLast().reduce(Optional(package)) { $0?.getSubpackage($1) }
                }
            for package in candidates { if let found = package.getEClass(segments[segments.count - 1]) { return found } }
        }
        report(.error, .unknownMetamodelElement, "No class named '\(name.text)' is imported", at: name.range)
        return nil
    }

    /// Resolves the name of an attribute of a class, possibly qualified by its class.
    mutating func resolveAttribute(_ name: TextName, of type: EClass) -> EAttribute? {
        let segments = name.segments
        var owner = type
        if segments.count > 1 {
            let qualifier = TextName(text: segments.dropLast().joined(separator: String(HenshinTextConstants.qualifier)), range: name.range)
            guard let resolved = resolveClass(qualifier) else { return nil }
            owner = resolved
        }
        if let found = owner.getEAttribute(name: segments.last ?? name.text) { return found }
        report(.error, .unknownMetamodelElement, "Class '\(owner.name)' has no attribute '\(segments.last ?? name.text)'", at: name.range)
        return nil
    }

    /// Resolves the name of a reference of a class, possibly qualified by its class.
    mutating func resolveReference(_ name: TextName, of type: EClass) -> EReference? {
        let segments = name.segments
        var owner = type
        if segments.count > 1 {
            let qualifier = TextName(text: segments.dropLast().joined(separator: String(HenshinTextConstants.qualifier)), range: name.range)
            guard let resolved = resolveClass(qualifier) else { return nil }
            owner = resolved
        }
        if let found = owner.getEReference(name: segments.last ?? name.text) { return found }
        report(.error, .unknownMetamodelElement, "Class '\(owner.name)' has no reference '\(segments.last ?? name.text)'", at: name.range)
        return nil
    }

    // MARK: - Expressions

    /// The JavaScript text of an expression, as Henshin writes it into a module, after
    /// checking that it refers only to parameters in scope.
    ///
    /// Binary operators are written without spaces, except that `OR` and `AND` become
    /// ` || ` and ` && `; string literals keep their quotes.
    mutating func javaScript(_ expression: TextExpression, scope: Set<String>) -> String {
        switch expression {
        case .binary(let symbol, let left, let right):
            let leftText = javaScript(left, scope: scope)
            let rightText = javaScript(right, scope: scope)
            if let logical = HenshinTextConstants.logicalOperators[symbol] { return "\(leftText) \(logical) \(rightText)" }
            let glued = (symbol == "+" || symbol == "-") && (rightText.hasPrefix("+") || rightText.hasPrefix("-"))
            return glued ? "\(leftText) \(symbol) \(rightText)" : leftText + symbol + rightText
        case .not(let inner):
            return "!" + javaScript(inner, scope: scope)
        case .bracket(let inner):
            return "(" + javaScript(inner, scope: scope) + ")"
        case .parameter(let name):
            if !scope.contains(name.text) {
                report(.error, .unknownName, "'\(name.text)' is not a parameter", at: name.range)
            }
            return name.text
        case .call(let name, let arguments):
            return name.text + "(" + arguments.map { javaScript($0, scope: scope) }.joined(separator: ",") + ")"
        case .field(let name):
            return name.text
        case .string(let text), .number(let text):
            return text
        case .boolean(let value):
            return value ? HenshinTextConstants.Keyword.true : HenshinTextConstants.Keyword.false
        }
    }

    // MARK: - Rules

    /// What a multi-rule needs to know about its kernel rule.
    struct Kernel {
        /// The translated kernel rule.
        var rule: Rule
        /// The parameters of the outermost rule, which every multi-rule copies.
        var parameters: [UnitParameter]
        /// The actions of the nodes of the kernel rule and of its own kernels, by name.
        var actions: [String: TextAction?]
    }

    /// Translates a rule.
    mutating func translate(_ text: TextRule) -> Rule {
        let parameters = text.parameters.map { unitParameter($0, owner: "rule '\(text.name.text)'") }
        return translateRule(name: text.name, body: text.body, parameters: parameters, kernel: nil, range: text.range)
    }

    /// Translates a rule or multi-rule from its elements.
    private mutating func translateRule(name: TextName, body: TextRuleBody, parameters: [UnitParameter], kernel: Kernel?, range: SourceRange) -> Rule {
        let scope = Set(parameters.map(\.name))
        for (option, keyword) in [(body.checkDangling, HenshinTextConstants.Keyword.checkDangling), (body.injectiveMatching, HenshinTextConstants.Keyword.injectiveMatching)]
        where option.count > 1 {
            report(.error, .repeatedElement, "'\(keyword)' can only be given once", at: option[1].range)
        }
        if body.conditions.count > 1 {
            report(.error, .repeatedElement, "'\(HenshinTextConstants.Keyword.conditions)' can only be given once", at: body.conditions[1].range)
        }
        if body.graphs.count != 1 {
            report(
                .error, .graphCount, body.graphs.isEmpty ? "Rule '\(name.text)' has no graph" : "Rule '\(name.text)' has more than one graph",
                at: body.graphs.count > 1 ? body.graphs[1].range : name.range)
        }
        let graph = body.graphs.first ?? TextGraph(range: range)
        var rule = Rule(
            name: name.text, parameters: parameters,
            lhs: RuleGraph(name: name.text + HenshinTextConstants.leftSideSuffix),
            rhs: RuleGraph(name: name.text + HenshinTextConstants.rightSideSuffix),
            attributeConditions: body.conditions.flatMap(\.expressions).map { AttributeCondition(conditionText: javaScript($0, scope: scope)) },
            checkDangling: body.checkDangling.first?.value ?? HenshinConstants.Defaults.checkDangling,
            injectiveMatching: body.injectiveMatching.first?.value ?? HenshinConstants.Defaults.injectiveMatching,
            javaImports: body.javaImports.map(\.text))
        var actions = kernel?.actions ?? [:]
        for node in graph.nodes {
            if actions[node.name.text] != nil {
                report(.error, .duplicateName, "A node named '\(node.name.text)' is already declared", at: node.name.range)
            }
            actions[node.name.text] = node.action
        }
        mergeNodes(graph, into: &rule, scope: scope)
        for node in rule.lhs.nodes {
            if let image = rule.rhs.nodes.first(where: { $0.name == node.name }) { rule.mappings.append(NodeMapping(origin: node.id, image: image.id)) }
        }
        if let kernel { copyKernel(kernel, graph: graph, into: &rule, scope: scope) }
        addEdges(graph.edges, actions: actions, to: &rule)
        if let kernel {
            for (kernelGraph, ownGraph) in [(kernel.rule.lhs, rule.lhs), (kernel.rule.rhs, rule.rhs)] {
                for node in ownGraph.nodes {
                    guard let origin = kernelGraph.nodes.first(where: { $0.name == node.name && $0.name != nil && $0.type.id == node.type.id }) else { continue }
                    rule.multiMappings.append(NodeMapping(origin: origin.id, image: node.id))
                }
            }
        }
        rule.lhs.formula = formula(of: graph, actions: actions, host: rule.lhs, scope: scope)
        let multiKernel = Kernel(rule: rule, parameters: kernel?.parameters ?? parameters, actions: actions)
        for multiRule in graph.multiRules {
            rule.multiRules.append(
                translateRule(name: multiRule.name, body: multiRule.body, parameters: multiKernel.parameters, kernel: multiKernel, range: multiRule.range))
        }
        return rule
    }

    /// Adds the nodes of a graph to the sides of a rule, with their attributes.
    ///
    /// The left-hand side receives the kept nodes, those marked `preserve` first, followed
    /// by the deleted nodes; the right-hand side receives copies of the kept nodes, with
    /// `set` values and created attributes, followed by the created nodes.
    private mutating func mergeNodes(_ graph: TextGraph, into rule: inout Rule, scope: Set<String>) {
        let kept = graph.nodes.filter { $0.action == .preserve } + graph.nodes.filter { $0.action == nil }
        for text in kept {
            guard let type = resolveClass(text.type) else { continue }
            checkAttributes(of: text)
            let lhsAttributes = attributes(text.attributes.filter { ($0.action == nil || $0.action == .preserve) && !$0.isSet }, of: type, scope: scope)
            var rhsAttributes = lhsAttributes
            for attribute in text.attributes where attribute.isSet {
                guard let feature = resolveAttribute(attribute.feature, of: type) else { continue }
                let value = javaScript(attribute.value, scope: scope)
                if let index = rhsAttributes.firstIndex(where: { $0.feature.name == feature.name }) {
                    rhsAttributes[index].value = value
                } else {
                    report(
                        .error, .setWithoutPreserve,
                        "'set \(attribute.feature.text)' needs an attribute '\(attribute.feature.text)' that the node keeps", at: attribute.range)
                    rhsAttributes.append(RuleAttribute(feature: feature, value: value))
                }
            }
            rhsAttributes += attributes(text.attributes.filter { $0.action == .create }, of: type, scope: scope)
            let deleted = attributes(text.attributes.filter { $0.action == .delete }, of: type, scope: scope)
            rule.lhs.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: lhsAttributes + deleted))
            rule.rhs.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: rhsAttributes))
        }
        for text in graph.nodes where text.action == .create {
            guard let type = resolveClass(text.type) else { continue }
            checkAttributes(of: text)
            if type.isAbstract || type.isInterface {
                report(.error, .abstractCreation, "A node of the abstract class '\(type.name)' cannot be created", at: text.type.range)
            }
            let values = attributes(text.attributes.filter { ($0.action == nil || $0.action == .create) && !$0.isSet }, of: type, scope: scope)
            rule.rhs.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: values))
        }
        for text in graph.nodes where text.action == .delete {
            guard let type = resolveClass(text.type) else { continue }
            checkAttributes(of: text)
            let values = attributes(text.attributes.filter { ($0.action == nil || $0.action == .delete) && !$0.isSet }, of: type, scope: scope)
            rule.lhs.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: values))
        }
        for text in graph.nodes where text.action == .forbid || text.action == .require {
            _ = resolveClass(text.type)
            checkAttributes(of: text)
        }
    }

    /// Reports attributes whose actions do not suit the action of their node, and features
    /// given more than once.
    private mutating func checkAttributes(of node: TextNode) {
        let allowed: Set<TextAction?>
        switch node.action {
        case .create?: allowed = [nil, .create]
        case .delete?: allowed = [nil, .delete, .forbid, .require]
        case .forbid?: allowed = [nil, .forbid]
        case .require?: allowed = [nil, .require]
        case .preserve?, nil: allowed = [nil, .preserve, .create, .delete, .forbid, .require]
        }
        let nodeAction = node.action?.rawValue ?? TextAction.preserve.rawValue
        var seen = Set<String>()
        for attribute in node.attributes {
            if attribute.isSet && !(node.action == nil || node.action == .preserve) {
                report(.error, .actionMismatch, "'set' attributes are not allowed in \(nodeAction) nodes", at: attribute.range)
            } else if !allowed.contains(attribute.action) {
                report(
                    .error, .actionMismatch, "\(attribute.action?.rawValue ?? "") attributes are not allowed in \(nodeAction) nodes", at: attribute.range)
            }
            let key = "\(attribute.feature.text)/\(attribute.isSet)/\(attribute.action?.rawValue ?? "")"
            if !seen.insert(key).inserted {
                report(.error, .duplicateName, "Attribute '\(attribute.feature.text)' can only be given once", at: attribute.feature.range)
            }
        }
    }

    /// Translates attributes of a node of a class.
    mutating func attributes(_ texts: [TextAttribute], of type: EClass, scope: Set<String>) -> [RuleAttribute] {
        texts.compactMap { text in
            guard let feature = resolveAttribute(text.feature, of: type) else { return nil }
            return RuleAttribute(feature: feature, value: javaScript(text.value, scope: scope))
        }
    }

    /// Copies the nodes and edges of a kernel rule into a multi-rule and adds the attributes
    /// of its `reuse` elements.
    private mutating func copyKernel(_ kernel: Kernel, graph: TextGraph, into rule: inout Rule, scope: Set<String>) {
        for node in kernel.rule.lhs.nodes {
            let copy = RuleNode(id: freshNode(), name: node.name, type: node.type)
            rule.lhs.nodes.append(copy)
            if let image = kernel.rule.rhs.nodes.first(where: { $0.name == node.name }) {
                let imageCopy = RuleNode(id: freshNode(), name: image.name, type: image.type)
                rule.rhs.nodes.append(imageCopy)
                rule.mappings.append(NodeMapping(origin: copy.id, image: imageCopy.id))
            }
        }
        for node in kernel.rule.rhs.nodes where !kernel.rule.lhs.nodes.contains(where: { $0.name == node.name }) {
            rule.rhs.nodes.append(RuleNode(id: freshNode(), name: node.name, type: node.type))
        }
        for reuse in graph.reuses {
            guard let reusedAction = kernel.actions[reuse.node.text] else {
                report(.error, .unknownName, "The kernel rule has no node named '\(reuse.node.text)'", at: reuse.node.range)
                continue
            }
            let lhsIndex = rule.lhs.nodes.firstIndex { $0.name == reuse.node.text }
            let rhsIndex = rule.rhs.nodes.firstIndex { $0.name == reuse.node.text }
            guard let type = (lhsIndex.map { rule.lhs.nodes[$0] } ?? rhsIndex.map { rule.rhs.nodes[$0] })?.type else { continue }
            for attribute in reuse.attributes {
                guard let feature = resolveAttribute(attribute.feature, of: type) else { continue }
                let value = RuleAttribute(feature: feature, value: javaScript(attribute.value, scope: scope))
                let action = attribute.isSet ? TextAction.create : (attribute.action ?? reusedAction ?? .preserve)
                switch (reusedAction ?? .preserve, action) {
                case (.create, .create), (.preserve, .create):
                    guard let rhsIndex else { continue }
                    if attribute.isSet, let existing = rule.rhs.nodes[rhsIndex].attributes.firstIndex(where: { $0.feature.name == feature.name }) {
                        rule.rhs.nodes[rhsIndex].attributes[existing] = value
                    } else {
                        rule.rhs.nodes[rhsIndex].attributes.append(value)
                    }
                case (.delete, .delete), (.preserve, .delete):
                    if let lhsIndex { rule.lhs.nodes[lhsIndex].attributes.append(value) }
                case (.preserve, .preserve):
                    if let lhsIndex { rule.lhs.nodes[lhsIndex].attributes.append(value) }
                    if let rhsIndex { rule.rhs.nodes[rhsIndex].attributes.append(value) }
                default:
                    report(
                        .error, .actionMismatch,
                        "\(action.rawValue) attributes are not allowed for the \((reusedAction ?? .preserve).rawValue) node '\(reuse.node.text)'",
                        at: attribute.range)
                }
            }
        }
        for (kernelGraph, side) in [(kernel.rule.lhs, true), (kernel.rule.rhs, false)] {
            for edge in kernelGraph.edges {
                guard let source = kernelGraph.node(edge.source)?.name, let target = kernelGraph.node(edge.target)?.name else { continue }
                if side {
                    if let s = rule.lhs.node(named: source), let t = rule.lhs.node(named: target) {
                        rule.lhs.edges.append(RuleEdge(source: s.id, target: t.id, type: edge.type))
                    }
                } else if let s = rule.rhs.node(named: source), let t = rule.rhs.node(named: target) {
                    rule.rhs.edges.append(RuleEdge(source: s.id, target: t.id, type: edge.type))
                }
            }
        }
    }

    /// Whether an action makes an element part of an application condition.
    private static func isCondition(_ action: TextAction?) -> Bool { action == .forbid || action == .require }

    /// Adds the edges of a graph that are not part of application conditions to the sides of
    /// a rule.
    private mutating func addEdges(_ edges: [TextEdge], actions: [String: TextAction?], to rule: inout Rule) {
        for edge in edges {
            guard let sourceAction = endAction(edge.source, actions), let targetAction = endAction(edge.target, actions) else { continue }
            checkEdgeActions(edge, source: sourceAction, target: targetAction)
            if Self.isCondition(edge.action) || Self.isCondition(sourceAction) || Self.isCondition(targetAction) { continue }
            let creates = edge.action == .create || sourceAction == .create || targetAction == .create
            if creates {
                addEdge(edge, to: &rule.rhs)
            } else if edge.action == .delete {
                addEdge(edge, to: &rule.lhs)
            } else {
                addEdge(edge, to: &rule.lhs)
                addEdge(edge, to: &rule.rhs)
            }
        }
    }

    /// The action of the node at the end of an edge, or `nil` with a report if no node has
    /// the name; a node without action yields `.some(nil)`.
    private mutating func endAction(_ name: TextName, _ actions: [String: TextAction?]) -> TextAction?? {
        guard let action = actions[name.text] else {
            report(.error, .unknownName, "No node named '\(name.text)' is declared", at: name.range)
            return nil
        }
        return .some(action)
    }

    /// Reports an edge whose action does not suit the actions of its nodes.
    private mutating func checkEdgeActions(_ edge: TextEdge, source: TextAction?, target: TextAction?) {
        let allowed: Set<TextAction>
        switch edge.action ?? .preserve {
        case .preserve: allowed = [.preserve]
        case .create: allowed = [.preserve, .create]
        case .delete: allowed = [.preserve, .delete]
        case .forbid: allowed = [.preserve, .delete, .forbid]
        case .require: allowed = [.preserve, .delete, .require]
        }
        let ends = (source ?? .preserve, target ?? .preserve)
        if !allowed.contains(ends.0) || !allowed.contains(ends.1) {
            report(
                .error, .actionMismatch,
                "A \((edge.action ?? .preserve).rawValue) edge is not allowed between a \(ends.0.rawValue) node and a \(ends.1.rawValue) node",
                at: edge.range)
        }
    }

    /// Adds an edge between the nodes of a graph named by its ends.
    private mutating func addEdge(_ edge: TextEdge, to graph: inout RuleGraph) {
        guard let source = graph.node(named: edge.source.text), let target = graph.node(named: edge.target.text) else {
            report(.error, .unknownName, "The nodes of the edge '\(edge.type.text)' are not on the same side of the rule", at: edge.range)
            return
        }
        guard let type = resolveReference(edge.type, of: source.type) else { return }
        graph.edges.append(RuleEdge(source: source.id, target: target.id, type: type))
    }

    // MARK: - Application conditions

    /// The application condition of a rule graph: its `forbid` and `require` elements and its
    /// matching formula, combined by conjunction.
    private mutating func formula(of graph: TextGraph, actions: [String: TextAction?], host: RuleGraph, scope: Set<String>) -> Formula? {
        let marked = { (action: TextAction) -> Bool in
            graph.nodes.contains { node in
                node.action == action || ((node.action == nil || node.action == .preserve || node.action == .delete) && node.attributes.contains { $0.action == action })
            } || graph.edges.contains { $0.action == action }
        }
        let forbid = marked(.forbid)
        let require = marked(.require)
        var tokens: Formula?
        if forbid && require {
            tokens = .and(.not(.condition(conclusion(.forbid, graph, actions: actions, host: host, scope: scope))), .condition(conclusion(.require, graph, actions: actions, host: host, scope: scope)))
        } else if forbid {
            tokens = .not(.condition(conclusion(.forbid, graph, actions: actions, host: host, scope: scope)))
        } else if require {
            tokens = .condition(conclusion(.require, graph, actions: actions, host: host, scope: scope))
        }
        if graph.formulas.count > 1 {
            report(.error, .repeatedElement, "'\(HenshinTextConstants.Keyword.matchingFormula)' can only be given once", at: graph.formulas[1].range)
        }
        let explicit = graph.formulas.first.flatMap { matching($0, host: host, scope: scope) }
        switch (tokens, explicit) {
        case (let tokens?, let explicit?): return .and(tokens, explicit)
        case (let tokens?, nil): return tokens
        case (nil, let explicit): return explicit
        }
    }

    /// The nested condition of the `forbid` or `require` elements of a rule graph.
    private mutating func conclusion(_ action: TextAction, _ graph: TextGraph, actions: [String: TextAction?], host: RuleGraph, scope: Set<String>) -> NestedCondition {
        var conclusion = RuleGraph(name: action.rawValue)
        for text in graph.nodes where text.action == action {
            guard let type = resolveClass(text.type) else { continue }
            let values = attributes(text.attributes.filter { $0.action == nil || $0.action == action }, of: type, scope: scope)
            conclusion.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: values))
        }
        for text in graph.nodes where text.action == nil || text.action == .preserve || text.action == .delete {
            let marked = text.attributes.filter { $0.action == action && !$0.isSet }
            guard !marked.isEmpty, let original = host.node(named: text.name.text) else { continue }
            conclusion.nodes.append(
                RuleNode(id: freshNode(), name: original.name, type: original.type, attributes: attributes(marked, of: original.type, scope: scope)))
        }
        for edge in graph.edges {
            let sourceAction = actions[edge.source.text] ?? nil
            let targetAction = actions[edge.target.text] ?? nil
            guard edge.action == action || sourceAction == action || targetAction == action else { continue }
            for end in [edge.source, edge.target] where conclusion.node(named: end.text) == nil {
                guard let original = host.node(named: end.text) else {
                    report(.error, .unknownName, "No node named '\(end.text)' can take part in the \(action.rawValue) condition", at: end.range)
                    continue
                }
                conclusion.nodes.append(RuleNode(id: freshNode(), name: original.name, type: original.type, attributes: original.attributes))
            }
            addEdge(TextEdge(action: nil, source: edge.source, target: edge.target, type: edge.type, range: edge.range), to: &conclusion)
        }
        let mappings = conclusion.nodes.compactMap { node in
            host.nodes.first { $0.name == node.name && $0.name != nil }.map { NodeMapping(origin: $0.id, image: node.id) }
        }
        return NestedCondition(conclusion: conclusion, mappings: mappings)
    }

    /// The formula of a matching formula over a host graph.
    private mutating func matching(_ formula: TextFormula, host: RuleGraph, scope: Set<String>) -> Formula? {
        var names = Set<String>()
        for graph in formula.graphs where !names.insert(graph.name.text).inserted {
            report(.error, .duplicateName, "A condition graph named '\(graph.name.text)' is already declared", at: graph.name.range)
        }
        return formula.logic.flatMap { logic($0, graphs: formula.graphs, host: host, scope: scope) }
    }

    /// Translates a logical formula over the condition graphs of a matching formula.
    private mutating func logic(_ logic: TextLogic, graphs: [TextConditionGraph], host: RuleGraph, scope: Set<String>) -> Formula? {
        /// Combines two operands, keeping the one that could be translated if the other could not.
        func combine(_ left: Formula?, _ right: Formula?, _ make: (Formula, Formula) -> Formula) -> Formula? {
            guard let left else { return right }
            guard let right else { return left }
            return make(left, right)
        }
        switch logic {
        case .and(let left, let right):
            return combine(self.logic(left, graphs: graphs, host: host, scope: scope), self.logic(right, graphs: graphs, host: host, scope: scope), Formula.and)
        case .or(let left, let right):
            return combine(self.logic(left, graphs: graphs, host: host, scope: scope), self.logic(right, graphs: graphs, host: host, scope: scope), Formula.or)
        case .xor(let left, let right):
            return combine(self.logic(left, graphs: graphs, host: host, scope: scope), self.logic(right, graphs: graphs, host: host, scope: scope), Formula.xor)
        case .not(let child):
            return self.logic(child, graphs: graphs, host: host, scope: scope).map { .not($0) }
        case .graph(let name):
            guard let graph = graphs.first(where: { $0.name.text == name.text }) else {
                report(.error, .unknownName, "No condition graph named '\(name.text)' is declared", at: name.range)
                return nil
            }
            return .condition(condition(graph, host: host, scope: scope))
        }
    }

    /// The nested condition of a condition graph over a host graph.
    private mutating func condition(_ graph: TextConditionGraph, host: RuleGraph, scope: Set<String>) -> NestedCondition {
        var conclusion = RuleGraph(name: graph.name.text)
        var mappings: [NodeMapping] = []
        for text in graph.nodes {
            guard let type = resolveClass(text.type) else { continue }
            if host.node(named: text.name.text) != nil || conclusion.node(named: text.name.text) != nil {
                report(.error, .duplicateName, "A node named '\(text.name.text)' is already declared", at: text.name.range)
            }
            conclusion.nodes.append(RuleNode(id: freshNode(), name: text.name.text, type: type, attributes: attributes(text.attributes, of: type, scope: scope)))
        }
        for reuse in graph.reuses {
            guard let original = host.node(named: reuse.node.text) else {
                report(.error, .unknownName, "The enclosing graph has no node named '\(reuse.node.text)'", at: reuse.node.range)
                continue
            }
            let copy = RuleNode(id: freshNode(), name: original.name, type: original.type, attributes: attributes(reuse.attributes, of: original.type, scope: scope))
            conclusion.nodes.append(copy)
            mappings.append(NodeMapping(origin: original.id, image: copy.id))
        }
        for edge in graph.edges {
            for end in [edge.source, edge.target] where conclusion.node(named: end.text) == nil {
                guard let original = host.node(named: end.text) else {
                    report(.error, .unknownName, "No node named '\(end.text)' is declared", at: end.range)
                    continue
                }
                let copy = RuleNode(id: freshNode(), name: original.name, type: original.type, attributes: original.attributes)
                conclusion.nodes.append(copy)
                mappings.append(NodeMapping(origin: original.id, image: copy.id))
            }
            addEdge(edge, to: &conclusion)
        }
        if graph.formulas.count > 1 {
            report(.error, .repeatedElement, "'\(HenshinTextConstants.Keyword.matchingFormula)' can only be given once", at: graph.formulas[1].range)
        }
        conclusion.formula = graph.formulas.first.flatMap { matching($0, host: conclusion, scope: scope) }
        return NestedCondition(conclusion: conclusion, mappings: mappings)
    }
}
