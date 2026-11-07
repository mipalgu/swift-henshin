//
//  JavaScriptTranslator.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase
import Foundation

/// A literal value of an expression.
public enum LiteralValue: Sendable, Hashable {
    /// An integer number.
    case integer(Int)
    /// A real number.
    case real(Double)
    /// A text.
    case string(String)
    /// A truth value.
    case boolean(Bool)
    /// The null value.
    case null

    /// The literal as an Ecore value, or `nil` for the null value.
    public var ecoreValue: (any EcoreValue)? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return value
        case .string(let value): return value
        case .boolean(let value): return value
        case .null: return nil
        }
    }
}

/// An expression translated from JavaScript into the Acceleo Query Language.
public struct TranslatedExpression: Sendable, Hashable {
    /// The shape of a translated expression, which decides how it is evaluated.
    public enum Form: Sendable, Hashable {
        /// A literal, evaluated without a query.
        case literal(LiteralValue)
        /// A lone variable reference, evaluated by looking the variable up.
        case variable(String)
        /// Any other expression, evaluated as an AQL query.
        case query
    }

    /// The JavaScript text of the expression.
    public let javaScript: String

    /// The equivalent AQL text.
    public let aql: String

    /// The variables that the expression refers to, sorted by name.
    public let variables: [String]

    /// The shape of the expression.
    public let form: Form
}

/// Translates the JavaScript expressions of Henshin documents into the Acceleo Query
/// Language (AQL).
///
/// Henshin writes attribute values, attribute conditions and iteration counts in
/// JavaScript. This translator accepts the subset of JavaScript that such expressions use
/// in practice: literals, parameters, arithmetic, string concatenation, comparisons,
/// logical operators, the conditional operator, a few string methods, the common `Math`
/// functions and number parsing (see ``translationTable``). Anything else is rejected with
/// ``HenshinError/unsupportedExpression(expression:reason:)`` naming the construct, rather
/// than being evaluated with different semantics.
///
/// The translation keeps JavaScript's meaning where AQL differs: `/` always divides as real
/// numbers, string positions are converted between JavaScript's zero-based and AQL's
/// one-based indexing, and every operation is parenthesised so that AQL's precedence
/// cannot regroup it.
public struct JavaScriptTranslator: Sendable {
    /// One entry of the documented translation table.
    public struct TableEntry: Sendable, Hashable {
        /// A JavaScript expression over the variables `a`, `b`, `c`, `s` and `t`.
        public let javaScript: String
        /// The AQL text that the expression translates to.
        public let aql: String
        /// What the entry illustrates.
        public let note: String
    }

