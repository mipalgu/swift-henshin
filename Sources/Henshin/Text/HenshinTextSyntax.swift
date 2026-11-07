//
//  HenshinTextSyntax.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase

/// A name in a Henshin Text document, possibly qualified, with its place in the source.
struct TextName: Sendable, Hashable {
    /// The name, without escape characters; segments of a qualified name are joined by
    /// dots.
    var text: String
    /// The range of the name in the source.
    var range: SourceRange

    /// The segments of a qualified name.
    var segments: [String] { text.split(separator: HenshinTextConstants.qualifier).map(String.init) }
}

/// The action of a node, edge or attribute: what a rule does with it.
enum TextAction: String, Sendable, Hashable {
    /// The element is kept.
    case preserve
    /// The element is created.
    case create
    /// The element is deleted.
    case delete
    /// The element must not exist.
    case forbid
    /// The element must exist.
    case require
}

/// A parameter declaration of a rule or unit.
struct TextParameter: Sendable {
    /// The kind, if one is given.
    var kind: ParameterKind?
    /// The name.
    var name: TextName
    /// The type: a data type keyword such as `EInt` or the name of a class.
    var type: TextName
    /// Whether the type is a data type keyword.
    var isDataType: Bool
}

/// An expression: an attribute value, an attribute condition or a number of iterations.
indirect enum TextExpression: Sendable {
    /// A binary operation, with the operator as written (such as `AND` or `+`).
    case binary(String, TextExpression, TextExpression)
    /// A negation.
    case not(TextExpression)
    /// An expression in parentheses.
    case bracket(TextExpression)
    /// A reference to a parameter.
    case parameter(TextName)
    /// A call of a Java method, such as `Math.max(a, b)`.
    case call(TextName, [TextExpression])
    /// A Java field such as `Integer.MAX_VALUE`.
    case field(TextName)
    /// A string literal, as written with its quotes.
    case string(String)
    /// A numeric literal, as written.
    case number(String)
    /// A truth value.
    case boolean(Bool)
}

/// An attribute of a node: an expression for one attribute feature.
struct TextAttribute: Sendable {
    /// The action, if one is given.
    var action: TextAction?
    /// Whether the attribute is a `set` attribute, which changes a kept value.
    var isSet: Bool
    /// The name of the attribute feature.
    var feature: TextName
    /// The value expression.
    var value: TextExpression
    /// The range of the whole attribute.
    var range: SourceRange
}

/// A node declaration of a rule or condition graph.
struct TextNode: Sendable {
    /// The action, if one is given; condition nodes have none.
    var action: TextAction?
    /// The name.
    var name: TextName
    /// The name of the class.
    var type: TextName
    /// The attributes.
    var attributes: [TextAttribute]
    /// The range of the whole declaration.
    var range: SourceRange
}

/// A `reuse` of a node of an enclosing graph, with further attributes.
struct TextReuse: Sendable {
    /// The name of the reused node.
    var node: TextName
    /// The attributes added to it.
    var attributes: [TextAttribute]
    /// The range of the whole element.
    var range: SourceRange
}

/// An edge between two named nodes.
struct TextEdge: Sendable {
    /// The action, if one is given; condition edges have none.
    var action: TextAction?
    /// The name of the source node.
    var source: TextName
    /// The name of the target node.
    var target: TextName
    /// The name of the reference.
    var type: TextName
    /// The range of the whole edge.
    var range: SourceRange
}

/// A logical formula over condition graphs.
indirect enum TextLogic: Sendable {
    /// A conjunction.
    case and(TextLogic, TextLogic)
    /// A disjunction.
    case or(TextLogic, TextLogic)
    /// An exclusive disjunction.
    case xor(TextLogic, TextLogic)
    /// A negation.
    case not(TextLogic)
    /// The existence of a condition graph, by name.
    case graph(TextName)
}

/// A `matchingFormula`: a formula together with the condition graphs it refers to.
struct TextFormula: Sendable {
    /// The formula, if it could be read.
    var logic: TextLogic?
    /// The condition graphs.
    var graphs: [TextConditionGraph]
    /// The range of the whole element.
    var range: SourceRange
}

/// A condition graph of a matching formula.
struct TextConditionGraph: Sendable {
    /// The name.
    var name: TextName
    /// The nodes that the graph introduces.
    var nodes: [TextNode]
    /// The nodes of the enclosing graph that it reuses.
    var reuses: [TextReuse]
    /// The edges.
    var edges: [TextEdge]
    /// The nested matching formulas.
    var formulas: [TextFormula]
    /// The range of the whole element.
    var range: SourceRange
}

