//
//  ValueSemantics.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// The conversions and comparisons of attribute values that rule application relies on.
///
/// Expressions compute numbers as integers or reals and text as strings, whereas attributes
/// have a specific data type. Values are converted to the data type of the attribute they
/// are compared with or assigned to, in the way that Henshin converts the results of its
/// scripts: numbers are narrowed or widened, and any value becomes text for a string
/// attribute.
enum ValueSemantics {
    /// Converts a value to the data type of an attribute.
    ///
    /// - Parameters:
    ///   - value: The value to convert, or `nil`.
    ///   - feature: The attribute that receives or is compared with the value.
    /// - Returns: The converted value, `nil` for `nil`, or the value unchanged if no
    ///   conversion applies.
    static func cast(_ value: (any EcoreValue)?, to feature: EAttribute) -> (any EcoreValue)? {
        if feature.isMany {
            let elements = (value as? EcoreValueArray)?.values ?? (value.map { [$0] } ?? [])
            return EcoreValueArray(elements.compactMap { cast($0, toTypeNamed: feature.eType.name) })
        }
        return cast(value, toTypeNamed: feature.eType.name)
    }

    /// Converts a single value to the data type of the given name.
    ///
    /// - Parameters:
    ///   - value: The value to convert, or `nil`.
    ///   - typeName: The name of the data type, such as `EInt`.
    /// - Returns: The converted value, `nil` for `nil`, or the value unchanged if no
    ///   conversion applies.
    static func cast(_ value: (any EcoreValue)?, toTypeNamed typeName: String) -> (any EcoreValue)? {
        guard let value else { return nil }
        guard let type = EcoreDataType(rawValue: typeName) else { return value }
        switch type {
        case .eString, .eStringObject:
            return value as? String ?? text(of: value)
        case .eInt, .eIntegerObject:
            return integer(value).map { Int($0) } ?? value
        case .eLong, .eLongObject:
            return integer(value).map { Int64($0) } ?? value
        case .eShort, .eShortObject:
            return integer(value).flatMap { Int16(exactly: $0) } ?? value
        case .eByte, .eByteObject:
            return integer(value).flatMap { Int8(exactly: $0) } ?? value
        case .eDouble, .eDoubleObject:
            return real(value) ?? value
        case .eFloat, .eFloatObject:
            return real(value).map { Float($0) } ?? value
        case .eBigInteger:
            return integer(value).map { EBigInteger($0) } ?? value
        case .eBigDecimal:
            return real(value).map { Decimal($0) } ?? value
        case .eBoolean, .eBooleanObject:
            if let flag = value as? Bool { return flag }
            if let text = value as? String, let flag = Bool(text) { return flag }
            return value
        default:
            return value
        }
    }

    /// Whether two values are equal, treating numbers of different types as equal when
    /// they have the same value.
    ///
    /// - Parameters:
    ///   - lhs: The first value.
    ///   - rhs: The second value.
    /// - Returns: `true` if both are `nil` or they denote the same value.
    static func equal(_ lhs: (any EcoreValue)?, _ rhs: (any EcoreValue)?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let left?, let right?):
            if let a = integer(left), let b = integer(right), isIntegral(left), isIntegral(right) { return a == b }
            if isNumeric(left), isNumeric(right), let a = real(left), let b = real(right) { return a == b }
            if let a = left as? EcoreValueArray, let b = right as? EcoreValueArray {
                return a.values.count == b.values.count && zip(a.values, b.values).allSatisfy { equal($0, $1) }
            }
            if type(of: left) == type(of: right) { return areEqual(left, right) }
            return false
        }
    }

    /// The text that stands for a value in a string attribute.
    ///
    /// - Parameter value: The value.
    /// - Returns: Its text; reals with no fractional part keep a trailing `.0`, as in Java.
    static func text(of value: any EcoreValue) -> String {
        if let text = value as? String { return text }
        return String(describing: value)
    }

    /// Whether a value is a number.
    static func isNumeric(_ value: any EcoreValue) -> Bool {
        isIntegral(value) || value is Double || value is Float || value is Decimal
    }

    /// Whether a value is an integer number.
    static func isIntegral(_ value: any EcoreValue) -> Bool {
        value is Int || value is Int64 || value is Int16 || value is Int8 || value is EBigInteger
    }

    /// The integer that a value denotes, truncating reals towards zero as Java does.
    ///
    /// - Parameter value: The value.
    /// - Returns: The integer, or `nil` if the value is not a number or numeric text.
    static func integer(_ value: any EcoreValue) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Int64: return Int(exactly: number)
        case let number as Int16: return Int(number)
        case let number as Int8: return Int(number)
        case let number as EBigInteger: return Int(exactly: number)
        case let number as Double: return number.isFinite ? Int(exactly: number.rounded(.towardZero)) : nil
        case let number as Float: return number.isFinite ? Int(exactly: number.rounded(.towardZero)) : nil
        case let number as Decimal: return Int(exactly: NSDecimalNumber(decimal: number).doubleValue.rounded(.towardZero))
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The real number that a value denotes.
    ///
    /// - Parameter value: The value.
    /// - Returns: The real number, or `nil` if the value is not a number or numeric text.
    static func real(_ value: any EcoreValue) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Float: return Double(number)
        case let number as Decimal: return NSDecimalNumber(decimal: number).doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return integer(value).map(Double.init)
        }
    }
}