    /// The translations of the supported JavaScript constructs, with notes on semantics.
    ///
    /// The table documents the translator and is checked by its tests.
    public static let translationTable: [TableEntry] = [
        TableEntry(javaScript: "42", aql: "42", note: "integer literal"),
        TableEntry(javaScript: "2.5", aql: "2.5", note: "real literal"),
        TableEntry(javaScript: "\"text\"", aql: "'text'", note: "string literal in either quote style"),
        TableEntry(javaScript: "true", aql: "true", note: "Boolean literal"),
        TableEntry(javaScript: "null", aql: "null", note: "null literal"),
        TableEntry(javaScript: "a", aql: "a", note: "parameter reference"),
        TableEntry(javaScript: "a + b", aql: "(a + b)", note: "addition, or concatenation if either is a string"),
        TableEntry(javaScript: "a - b", aql: "(a - b)", note: "subtraction"),
        TableEntry(javaScript: "a * b", aql: "(a * b)", note: "multiplication"),
        TableEntry(javaScript: "a / b", aql: "((a * 1.0) / b)", note: "always real division, as in JavaScript"),
        TableEntry(javaScript: "a % b", aql: "(a mod b)", note: "remainder"),
        TableEntry(javaScript: "-a", aql: "(-a)", note: "negation"),
        TableEntry(javaScript: "a == b", aql: "(a = b)", note: "equality; === is the same"),
        TableEntry(javaScript: "a != b", aql: "(a <> b)", note: "inequality; !== is the same"),
        TableEntry(javaScript: "a < b", aql: "(a < b)", note: "comparison; also <=, >, >="),
        TableEntry(javaScript: "a && b", aql: "(a and b)", note: "conjunction"),
        TableEntry(javaScript: "a || b", aql: "(a or b)", note: "disjunction"),
        TableEntry(javaScript: "!a", aql: "(not a)", note: "negation"),
        TableEntry(javaScript: "a ? b : c", aql: "(if a then b else c endif)", note: "conditional"),
        TableEntry(javaScript: "s.length", aql: "s.size()", note: "string length"),
        TableEntry(javaScript: "s.toUpperCase()", aql: "s.toUpper()", note: "upper case"),
        TableEntry(javaScript: "s.toLowerCase()", aql: "s.toLower()", note: "lower case"),
        TableEntry(javaScript: "s.trim()", aql: "s.trim()", note: "trimmed text"),
        TableEntry(javaScript: "s.startsWith(t)", aql: "s.startsWith(t)", note: "prefix test"),
        TableEntry(javaScript: "s.endsWith(t)", aql: "s.endsWith(t)", note: "suffix test"),
        TableEntry(javaScript: "s.includes(t)", aql: "s.contains(t)", note: "substring test"),
        TableEntry(javaScript: "s.replace(t, s)", aql: "s.substituteFirst(t, s)", note: "replaces the first occurrence of a text"),
        TableEntry(javaScript: "s.substring(a, b)", aql: "s.substring((a + 1), b)", note: "zero-based start converted to one-based"),
        TableEntry(javaScript: "Math.abs(a)", aql: "a.abs()", note: "absolute value"),
        TableEntry(javaScript: "Math.max(a, b)", aql: "a.max(b)", note: "maximum; Math.min is alike"),
        TableEntry(javaScript: "Math.floor(a)", aql: "a.floor()", note: "rounds down; Math.ceil rounds up"),
        TableEntry(javaScript: "Math.round(a)", aql: "a.round()", note: "rounds halves away from zero, unlike JavaScript for negative halves"),
        TableEntry(javaScript: "parseInt(s)", aql: "s.toInteger()", note: "integer from text"),
        TableEntry(javaScript: "parseFloat(s)", aql: "s.toReal()", note: "real number from text"),
        TableEntry(javaScript: "String(a)", aql: "('' + a)", note: "text of a value"),
    ]

    /// The names that expressions may refer to.
    public let variables: Set<String>

    /// Creates a translator.
    ///
    /// - Parameter variables: The names that expressions may refer to, usually the
    ///   parameters of a rule or unit.
    public init(variables: Set<String>) {
        self.variables = variables
    }

    /// Translates a JavaScript expression into AQL.
    ///
    /// - Parameter source: The JavaScript text.
    /// - Returns: The translated expression.
    /// - Throws: ``HenshinError/unsupportedExpression(expression:reason:)`` if the text is
    ///   not in the supported subset or refers to an unknown name.
    public func translate(_ source: String) throws(HenshinError) -> TranslatedExpression {
        do {
            var lexer = ScriptLexer(source)
            var parser = ScriptParser(tokens: try lexer.tokens())
            let node = try parser.parseExpression()
            try parser.expectEnd()
            var referenced = Set<String>()
            let aql = try emit(node, referenced: &referenced)
            let form: TranslatedExpression.Form
            switch node {
            case .literal(let value): form = .literal(value)
            case .identifier(let name): form = .variable(name)
            default: form = .query
            }
            return TranslatedExpression(javaScript: source, aql: aql, variables: referenced.sorted(), form: form)
        } catch let failure as ScriptFailure {
            throw .unsupportedExpression(expression: source, reason: failure.reason)
        } catch {
            throw .unsupportedExpression(expression: source, reason: "\(error)")
        }
    }

    // MARK: - Emitting AQL

    /// Renders a syntax tree as AQL text.
    private func emit(_ node: ScriptNode, referenced: inout Set<String>) throws -> String {
        switch node {
        case .literal(let value):
            return Self.render(value)
        case .identifier(let name):
            guard variables.contains(name) else {
                throw ScriptFailure("'\(name)' is not a parameter of the unit")
            }
            referenced.insert(name)
            return name
        case .unary(let op, let operand):
            let inner = try emit(operand, referenced: &referenced)
            switch op {
            case .negate: return "(-\(inner))"
            case .plus: return inner
            case .not: return "(not \(inner))"
            }
        case .binary(let op, let left, let right):
            let lhs = try emit(left, referenced: &referenced)
            let rhs = try emit(right, referenced: &referenced)
            if op == .divide { return "((\(lhs) * 1.0) / \(rhs))" }
            return "(\(lhs) \(op.aql) \(rhs))"
        case .conditional(let condition, let then, let otherwise):
            let c = try emit(condition, referenced: &referenced)
            let a = try emit(then, referenced: &referenced)
            let b = try emit(otherwise, referenced: &referenced)
            return "(if \(c) then \(a) else \(b) endif)"
        case .member(let receiver, let name):
            guard name == ScriptSyntax.lengthProperty else {
                throw ScriptFailure("property '\(name)' is not supported")
            }
            return "\(try emitReceiver(receiver, referenced: &referenced)).size()"
        case .call(let callee, let arguments):
            return try emitCall(callee, arguments, referenced: &referenced)
        }
    }

