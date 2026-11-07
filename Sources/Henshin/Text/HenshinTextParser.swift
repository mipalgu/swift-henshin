//
//  HenshinTextParser.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase

/// The result of reading a Henshin Text document: its syntax, problems, outline and tokens.
public struct HenshinTextParseResult: Sendable {
    /// The syntax tree of the document, as far as it could be read.
    let document: TextDocument

    /// The syntax errors, with their positions; empty if the document is well-formed.
    public var diagnostics: [SourceDiagnostic]

    /// The outline of the document: imports, rules with their multi-rules, nodes and
    /// condition graphs, and units.
    public var outline: [OutlineNode]

    /// The tokens of the document, comments included, for highlighting.
    public var tokens: [SourceToken]

    /// Whether the document was read without errors.
    public var isValid: Bool { !diagnostics.contains { $0.severity == .error } }
}

/// Reads Henshin Text, the textual syntax of Henshin.
///
/// Henshin Text describes rules as a single graph whose nodes, edges and attributes carry
/// actions (`preserve`, `create`, `delete`, `forbid`, `require`), and units as nested blocks
/// of calls with sequences, conditionals, priorities, alternatives, iterations and loops. The
/// reader follows the Xtext grammar of the Eclipse Henshin project. It recovers from errors:
/// a malformed element is reported with its position and skipped, and reading continues
/// with the next element.
public enum HenshinText {
    /// Reads a Henshin Text document.
    ///
    /// - Parameter text: The document.
    /// - Returns: The syntax, diagnostics, outline and tokens of the document.
    public static func parse(_ text: String) -> HenshinTextParseResult {
        var lexer = HenshinTextLexer(text)
        let all = lexer.tokens()
        var parser = HenshinTextParser(tokens: all.filter { $0.kind != .comment }, lexer: lexer)
        let document = parser.parseDocument()
        return HenshinTextParseResult(
            document: document, diagnostics: lexer.diagnostics + parser.diagnostics, outline: parser.outline,
            tokens: sourceTokens(all))
    }

    /// Splits a Henshin Text document into tokens for highlighting.
    ///
    /// Comments are included; whitespace is not. Keywords that name data types are type
    /// names, as are the names after a colon.
    ///
    /// - Parameter text: The document.
    /// - Returns: The tokens, in order.
    public static func tokens(in text: String) -> [SourceToken] {
        var lexer = HenshinTextLexer(text)
        return sourceTokens(lexer.tokens())
    }

    /// Classifies tokens for highlighting.
    private static func sourceTokens(_ tokens: [TextToken]) -> [SourceToken] {
        var result: [SourceToken] = []
        var previous: TextToken?
        for token in tokens where token.kind != .end {
            let kind: SourceTokenKind
            switch token.kind {
            case .keyword:
                if HenshinTextConstants.dataTypes.contains(token.text) {
                    kind = .typeName
                } else if token.text == HenshinTextConstants.Keyword.true || token.text == HenshinTextConstants.Keyword.false {
                    kind = .boolean
                } else {
                    kind = .keyword
                }
            case .identifier: kind = previous?.is(":") == true ? .typeName : .identifier
            case .number: kind = .number
            case .string: kind = .string
            case .comment: kind = .comment
            case .symbol: kind = Self.punctuation.contains(token.text) ? .punctuation : .operator
            case .invalid, .end: kind = .invalid
            }
            result.append(SourceToken(kind: kind, range: token.range))
            if token.kind != .comment { previous = token }
        }
        return result
    }

    /// The symbols that are punctuation rather than operators.
    private static let punctuation: Set<String> = ["(", ")", "{", "}", "[", "]", ",", ":", "."]
}

/// A recursive-descent parser of Henshin Text with error recovery.
struct HenshinTextParser {
    /// Shorthand for the keywords.
    private typealias Keyword = HenshinTextConstants.Keyword

    /// The tokens, without comments, ending with an end token.
    private let tokens: [TextToken]
    /// The lexer, for ranges.
    private let lexer: HenshinTextLexer
    /// The position of the current token.
    private var index = 0
    /// The offset of the last error, so that one position is reported only once.
    private var lastError = -1
    /// The syntax errors found so far.
    private(set) var diagnostics: [SourceDiagnostic] = []
    /// The outline of the document.
    private(set) var outline: [OutlineNode] = []

