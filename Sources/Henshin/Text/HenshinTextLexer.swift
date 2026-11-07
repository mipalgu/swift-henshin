//
//  HenshinTextLexer.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase

/// A token of a Henshin Text document.
struct TextToken: Sendable, Hashable {
    /// What a token is.
    enum Kind: Sendable, Hashable {
        /// An identifier; the text is the name without its escape character.
        case identifier
        /// A keyword.
        case keyword
        /// An unsigned integer or decimal number.
        case number
        /// A string literal, with its quotes.
        case string
        /// A symbol such as `->` or `{`.
        case symbol
        /// A comment.
        case comment
        /// Text that cannot start a token.
        case invalid
        /// The end of the document.
        case end
    }

    /// What the token is.
    var kind: Kind
    /// The text of the token; for an escaped identifier, without the escape character.
    var text: String
    /// The offset of the first byte of the token, in UTF-8 code units.
    var start: Int
    /// The offset just after the last byte of the token, in UTF-8 code units.
    var end: Int
    /// The range of the token in the source.
    var range: SourceRange
    /// Whether the token is an identifier written with the escape character.
    var isEscaped = false

    /// Whether the token is a given symbol.
    ///
    /// - Parameter symbol: The symbol.
    /// - Returns: `true` if the token is that symbol.
    func `is`(_ symbol: String) -> Bool { kind == .symbol && text == symbol }

    /// Whether the token is a given keyword.
    ///
    /// - Parameter keyword: The keyword.
    /// - Returns: `true` if the token is that keyword.
    func isKeyword(_ keyword: String) -> Bool { kind == .keyword && text == keyword }
}

/// Splits Henshin Text into tokens.
///
/// The lexer follows the terminals of Henshin's Xtext grammar: identifiers may be escaped
/// with `^` to use a keyword as a name, strings are delimited by double or single quotes
/// with backslash escapes, and comments are written as in Java. A minus sign is always a
/// token of its own; the parser joins it with a number where the grammar expects a
/// negative literal.
struct HenshinTextLexer {
    /// The bytes of the document.
    private let bytes: [UInt8]
    /// The lines of the document, for positions.
    private let lines: LineTable
    /// The current offset.
    private var offset = 0
    /// The problems found so far.
    private(set) var diagnostics: [SourceDiagnostic] = []

    /// Creates a lexer.
    ///
    /// - Parameter text: The document.
    init(_ text: String) {
        bytes = Array(text.utf8)
        lines = LineTable(text)
    }

    /// The range between two offsets.
    func range(_ start: Int, _ end: Int) -> SourceRange { lines.range(fromUTF8Offset: start, to: end) }

    /// Reads all tokens, comments included, followed by an end token.
    ///
    /// - Returns: The tokens.
    mutating func tokens() -> [TextToken] {
        var result: [TextToken] = []
        while let token = next() { result.append(token) }
        result.append(TextToken(kind: .end, text: "", start: bytes.count, end: bytes.count, range: range(bytes.count, bytes.count)))
        return result
    }

    /// Reads the next token, skipping whitespace.
    private mutating func next() -> TextToken? {
        while offset < bytes.count, Self.isWhitespace(bytes[offset]) { offset += 1 }
        guard offset < bytes.count else { return nil }
        let start = offset
        let byte = bytes[offset]
        if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "/") {
            while offset < bytes.count, bytes[offset] != 0x0A, bytes[offset] != 0x0D { offset += 1 }
            return token(.comment, from: start)
        }
        if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "*") {
            offset += 2
            while offset < bytes.count, !(bytes[offset] == UInt8(ascii: "*") && peek(1) == UInt8(ascii: "/")) { offset += 1 }
            if offset < bytes.count {
                offset += 2
            } else {
                diagnostics.append(.henshinText(.error, .unterminated, "The comment has no end", at: range(start, offset)))
            }
            return token(.comment, from: start)
        }
        if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { return string(delimiter: byte) }
        if Self.isDigit(byte) { return number() }
        if byte == HenshinTextConstants.escape.asciiValue, offset + 1 < bytes.count, Self.isIdentifierStart(bytes[offset + 1]) {
            offset += 1
            var token = identifier(from: start)
            token.kind = .identifier
            token.isEscaped = true
            return token
        }
        if Self.isIdentifierStart(byte) { return identifier(from: start) }
        for symbol in HenshinTextConstants.symbols where matches(symbol) {
            offset += symbol.utf8.count
            return token(.symbol, from: start)
        }
        offset += 1
        while offset < bytes.count, bytes[offset] & 0xC0 == 0x80 { offset += 1 }
        let invalid = token(.invalid, from: start)
        diagnostics.append(.henshinText(.error, .unexpectedCharacter, "Unexpected character '\(invalid.text)'", at: invalid.range))
        return invalid
    }

    /// The byte at a distance from the current offset, if any.
    private func peek(_ distance: Int) -> UInt8? {
        offset + distance < bytes.count ? bytes[offset + distance] : nil
    }

    /// Whether the document continues with a symbol at the current offset.
    private func matches(_ symbol: String) -> Bool {
        for (index, byte) in symbol.utf8.enumerated() where peek(index) != byte { return false }
        return true
    }

    /// A token from an offset to the current offset.
    private func token(_ kind: TextToken.Kind, from start: Int, text: String? = nil) -> TextToken {
        TextToken(
            kind: kind, text: text ?? String(decoding: bytes[start..<offset], as: UTF8.self), start: start, end: offset,
            range: range(start, offset))
    }

    /// Reads an identifier or keyword whose first character is at the current offset.
    private mutating func identifier(from start: Int) -> TextToken {
        let nameStart = offset
        while offset < bytes.count, Self.isIdentifierPart(bytes[offset]) { offset += 1 }
        let name = String(decoding: bytes[nameStart..<offset], as: UTF8.self)
        let isKeyword = nameStart == start && HenshinTextConstants.keywords.contains(name)
        return token(isKeyword ? .keyword : .identifier, from: start, text: name)
    }

    /// Reads an integer or a decimal number.
    private mutating func number() -> TextToken {
        let start = offset
        while offset < bytes.count, Self.isDigit(bytes[offset]) { offset += 1 }
        if offset + 1 < bytes.count, bytes[offset] == UInt8(ascii: "."), Self.isDigit(bytes[offset + 1]) {
            offset += 1
            while offset < bytes.count, Self.isDigit(bytes[offset]) { offset += 1 }
        }
        return token(.number, from: start)
    }

    /// Reads a string literal whose opening quote is at the current offset.
    private mutating func string(delimiter: UInt8) -> TextToken {
        let start = offset
        offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == UInt8(ascii: "\\") {
                offset += 2
                continue
            }
            offset += 1
            if byte == delimiter { return token(.string, from: start) }
        }
        offset = bytes.count
        let unterminated = token(.string, from: start)
        diagnostics.append(.henshinText(.error, .unterminated, "The string has no closing quote", at: unterminated.range))
        return unterminated
    }

    /// Whether a byte is whitespace.
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// Whether a byte is a decimal digit.
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    /// Whether a byte can start an identifier.
    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "_")
    }

    /// Whether a byte can continue an identifier.
    private static func isIdentifierPart(_ byte: UInt8) -> Bool { isIdentifierStart(byte) || isDigit(byte) }
}