    /// Renders the receiver of a method call, which must not be a namespace.
    private func emitReceiver(_ node: ScriptNode, referenced: inout Set<String>) throws -> String {
        if case .identifier(let name) = node, ScriptSyntax.namespaces.contains(name) {
            throw ScriptFailure("'\(name)' cannot be used as a value")
        }
        return try emit(node, referenced: &referenced)
    }

    /// Renders a function or method call.
    private func emitCall(_ callee: ScriptNode, _ arguments: [ScriptNode], referenced: inout Set<String>) throws -> String {
        var rendered: [String] = []
        for argument in arguments { rendered.append(try emit(argument, referenced: &referenced)) }
        switch callee {
        case .identifier(let function):
            guard let translation = ScriptSyntax.globalFunctions[function], translation.arity == rendered.count else {
                throw ScriptFailure("function '\(function)' with \(rendered.count) argument(s) is not supported")
            }
            return translation.render(rendered)
        case .member(.identifier(let namespace), let function) where ScriptSyntax.namespaces.contains(namespace):
            guard let translation = ScriptSyntax.mathFunctions[function], translation.arity == rendered.count else {
                throw ScriptFailure("function '\(namespace).\(function)' with \(rendered.count) argument(s) is not supported")
            }
            return translation.render(rendered)
        case .member(let receiver, let method):
            guard let translation = ScriptSyntax.methods[method], translation.arities.contains(rendered.count) else {
                throw ScriptFailure("method '\(method)' with \(rendered.count) argument(s) is not supported")
            }
            let target = try emitReceiver(receiver, referenced: &referenced)
            return translation.render(target, rendered)
        default:
            throw ScriptFailure("only named functions and methods can be called")
        }
    }

    /// Renders a literal as AQL text.
    static func render(_ value: LiteralValue) -> String {
        switch value {
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .boolean(let flag): return flag ? "true" : "false"
        case .null: return HenshinConstants.nullLiteral
        case .string(let text):
            var escaped = ""
            for character in text {
                switch character {
                case "\\": escaped += "\\\\"
                case "'": escaped += "\\'"
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default: escaped.append(character)
                }
            }
            return "'\(escaped)'"
        }
    }
}

// MARK: - Syntax

/// A failure to read or translate a script, with its reason.
struct ScriptFailure: Error {
    /// A phrase that names the problem.
    let reason: String

    /// Creates a failure.
    ///
    /// - Parameter reason: A phrase that names the problem.
    init(_ reason: String) { self.reason = reason }
}

/// The vocabulary of the supported JavaScript subset and its AQL counterparts.
enum ScriptSyntax {
    /// The property that gives the length of a string.
    static let lengthProperty = "length"

    /// The names that only qualify functions, such as `Math`.
    static let namespaces: Set<String> = ["Math"]

    /// The keyword literals.
    static let keywordLiterals: [String: LiteralValue] = ["true": .boolean(true), "false": .boolean(false), "null": .null]

    /// Reserved words whose constructs are outside the subset.
    static let unsupportedKeywords: Set<String> = [
        "new", "function", "typeof", "instanceof", "var", "let", "const", "return", "this", "delete", "void",
        "in", "of", "class", "if", "else", "for", "while", "do", "switch", "undefined",
    ]

    /// A translation of a function with a fixed number of arguments.
    struct Function {
        /// The number of arguments.
        let arity: Int
        /// Renders the call from the AQL texts of its arguments.
        let render: @Sendable ([String]) -> String
    }

    /// A translation of a method with its receiver.
    struct Method {
        /// The numbers of arguments that the method accepts.
        let arities: ClosedRange<Int>
        /// Renders the call from the AQL texts of its receiver and arguments.
        let render: @Sendable (String, [String]) -> String
    }

    /// The global functions of the subset.
    static let globalFunctions: [String: Function] = [
        "parseInt": Function(arity: 1) { "\($0[0]).toInteger()" },
        "parseFloat": Function(arity: 1) { "\($0[0]).toReal()" },
        "String": Function(arity: 1) { "('' + \($0[0]))" },
    ]