    /// The keywords that start a top-level declaration.
    private static let declarationKeywords: Set<String> = [Keyword.ePackageImport, Keyword.rule, Keyword.unit]
    /// The keywords that start an element of a rule.
    private static let ruleKeywords: Set<String> = [
        Keyword.javaImport, Keyword.checkDangling, Keyword.injectiveMatching, Keyword.conditions, Keyword.graph,
    ]
    /// The keywords that start an element of a graph.
    private static let graphKeywords: Set<String> = Set(
        [Keyword.edges, Keyword.node, Keyword.reuse, Keyword.matchingFormula, Keyword.multiRule, Keyword.conditionGraph]
            + HenshinTextConstants.actions)
    /// The keywords that start an element of a unit.
    private static let unitKeywords: Set<String> = [
        Keyword.strict, Keyword.rollback, Keyword.independent, Keyword.if, Keyword.priority, Keyword.for, Keyword.while,
    ]

    /// Creates a parser.
    ///
    /// - Parameters:
    ///   - tokens: The tokens, without comments, ending with an end token.
    ///   - lexer: The lexer that read them, for ranges.
    init(tokens: [TextToken], lexer: HenshinTextLexer) {
        self.tokens = tokens
        self.lexer = lexer
    }

    // MARK: - Token access

    /// The current token.
    private var current: TextToken { tokens[index] }

    /// The token after the current one.
    private var following: TextToken { tokens[min(index + 1, tokens.count - 1)] }

    /// Whether the end of the document is reached.
    private var atEnd: Bool { current.kind == .end }

    /// Moves to the next token.
    ///
    /// - Returns: The token moved past.
    @discardableResult
    private mutating func advance() -> TextToken {
        let token = current
        if !atEnd { index += 1 }
        return token
    }

    /// Moves past a symbol if it is the current token.
    private mutating func accept(_ symbol: String) -> Bool {
        guard current.is(symbol) else { return false }
        advance()
        return true
    }

    /// Moves past a keyword if it is the current token.
    private mutating func acceptKeyword(_ keyword: String) -> Bool {
        guard current.isKeyword(keyword) else { return false }
        advance()
        return true
    }

    /// Moves past a symbol, or reports that it is missing.
    @discardableResult
    private mutating func expect(_ symbol: String, _ context: String) -> Bool {
        if accept(symbol) { return true }
        error("Expected '\(symbol)' \(context)")
        return false
    }

    /// Moves past a keyword, or reports that it is missing.
    @discardableResult
    private mutating func expectKeyword(_ keyword: String, _ context: String) -> Bool {
        if acceptKeyword(keyword) { return true }
        error("Expected '\(keyword)' \(context)")
        return false
    }

    /// Reports a syntax error at the current token, once per position.
    private mutating func error(_ message: String, code: HenshinTextDiagnosticCode = .unexpectedToken) {
        guard current.start != lastError else { return }
        lastError = current.start
        let found = atEnd ? "the end of the document" : "'\(current.text)'"
        diagnostics.append(.henshinText(.error, code, "\(message), found \(found)", at: current.range))
    }

    /// The range from a token to the end of the last token moved past.
    private func range(from start: TextToken) -> SourceRange {
        let end = index > 0 ? tokens[index - 1].end : start.end
        return lexer.range(start.start, max(start.end, end))
    }

    /// Skips tokens up to one of the given symbols or, after at least one token, up to a
    /// keyword that starts an element, keeping brackets balanced.
    ///
    /// A closing bracket without its opening bracket that is not one of the symbols is
    /// skipped as well.
    private mutating func recover(at symbols: Set<String>, keywords: Set<String>) {
        var depth = 0
        var moved = false
        while !atEnd {
            let token = current
            let isClosing = token.is(")") || token.is("]") || token.is("}")
            if depth == 0 {
                if token.kind == .symbol && symbols.contains(token.text) { return }
                if token.kind == .keyword && keywords.contains(token.text) && moved { return }
            }
            if token.is("(") || token.is("[") || token.is("{") { depth += 1 }
            if isClosing && depth > 0 { depth -= 1 }
            advance()
            moved = true
        }
    }