/// The graph of a rule or multi-rule.
struct TextGraph: Sendable {
    /// The nodes, in order.
    var nodes: [TextNode] = []
    /// The reused nodes of the kernel rule, in order.
    var reuses: [TextReuse] = []
    /// The edges, in order.
    var edges: [TextEdge] = []
    /// The matching formulas.
    var formulas: [TextFormula] = []
    /// The multi-rules.
    var multiRules: [TextMultiRule] = []
    /// The range of the whole element.
    var range: SourceRange
}

/// A truth-valued option of a rule, with its place in the source.
struct TextOption: Sendable {
    /// The value.
    var value: Bool
    /// The range of the whole option.
    var range: SourceRange
}

/// The elements of a rule or multi-rule.
struct TextRuleBody: Sendable {
    /// The imported Java packages.
    var javaImports: [TextName] = []
    /// The `checkDangling` options.
    var checkDangling: [TextOption] = []
    /// The `injectiveMatching` options.
    var injectiveMatching: [TextOption] = []
    /// The `conditions` lists, each with its range.
    var conditions: [(expressions: [TextExpression], range: SourceRange)] = []
    /// The graphs.
    var graphs: [TextGraph] = []
}

/// A multi-rule within the graph of a rule.
struct TextMultiRule: Sendable {
    /// The name.
    var name: TextName
    /// The elements.
    var body: TextRuleBody
    /// The range of the whole declaration.
    var range: SourceRange
}

/// A rule declaration.
struct TextRule: Sendable {
    /// The name.
    var name: TextName
    /// The parameters.
    var parameters: [TextParameter]
    /// The elements.
    var body: TextRuleBody
    /// The range of the whole declaration.
    var range: SourceRange
}

/// A call of a rule or unit, passing parameters of the calling unit.
struct TextCall: Sendable {
    /// The name of the called rule or unit.
    var callee: TextName
    /// The names of the parameters passed, in order.
    var arguments: [TextName]
    /// The range of the whole call.
    var range: SourceRange
}

/// An element of a unit.
indirect enum TextUnitElement: Sendable {
    /// A call.
    case call(TextCall)
    /// A block of elements applied in sequence.
    case block([TextUnitElement], SourceRange)
    /// The `strict` option of a sequence.
    case strict(TextOption)
    /// The `rollback` option of a sequence.
    case rollback(TextOption)
    /// Alternatives of which one applicable is applied.
    case independent([[TextUnitElement]], SourceRange)
    /// A conditional, with condition, success and optional failure branches.
    case conditional([TextUnitElement], [TextUnitElement], [TextUnitElement]?, SourceRange)
    /// Alternatives of which the first applicable is applied.
    case priority([[TextUnitElement]], SourceRange)
    /// A block repeated a number of times.
    case iterated(TextExpression, [TextUnitElement], SourceRange)
    /// A block repeated for as long as it succeeds.
    case loop([TextUnitElement], SourceRange)

    /// The range of the element.
    var range: SourceRange {
        switch self {
        case .call(let call): return call.range
        case .strict(let option), .rollback(let option): return option.range
        case .block(_, let range), .independent(_, let range), .conditional(_, _, _, let range), .priority(_, let range),
            .iterated(_, _, let range), .loop(_, let range):
            return range
        }
    }
}

/// A unit declaration.
struct TextUnit: Sendable {
    /// The name.
    var name: TextName
    /// The parameters.
    var parameters: [TextParameter]
    /// The elements.
    var elements: [TextUnitElement]
    /// The range of the whole declaration.
    var range: SourceRange
}

/// A top-level declaration: a rule or a unit.
enum TextDeclaration: Sendable {
    /// A rule.
    case rule(TextRule)
    /// A unit.
    case unit(TextUnit)

    /// The name of the declaration.
    var name: TextName {
        switch self {
        case .rule(let rule): return rule.name
        case .unit(let unit): return unit.name
        }
    }

    /// The parameters of the declaration.
    var parameters: [TextParameter] {
        switch self {
        case .rule(let rule): return rule.parameters
        case .unit(let unit): return unit.parameters
        }
    }
}

/// The syntax tree of a Henshin Text document.
struct TextDocument: Sendable {
    /// The names of the imported metamodel packages.
    var imports: [TextName] = []
    /// The rules and units, in document order.
    var declarations: [TextDeclaration] = []
}