    /// The functions of the `Math` namespace in the subset.
    static let mathFunctions: [String: Function] = [
        "abs": Function(arity: 1) { "\($0[0]).abs()" },
        "floor": Function(arity: 1) { "\($0[0]).floor()" },
        "ceil": Function(arity: 1) { "\($0[0]).ceil()" },
        "round": Function(arity: 1) { "\($0[0]).round()" },
        "max": Function(arity: 2) { "\($0[0]).max(\($0[1]))" },
        "min": Function(arity: 2) { "\($0[0]).min(\($0[1]))" },
    ]

    /// The string methods of the subset.
    static let methods: [String: Method] = [
        "toUpperCase": Method(arities: 0...0) { receiver, _ in "\(receiver).toUpper()" },
        "toLowerCase": Method(arities: 0...0) { receiver, _ in "\(receiver).toLower()" },
        "trim": Method(arities: 0...0) { receiver, _ in "\(receiver).trim()" },
        "startsWith": Method(arities: 1...1) { "\($0).startsWith(\($1[0]))" },
        "endsWith": Method(arities: 1...1) { "\($0).endsWith(\($1[0]))" },
        "includes": Method(arities: 1...1) { "\($0).contains(\($1[0]))" },
        "replace": Method(arities: 2...2) { "\($0).substituteFirst(\($1[0]), \($1[1]))" },
        "substring": Method(arities: 1...2) { receiver, arguments in
            let start = "(\(arguments[0]) + 1)"
            return arguments.count == 1 ? "\(receiver).substring(\(start))" : "\(receiver).substring(\(start), \(arguments[1]))"
        },
    ]
}

/// A unary operator of the subset.
enum ScriptUnaryOperator: Sendable {
    /// Arithmetic negation.
    case negate
    /// Unary plus, which leaves a number unchanged.
    case plus
    /// Logical negation.
    case not
}

/// A binary operator of the subset, with its precedence and AQL spelling.
enum ScriptBinaryOperator: String, Sendable {
    /// Logical or.
    case or = "||"
    /// Logical and.
    case and = "&&"
    /// Equality.
    case equal = "=="
    /// Inequality.
    case notEqual = "!="
    /// Less than.
    case less = "<"
    /// Less than or equal.
    case lessOrEqual = "<="
    /// Greater than.
    case greater = ">"
    /// Greater than or equal.
    case greaterOrEqual = ">="
    /// Addition or concatenation.
    case add = "+"
    /// Subtraction.
    case subtract = "-"
    /// Multiplication.
    case multiply = "*"
    /// Real division.
    case divide = "/"
    /// Remainder.
    case remainder = "%"

    /// The binding strength of the operator; higher binds tighter.
    var precedence: Int {
        switch self {
        case .or: return 1
        case .and: return 2
        case .equal, .notEqual: return 3
        case .less, .lessOrEqual, .greater, .greaterOrEqual: return 4
        case .add, .subtract: return 5
        case .multiply, .divide, .remainder: return 6
        }
    }

    /// The AQL spelling of the operator.
    var aql: String {
        switch self {
        case .or: return "or"
        case .and: return "and"
        case .equal: return "="
        case .notEqual: return "<>"
        case .remainder: return "mod"
        default: return rawValue
        }
    }
}

/// A syntax tree of the JavaScript subset.
indirect enum ScriptNode: Sendable {
    /// A literal.
    case literal(LiteralValue)
    /// A name.
    case identifier(String)
    /// A unary operation.
    case unary(ScriptUnaryOperator, ScriptNode)
    /// A binary operation.
    case binary(ScriptBinaryOperator, ScriptNode, ScriptNode)
    /// The conditional operator.
    case conditional(ScriptNode, ScriptNode, ScriptNode)
    /// A property access.
    case member(ScriptNode, String)
    /// A call of a function or method.
    case call(ScriptNode, [ScriptNode])
}

/// A token of the JavaScript subset.
enum ScriptToken: Equatable, Sendable {
    /// A number.
    case number(LiteralValue)
    /// A string literal.
    case string(String)
    /// A name or keyword.
    case identifier(String)
    /// An operator or punctuation mark.
    case symbol(String)
}

/// Splits JavaScript text into tokens of the supported subset.
struct ScriptLexer {
    /// The characters of the text.
    private let characters: [Character]
    /// The position of the next character.
    private var position = 0

    /// The operators and punctuation of the subset, longest first.
    private static let symbols = [
        "===", "!==", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "%", "<", ">", "!", "?", ":", "(", ")",
        ",", ".",
    ]