    // MARK: - Names

    /// Reads an identifier.
    private mutating func identifier(_ context: String) -> TextName? {
        guard current.kind == .identifier else {
            error("Expected a name \(context)")
            return nil
        }
        let token = advance()
        return TextName(text: token.text, range: token.range)
    }

    /// Reads a possibly qualified name such as `bank.Account`.
    private mutating func qualifiedName(_ context: String) -> TextName? {
        guard let first = identifier(context) else { return nil }
        var name = first
        while current.is("."), following.kind == .identifier {
            advance()
            let segment = advance()
            name.text += String(HenshinTextConstants.qualifier) + segment.text
            name.range = name.range.union(segment.range)
        }
        return name
    }

    /// Reads `true` or `false`.
    private mutating func truthValue(_ context: String) -> Bool? {
        if acceptKeyword(Keyword.true) { return true }
        if acceptKeyword(Keyword.false) { return false }
        error("Expected 'true' or 'false' \(context)")
        return nil
    }

    // MARK: - Document

    /// Reads the whole document.
    ///
    /// - Returns: The syntax tree.
    mutating func parseDocument() -> TextDocument {
        var document = TextDocument()
        while !atEnd {
            let start = current
            if acceptKeyword(Keyword.ePackageImport) {
                if !document.declarations.isEmpty {
                    diagnostics.append(
                        .henshinText(.error, .unexpectedToken, "Metamodel imports must precede the rules and units", at: start.range))
                }
                if let name = qualifiedName("of a metamodel package after 'ePackageImport'") {
                    document.imports.append(name)
                    outline.append(
                        OutlineNode(
                            id: "\(HenshinTextOutlineKind.import)/\(name.text)", kind: HenshinTextOutlineKind.import, name: name.text,
                            range: range(from: start), selectionRange: name.range))
                }
            } else if current.isKeyword(Keyword.rule) {
                if let rule = parseRule() { document.declarations.append(.rule(rule)) }
            } else if current.isKeyword(Keyword.unit) {
                if let unit = parseUnit() { document.declarations.append(.unit(unit)) }
            } else {
                error("Expected 'ePackageImport', 'rule' or 'unit'")
                recover(at: [], keywords: Self.declarationKeywords)
                if current.is("}") || current.is(")") || current.is("]") { advance() }
            }
        }
        if document.imports.isEmpty {
            diagnostics.append(
                .henshinText(.error, .unexpectedToken, "A document must import at least one metamodel package with 'ePackageImport'",
                    at: lexer.range(0, 0)))
        }
        return document
    }

    /// Reads a parameter list in parentheses.
    private mutating func parseParameters() -> [TextParameter] {
        var parameters: [TextParameter] = []
        guard expect("(", "before the parameters") else { return parameters }
        if accept(")") { return parameters }
        repeat {
            var kind: ParameterKind?
            if current.kind == .keyword, let declared = HenshinTextConstants.parameterKinds[current.text] {
                kind = declared
                advance()
            }
            guard let name = identifier("of a parameter") else {
                recover(at: [",", ")"], keywords: [])
                continue
            }
            expect(":", "after the parameter name")
            let typeToken = current
            if current.kind == .keyword, HenshinTextConstants.dataTypes.contains(current.text) {
                advance()
                parameters.append(TextParameter(kind: kind, name: name, type: TextName(text: typeToken.text, range: typeToken.range), isDataType: true))
            } else if let type = qualifiedName("of the parameter's type") {
                parameters.append(TextParameter(kind: kind, name: name, type: type, isDataType: false))
            } else {
                recover(at: [",", ")"], keywords: [])
            }
        } while accept(",")
        expect(")", "after the parameters")
        return parameters
    }

    // MARK: - Rules

