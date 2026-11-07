//
//  ExpressionEvaluator.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import AQL
import ECore
import EMFBase

/// An expression of a rule or unit, translated and ready to be evaluated.
///
/// Literals and lone parameter references are evaluated directly; every other expression
/// is evaluated as an AQL query by an ``ExpressionEvaluator``.
struct CompiledExpression: Sendable {
    /// The translation of the expression.
    let translated: TranslatedExpression

    /// The JavaScript text of the expression.
    var source: String { translated.javaScript }

    /// The variables that the expression refers to.
    var variables: [String] { translated.variables }

    /// The value of a literal expression, if the expression is a literal.
    var literal: LiteralValue? {
        if case .literal(let value) = translated.form { return value }
        return nil
    }

    /// The parameter that a lone reference names, if the expression is one.
    var parameter: String? {
        if case .variable(let name) = translated.form { return name }
        return nil
    }

    /// Translates an expression.
    ///
    /// - Parameters:
    ///   - source: The JavaScript text.
    ///   - variables: The names that the expression may refer to.
    /// - Throws: ``HenshinError/unsupportedExpression(expression:reason:)`` if the text
    ///   cannot be translated.
    init(_ source: String, variables: Set<String>) throws(HenshinError) {
        translated = try JavaScriptTranslator(variables: variables).translate(source)
    }

    /// Whether every variable of the expression has a value among the given bindings.
    ///
    /// - Parameter bindings: The parameter values bound so far.
    /// - Returns: `true` if the expression can be evaluated.
    func isEvaluable(with bindings: ParameterBindings) -> Bool {
        variables.allSatisfy { bindings.isBound($0) }
    }
}

/// Evaluates translated expressions with the Acceleo Query Language.
///
/// The evaluator keeps one AQL execution context and the parsed form of every query it has
/// evaluated, so that a rule applied many times parses each of its queries once. It runs on
/// the main actor, as AQL evaluation does.
@MainActor
final class ExpressionEvaluator {
    /// The context in which queries are evaluated.
    private let context = AQLExecutionContext(options: .standard)

    /// The parsed queries, by AQL text.
    private var parsed: [String: any AQLExpression] = [:]

    /// The number of queries evaluated, for performance reports.
    private(set) var evaluations = 0

    /// Creates an evaluator.
    init() {}

    /// Evaluates an expression with parameter values.
    ///
    /// - Parameters:
    ///   - expression: The expression to evaluate.
    ///   - values: The values of the variables that the expression refers to; objects are
    ///     given as themselves so that their attributes can be read.
    /// - Returns: The value of the expression.
    /// - Throws: ``HenshinError/evaluationFailed(expression:reason:)`` if the query cannot
    ///   be parsed or evaluated.
    func evaluate(_ expression: CompiledExpression, values: [String: SendableValue]) async throws(HenshinError)
        -> (any EcoreValue)?
    {
        evaluations += 1
        let query: any AQLExpression
        if let cached = parsed[expression.translated.aql] {
            query = cached
        } else {
            let result = AQLParser().parse(expression.translated.aql)
            guard let parsedQuery = result.expression, !result.diagnostics.contains(where: { $0.severity == .error }) else {
                let reason = result.diagnostics.map(\.message).joined(separator: "; ")
                throw .evaluationFailed(expression: expression.source, reason: reason)
            }
            parsed[expression.translated.aql] = parsedQuery
            query = parsedQuery
        }
        context.pushScope()
        defer { context.popScope() }
        for (name, value) in values { context.setVariable(name, value: value.value) }
        do {
            return try await query.evaluate(in: context)
        } catch {
            throw .evaluationFailed(expression: expression.source, reason: "\(error)")
        }
    }
}

/// A value that may be sent to the expression evaluator.
struct SendableValue: Sendable {
    /// The value, or `nil` for the null value.
    let value: (any EcoreValue)?
}