    /// Operators of JavaScript outside the subset, longest first.
    private static let unsupportedSymbols = [
        ">>>", "<<", ">>", "++", "--", "+=", "-=", "*=", "/=", "=>", "=", "&", "|", "^", "~", "[", "]", "{", "}", ";", "`",
    ]

    /// Creates a lexer.
    ///
    /// - Parameter source: The JavaScript text.
    init(_ source: String) {
        characters = Array(source)
    }

    /// Reads all tokens of the text.
    ///
    /// - Returns: The tokens in order.
    /// - Throws: ``ScriptFailure`` for characters outside the subset.
    mutating func tokens() throws -> [ScriptToken] {
        var result: [ScriptToken] = []
        while let character = peek() {
            if character.isWhitespace {
                position += 1
            } else if character.isNumber {
                result.append(try number())
            } else if character == "\"" || character == "'" {
                result.append(.string(try string(delimiter: character)))
            } else if character.isLetter || character == "_" || character == "$" {
                result.append(.identifier(identifier()))
            } else if let symbol = Self.symbols.first(where: matches) {
                if let longer = Self.unsupportedSymbols.first(where: matches), longer.count > symbol.count {
                    throw ScriptFailure("operator '\(longer)' is not supported")
                }
                position += symbol.count
                result.append(.symbol(symbol))
            } else if let symbol = Self.unsupportedSymbols.first(where: matches) {
                throw ScriptFailure("'\(symbol)' is not supported")
            } else {
                throw ScriptFailure("unexpected character '\(character)'")
            }
        }
        return result
    }

    /// The next character, if any.
    private func peek(_ offset: Int = 0) -> Character? {
        position + offset < characters.count ? characters[position + offset] : nil
    }

    /// Whether the text continues with a symbol.
    private func matches(_ symbol: String) -> Bool {
        for (offset, character) in symbol.enumerated() where peek(offset) != character { return false }
        return true
    }

    /// Reads a name.
    private mutating func identifier() -> String {
        var name = ""
        while let character = peek(), character.isLetter || character.isNumber || character == "_" || character == "$" {
            name.append(character)
            position += 1
        }
        return name
    }

    /// Reads a number.
    private mutating func number() throws -> ScriptToken {
        var text = ""
        var isReal = false
        while let character = peek() {
            if character.isNumber {
                text.append(character)
            } else if character == ".", !isReal, peek(1)?.isNumber == true {
                isReal = true
                text.append(character)
            } else if character == "e" || character == "E" {
                isReal = true
                text.append(character)
                if let sign = peek(1), sign == "+" || sign == "-" {
                    text.append(sign)
                    position += 1
                }
            } else {
                break
            }
            position += 1
        }
        if let next = peek(), next.isLetter || next == "_" {
            throw ScriptFailure("malformed number '\(text)\(next)'")
        }
        if !isReal, let value = Int(text) { return .number(.integer(value)) }
        guard let value = Double(text) else { throw ScriptFailure("malformed number '\(text)'") }
        return .number(.real(value))
    }

    /// Reads a string literal.
    private mutating func string(delimiter: Character) throws -> String {
        position += 1
        var text = ""
        while let character = peek() {
            position += 1
            if character == delimiter { return text }
            guard character == "\\" else {
                text.append(character)
                continue
            }
            guard let escaped = peek() else { break }
            position += 1
            switch escaped {
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "r": text.append("\r")
            case "u":
                guard position + 4 <= characters.count, let scalar = UInt32(String(characters[position..<position + 4]), radix: 16),
                    let unicode = Unicode.Scalar(scalar)
                else { throw ScriptFailure("malformed unicode escape") }
                text.unicodeScalars.append(unicode)
                position += 4
            default: text.append(escaped)
            }
        }
        throw ScriptFailure("unterminated string literal")
    }
}

/// Parses tokens of the JavaScript subset into a syntax tree by precedence climbing.
struct ScriptParser {
    /// The tokens to parse.
    private let tokens: [ScriptToken]
    /// The position of the next token.
    private var position = 0

    /// Creates a parser.
    ///
    /// - Parameter tokens: The tokens to parse.
    init(tokens: [ScriptToken]) {
        self.tokens = tokens
    }

    /// Parses an expression, including the conditional operator.
    ///
    /// - Returns: The syntax tree.
    /// - Throws: ``ScriptFailure`` for malformed or unsupported syntax.
    mutating func parseExpression() throws -> ScriptNode {
        let condition = try parseBinary(minimum: 1)
        guard accept("?") else { return condition }
        let then = try parseExpression()
        try expect(":")
        let otherwise = try parseExpression()
        return .conditional(condition, then, otherwise)
    }