    /// Reads a rule declaration.
    private mutating func parseRule() -> TextRule? {
        let start = advance()
        guard let name = identifier("of the rule") else {
            recover(at: [], keywords: Self.declarationKeywords)
            return nil
        }
        let parameters = parseParameters()
        var children: [OutlineNode] = []
        let body = parseRuleBody(owner: "the rule", path: "\(HenshinTextOutlineKind.rule)/\(name.text)", children: &children)
        let rule = TextRule(name: name, parameters: parameters, body: body, range: range(from: start))
        outline.append(
            OutlineNode(
                id: "\(HenshinTextOutlineKind.rule)/\(name.text)", kind: HenshinTextOutlineKind.rule, name: name.text,
                detail: signature(parameters), range: rule.range, selectionRange: name.range, children: children))
        return rule
    }

    /// A parameter list as a short text, such as `(IN x:EInt)`.
    private func signature(_ parameters: [TextParameter]) -> String {
        let listed = parameters.map { parameter in
            (parameter.kind.map { "\($0.rawValue) " } ?? "") + "\(parameter.name.text):\(parameter.type.text)"
        }
        return "(" + listed.joined(separator: ", ") + ")"
    }

    /// Reads the braced elements of a rule or multi-rule.
    private mutating func parseRuleBody(owner: String, path: String, children: inout [OutlineNode]) -> TextRuleBody {
        var body = TextRuleBody()
        guard expect("{", "to open \(owner)") else {
            recover(at: ["}"], keywords: Self.declarationKeywords)
            _ = accept("}")
            return body
        }
        var elements = 0
        while !atEnd, !current.is("}") {
            let start = current
            elements += 1
            if acceptKeyword(Keyword.javaImport) {
                if let name = qualifiedName("of a Java package") { body.javaImports.append(name) }
            } else if acceptKeyword(Keyword.checkDangling) {
                if let value = truthValue("after 'checkDangling'") { body.checkDangling.append(TextOption(value: value, range: range(from: start))) }
            } else if acceptKeyword(Keyword.injectiveMatching) {
                if let value = truthValue("after 'injectiveMatching'") {
                    body.injectiveMatching.append(TextOption(value: value, range: range(from: start)))
                }
            } else if acceptKeyword(Keyword.conditions) {
                var expressions: [TextExpression] = []
                if expect("[", "after 'conditions'") {
                    repeat {
                        if let expression = parseExpression() { expressions.append(expression) } else { recover(at: [",", "]"], keywords: []) }
                    } while accept(",")
                    expect("]", "after the conditions")
                }
                body.conditions.append((expressions, range(from: start)))
            } else if current.isKeyword(Keyword.graph) {
                body.graphs.append(parseGraph(path: path, children: &children))
            } else {
                elements -= 1
                error("Expected 'graph', 'conditions', 'checkDangling', 'injectiveMatching' or 'javaImport' in \(owner)")
                recover(at: ["}"], keywords: Self.ruleKeywords)
            }
        }
        if elements == 0 {
            error("Expected an element of \(owner)")
        }
        expect("}", "to close \(owner)")
        return body
    }

    /// Reads the graph of a rule or multi-rule.
    private mutating func parseGraph(path: String, children: inout [OutlineNode]) -> TextGraph {
        let start = advance()
        var graph = TextGraph(range: start.range)
        guard expect("{", "to open the graph") else { return graph }
        while !atEnd, !current.is("}") {
            let elementStart = current
            var action: TextAction?
            if current.kind == .keyword, let declared = TextAction(rawValue: current.text) {
                action = declared
                advance()
                guard current.isKeyword(Keyword.node) else {
                    error("Expected 'node' after '\(declared.rawValue)'")
                    recover(at: ["}"], keywords: Self.graphKeywords)
                    continue
                }
            }
            if acceptKeyword(Keyword.node) {
                if let node = parseNode(action: action, start: elementStart) {
                    graph.nodes.append(node)
                    children.append(outlineNode(node, path: path))
                }
            } else if acceptKeyword(Keyword.reuse) {
                if let reuse = parseReuse(start: elementStart) { graph.reuses.append(reuse) }
            } else if acceptKeyword(Keyword.edges) {
                graph.edges += parseEdges(allowActions: true)
            } else if current.isKeyword(Keyword.matchingFormula) {
                graph.formulas.append(parseFormula(path: path, children: &children))
            } else if acceptKeyword(Keyword.multiRule) {
                guard let name = identifier("of the multi-rule") else {
                    recover(at: ["}"], keywords: Self.graphKeywords)
                    continue
                }
                let multiPath = "\(path)/\(HenshinTextOutlineKind.multiRule)/\(name.text)"
                var multiChildren: [OutlineNode] = []
                let body = parseRuleBody(owner: "the multi-rule", path: multiPath, children: &multiChildren)
                let multiRule = TextMultiRule(name: name, body: body, range: range(from: elementStart))
                graph.multiRules.append(multiRule)
                children.append(
                    OutlineNode(
                        id: multiPath, kind: HenshinTextOutlineKind.multiRule, name: name.text, range: multiRule.range,
                        selectionRange: name.range, children: multiChildren))
            } else {
                error("Expected 'node', 'edges', 'reuse', 'matchingFormula' or 'multiRule' in the graph")
                recover(at: ["}"], keywords: Self.graphKeywords)
            }
        }
        expect("}", "to close the graph")
        graph.range = range(from: start)
        return graph
    }

    /// The outline entry of a node.
    private func outlineNode(_ node: TextNode, path: String) -> OutlineNode {
        OutlineNode(
            id: "\(path)/\(HenshinTextOutlineKind.node)/\(node.name.text)", kind: HenshinTextOutlineKind.node, name: node.name.text,
            detail: (node.action.map { "\($0.rawValue) " } ?? "") + node.type.text, range: node.range, selectionRange: node.name.range)
    }

    /// Reads a node declaration after its `node` keyword.
    private mutating func parseNode(action: TextAction?, start: TextToken) -> TextNode? {
        guard let name = identifier("of the node") else {
            recover(at: ["}"], keywords: Self.graphKeywords)
            return nil
        }
        expect(":", "after the node name")
        guard let type = qualifiedName("of the node's class") else {
            recover(at: ["}"], keywords: Self.graphKeywords)
            return nil
        }
        let attributes = current.is("{") ? parseAttributes() : []
        return TextNode(action: action, name: name, type: type, attributes: attributes, range: range(from: start))
    }

    /// Reads a `reuse` element after its keyword.
    private mutating func parseReuse(start: TextToken) -> TextReuse? {
        guard let name = identifier("of the reused node") else {
            recover(at: ["}"], keywords: Self.graphKeywords)
            return nil
        }
        let attributes = current.is("{") ? parseAttributes() : []
        return TextReuse(node: name, attributes: attributes, range: range(from: start))
    }

    /// Reads braced attributes.
    private mutating func parseAttributes() -> [TextAttribute] {
        advance()
        var attributes: [TextAttribute] = []
        while !atEnd, !current.is("}") {
            let start = current
            var action: TextAction?
            var isSet = false
            if acceptKeyword(Keyword.set) {
                isSet = true
            } else if current.kind == .keyword, let declared = TextAction(rawValue: current.text) {
                action = declared
                advance()
            }
            guard let feature = qualifiedName("of an attribute") else {
                recover(at: ["}"], keywords: Set([Keyword.set] + HenshinTextConstants.actions))
                continue
            }
            expect("=", "after the attribute name")
            guard let value = parseExpression() else {
                recover(at: ["}"], keywords: Set([Keyword.set] + HenshinTextConstants.actions))
                continue
            }
            attributes.append(TextAttribute(action: action, isSet: isSet, feature: feature, value: value, range: range(from: start)))
        }
        expect("}", "to close the attributes")
        return attributes
    }