    /// Checks that all tokens have been read.
    ///
    /// - Throws: ``ScriptFailure`` if tokens remain.
    func expectEnd() throws {
        if position < tokens.count { throw ScriptFailure("unexpected \(describe(tokens[position]))") }
    }

    /// Parses binary operations whose precedence is at least the given one.
    private mutating func parseBinary(minimum: Int) throws -> ScriptNode {
        var left = try parseUnary()
        while let op = peekOperator(), op.precedence >= minimum {
            position += 1
            let right = try parseBinary(minimum: op.precedence + 1)
            left = .binary(op, left, right)
        }
        return left
    }

    /// The binary operator at the current position, if any.
    private func peekOperator() -> ScriptBinaryOperator? {
        guard position < tokens.count, case .symbol(let symbol) = tokens[position] else { return nil }
        switch symbol {
        case "===": return .equal
        case "!==": return .notEqual
        default: return ScriptBinaryOperator(rawValue: symbol)
        }
    }

    /// Parses a unary operation or a postfix expression.
    private mutating func parseUnary() throws -> ScriptNode {
        if accept("!") { return .unary(.not, try parseUnary()) }
        if accept("+") { return .unary(.plus, try parseUnary()) }
        if accept("-") {
            let operand = try parseUnary()
            switch operand {
            case .literal(.integer(let value)): return .literal(.integer(-value))
            case .literal(.real(let value)): return .literal(.real(-value))
            default: return .unary(.negate, operand)
            }
        }
        return try parsePostfix()
    }

    /// Parses a primary expression followed by property accesses and calls.
    private mutating func parsePostfix() throws -> ScriptNode {
        var node = try parsePrimary()
        while true {
            if accept(".") {
                guard position < tokens.count, case .identifier(let name) = tokens[position] else {
                    throw ScriptFailure("expected a name after '.'")
                }
                position += 1
                if case .member = node, !accept("(", peekOnly: true) {
                    throw ScriptFailure("nested property access is not supported")
                }
                node = .member(node, name)
            } else if accept("(") {
                var arguments: [ScriptNode] = []
                if !accept(")") {
                    repeat { arguments.append(try parseExpression()) } while accept(",")
                    try expect(")")
                }
                if case .member(_, ScriptSyntax.lengthProperty) = node {
                    throw ScriptFailure("'length' is a property, not a method")
                }
                node = .call(node, arguments)
            } else {
                return node
            }
        }
    }

    /// Parses a literal, name or parenthesised expression.
    private mutating func parsePrimary() throws -> ScriptNode {
        guard position < tokens.count else { throw ScriptFailure("the expression ends too early") }
        let token = tokens[position]
        position += 1
        switch token {
        case .number(let value): return .literal(value)
        case .string(let text): return .literal(.string(text))
        case .identifier(let name):
            if let literal = ScriptSyntax.keywordLiterals[name] { return .literal(literal) }
            if ScriptSyntax.unsupportedKeywords.contains(name) { throw ScriptFailure("'\(name)' is not supported") }
            if ScriptSyntax.namespaces.contains(name), !accept(".", peekOnly: true) {
                throw ScriptFailure("'\(name)' cannot be used as a value")
            }
            return .identifier(name)
        case .symbol("("):
            let inner = try parseExpression()
            try expect(")")
            return inner
        case .symbol(let symbol):
            throw ScriptFailure("unexpected '\(symbol)'")
        }
    }

    /// Consumes a symbol if it comes next.
    private mutating func accept(_ symbol: String, peekOnly: Bool = false) -> Bool {
        guard position < tokens.count, tokens[position] == .symbol(symbol) else { return false }
        if !peekOnly { position += 1 }
        return true
    }

    /// Consumes a symbol that must come next.
    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else {
            let found = position < tokens.count ? describe(tokens[position]) : "the end of the expression"
            throw ScriptFailure("expected '\(symbol)' but found \(found)")
        }
    }

    /// Describes a token for a diagnostic.
    private func describe(_ token: ScriptToken) -> String {
        switch token {
        case .number(let value): return "number \(JavaScriptTranslator.render(value))"
        case .string(let text): return "string '\(text)'"
        case .identifier(let name): return "'\(name)'"
        case .symbol(let symbol): return "'\(symbol)'"
        }
    }
}