    /// Reads a bracketed edge list after its `edges` keyword.
    private mutating func parseEdges(allowActions: Bool) -> [TextEdge] {
        var edges: [TextEdge] = []
        guard expect("[", "after 'edges'") else { return edges }
        repeat {
            let start = current
            guard expect("(", "to open an edge") else {
                recover(at: [",", "]"], keywords: [])
                continue
            }
            var action: TextAction?
            if current.kind == .keyword, let declared = TextAction(rawValue: current.text) {
                if !allowActions {
                    diagnostics.append(
                        .henshinText(.error, .unexpectedToken, "An edge of a condition graph has no action", at: current.range))
                }
                action = allowActions ? declared : nil
                advance()
            }
            guard let source = identifier("of the edge's source node") else {
                recover(at: [",", "]"], keywords: [])
                continue
            }
            expect("->", "between the source and target of the edge")
            guard let target = identifier("of the edge's target node") else {
                recover(at: [",", "]"], keywords: [])
                continue
            }
            expect(":", "before the edge's reference")
            guard let type = qualifiedName("of the edge's reference") else {
                recover(at: [",", "]"], keywords: [])
                continue
            }
            expect(")", "to close the edge")
            edges.append(TextEdge(action: action, source: source, target: target, type: type, range: range(from: start)))
        } while accept(",")
        expect("]", "to close the edges")
        return edges
    }

    // MARK: - Formulas

    /// Reads a `matchingFormula`.
    private mutating func parseFormula(path: String, children: inout [OutlineNode]) -> TextFormula {
        let start = advance()
        var formula = TextFormula(logic: nil, graphs: [], range: start.range)
        guard expect("{", "after 'matchingFormula'") else { return formula }
        if expectKeyword(Keyword.formula, "at the start of the matching formula") {
            formula.logic = parseLogic()
        }
        while !atEnd, !current.is("}") {
            guard current.isKeyword(Keyword.conditionGraph) else {
                error("Expected 'conditionGraph' in the matching formula")
                recover(at: ["}"], keywords: [Keyword.conditionGraph])
                continue
            }
            if let graph = parseConditionGraph(path: path, children: &children) { formula.graphs.append(graph) }
        }
        if formula.graphs.isEmpty { error("Expected a condition graph in the matching formula") }
        expect("}", "to close the matching formula")
        formula.range = range(from: start)
        return formula
    }

    /// Reads a logical formula over condition graphs.
    private mutating func parseLogic() -> TextLogic? {
        guard var left = parseLogicConjunction() else { return nil }
        while current.isKeyword(Keyword.or) || current.isKeyword(Keyword.xor) {
            let isOr = advance().text == Keyword.or
            guard let right = parseLogicConjunction() else { return left }
            left = isOr ? .or(left, right) : .xor(left, right)
        }
        return left
    }

    /// Reads a conjunction of a logical formula.
    private mutating func parseLogicConjunction() -> TextLogic? {
        guard var left = parseLogicPrimary() else { return nil }
        while acceptKeyword(Keyword.and) {
            guard let right = parseLogicPrimary() else { return left }
            left = .and(left, right)
        }
        return left
    }

    /// Reads a parenthesised, negated or atomic logical formula.
    private mutating func parseLogicPrimary() -> TextLogic? {
        if accept("(") {
            let inner = parseLogic()
            expect(")", "to close the formula")
            return inner
        }
        if accept("!") { return parseLogicPrimary().map { .not($0) } }
        return identifier("of a condition graph in the formula").map { .graph($0) }
    }

    /// Reads a condition graph.
    private mutating func parseConditionGraph(path: String, children: inout [OutlineNode]) -> TextConditionGraph? {
        let start = advance()
        guard let name = identifier("of the condition graph") else {
            recover(at: ["}"], keywords: [Keyword.conditionGraph])
            return nil
        }
        var graph = TextConditionGraph(name: name, nodes: [], reuses: [], edges: [], formulas: [], range: start.range)
        let graphPath = "\(path)/\(HenshinTextOutlineKind.conditionGraph)/\(name.text)"
        var graphChildren: [OutlineNode] = []
        if expect("{", "to open the condition graph") {
            while !atEnd, !current.is("}") {
                let elementStart = current
                if current.kind == .keyword, TextAction(rawValue: current.text) != nil {
                    diagnostics.append(.henshinText(.error, .unexpectedToken, "A node of a condition graph has no action", at: current.range))
                    advance()
                }
                if acceptKeyword(Keyword.node) {
                    if let node = parseNode(action: nil, start: elementStart) {
                        graph.nodes.append(node)
                        graphChildren.append(outlineNode(node, path: graphPath))
                    }
                } else if acceptKeyword(Keyword.reuse) {
                    if let reuse = parseReuse(start: elementStart) { graph.reuses.append(reuse) }
                } else if acceptKeyword(Keyword.edges) {
                    graph.edges += parseEdges(allowActions: false)
                } else if current.isKeyword(Keyword.matchingFormula) {
                    graph.formulas.append(parseFormula(path: graphPath, children: &graphChildren))
                } else {
                    error("Expected 'node', 'reuse', 'edges' or 'matchingFormula' in the condition graph")
                    recover(at: ["}"], keywords: Self.graphKeywords)
                }
            }
            expect("}", "to close the condition graph")
        }
        graph.range = range(from: start)
        children.append(
            OutlineNode(
                id: graphPath, kind: HenshinTextOutlineKind.conditionGraph, name: name.text, range: graph.range, selectionRange: name.range,
                children: graphChildren))
        return graph
    }

    // MARK: - Units

    /// Reads a unit declaration.
    private mutating func parseUnit() -> TextUnit? {
        let start = advance()
        guard let name = identifier("of the unit") else {
            recover(at: [], keywords: Self.declarationKeywords)
            return nil
        }
        let parameters = parseParameters()
        var elements: [TextUnitElement] = []
        if expect("{", "to open the unit") {
            elements = parseUnitElements(until: "}", context: "in the unit")
            expect("}", "to close the unit")
        } else {
            recover(at: ["}"], keywords: Self.declarationKeywords)
            _ = accept("}")
        }
        let unit = TextUnit(name: name, parameters: parameters, elements: elements, range: range(from: start))
        outline.append(
            OutlineNode(
                id: "\(HenshinTextOutlineKind.unit)/\(name.text)", kind: HenshinTextOutlineKind.unit, name: name.text,
                detail: signature(parameters), range: unit.range, selectionRange: name.range))
        return unit
    }

    /// Reads unit elements up to a closing symbol, which is not consumed; at least one
    /// element is expected.
    private mutating func parseUnitElements(until closing: String, context: String, alsoStoppingAt others: Set<String> = []) -> [TextUnitElement] {
        var elements: [TextUnitElement] = []
        while !atEnd, !current.is(closing), !(current.kind == .symbol && others.contains(current.text)) {
            if let element = parseUnitElement() {
                elements.append(element)
            } else {
                recover(at: Set([closing]).union(others), keywords: Self.unitKeywords)
            }
        }
        if elements.isEmpty { error("Expected a call or a control structure \(context)") }
        return elements
    }

    /// Reads one unit element.
    private mutating func parseUnitElement() -> TextUnitElement? {
        let start = current
        if current.kind == .identifier {
            let callee = advance()
            var arguments: [TextName] = []
            guard expect("(", "after the name of the called unit") else { return nil }
            if !accept(")") {
                repeat {
                    if let argument = identifier("of a parameter passed to '\(callee.text)'") { arguments.append(argument) }
                } while accept(",")
                expect(")", "after the arguments")
            }
            return .call(TextCall(callee: TextName(text: callee.text, range: callee.range), arguments: arguments, range: range(from: start)))
        }
        if accept("{") {
            let elements = parseUnitElements(until: "}", context: "in the block")
            expect("}", "to close the block")
            return .block(elements, range(from: start))
        }
        if acceptKeyword(Keyword.strict) {
            return truthValue("after 'strict'").map { .strict(TextOption(value: $0, range: range(from: start))) }
        }
        if acceptKeyword(Keyword.rollback) {
            return truthValue("after 'rollback'").map { .rollback(TextOption(value: $0, range: range(from: start))) }
        }
        if acceptKeyword(Keyword.independent) {
            return .independent(parseAlternatives(after: Keyword.independent), range(from: start))
        }
        if acceptKeyword(Keyword.priority) {
            return .priority(parseAlternatives(after: Keyword.priority), range(from: start))
        }
        if acceptKeyword(Keyword.if) {
            var condition: [TextUnitElement] = []
            if expect("(", "after 'if'") {
                condition = parseUnitElements(until: ")", context: "in the condition")
                expect(")", "to close the condition")
            }
            expectKeyword(Keyword.then, "after the condition")
            let then = parseBlock(after: Keyword.then)
            var otherwise: [TextUnitElement]?
            if acceptKeyword(Keyword.else) { otherwise = parseBlock(after: Keyword.else) }
            return .conditional(condition, then, otherwise, range(from: start))
        }
        if acceptKeyword(Keyword.for) {
            var iterations: TextExpression?
            if expect("(", "after 'for'") {
                iterations = parseExpression()
                expect(")", "after the number of iterations")
            }
            let body = parseBlock(after: Keyword.for)
            return iterations.map { .iterated($0, body, range(from: start)) }
        }
        if acceptKeyword(Keyword.while) {
            return .loop(parseBlock(after: Keyword.while), range(from: start))
        }
        error("Expected a call or a control structure")
        return nil
    }

    /// Reads a braced block of unit elements.
    private mutating func parseBlock(after keyword: String) -> [TextUnitElement] {
        guard expect("{", "after '\(keyword)'") else { return [] }
        let elements = parseUnitElements(until: "}", context: "after '\(keyword)'")
        expect("}", "to close the block")
        return elements
    }

    /// Reads bracketed alternatives separated by commas.
    private mutating func parseAlternatives(after keyword: String) -> [[TextUnitElement]] {
        var alternatives: [[TextUnitElement]] = []
        guard expect("[", "after '\(keyword)'") else { return alternatives }
        repeat {
            alternatives.append(parseUnitElements(until: "]", context: "as an alternative", alsoStoppingAt: [","]))
        } while accept(",")
        expect("]", "to close the alternatives")
        return alternatives
    }

    // MARK: - Expressions

    /// The levels of binary operators, from the loosest to the tightest.
    private static let operatorLevels: [[String]] = [
        [Keyword.or], [Keyword.and], ["==", "!="], [">=", "<=", ">", "<"], ["+", "-"], ["*", "/"],
    ]

    /// Reads an expression.
    private mutating func parseExpression() -> TextExpression? {
        parseBinary(level: 0)
    }

    /// Reads a binary expression of a level of operators and tighter ones.
    private mutating func parseBinary(level: Int) -> TextExpression? {
        guard level < Self.operatorLevels.count else { return parsePrimary() }
        guard var left = parseBinary(level: level + 1) else { return nil }
        while (current.kind == .symbol || current.kind == .keyword) && Self.operatorLevels[level].contains(current.text) {
            let symbol = advance().text
            guard let right = parseBinary(level: level + 1) else { return left }
            left = .binary(symbol, left, right)
        }
        return left
    }

    /// Reads a parenthesised, negated or atomic expression.
    private mutating func parsePrimary() -> TextExpression? {
        let token = current
        if accept("(") {
            guard let inner = parseExpression() else { return nil }
            expect(")", "to close the expression")
            return .bracket(inner)
        }
        if accept("!") { return parsePrimary().map { .not($0) } }
        switch token.kind {
        case .string:
            advance()
            return .string(token.text)
        case .number:
            advance()
            return .number(token.text)
        case .keyword where token.text == Keyword.true || token.text == Keyword.false:
            advance()
            return .boolean(token.text == Keyword.true)
        case .symbol where token.text == "-" && following.kind == .number && following.start == token.end:
            advance()
            return .number("-" + advance().text)
        case .identifier:
            guard let name = qualifiedName("in the expression") else { return nil }
            if accept("(") {
                var arguments: [TextExpression] = []
                if !accept(")") {
                    repeat {
                        if let argument = parseExpression() { arguments.append(argument) }
                    } while accept(",")
                    expect(")", "after the arguments")
                }
                return .call(name, arguments)
            }
            switch name.segments.count {
            case 1: return .parameter(name)
            case 2: return .field(name)
            default:
                diagnostics.append(
                    .henshinText(.error, .unexpectedToken, "A Java field is written as 'Class.FIELD', not '\(name.text)'", at: name.range))
                return .field(name)
            }
        default:
            error("Expected an expression")
            return nil
        }
    }
}
