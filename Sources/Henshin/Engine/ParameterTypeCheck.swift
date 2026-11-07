//
//  ParameterTypeCheck.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// Checks that the values a caller gives suit the declared data types of their parameters.
///
/// Henshin detects mistakes in the programmatic use of a transformation, such as text given
/// for an integer parameter, before they surface as failed matches. The check covers
/// parameters whose type is one of Ecore's text, Boolean, integer or real data types;
/// parameters of other types, such as classes, enumerations or dates, accept any value.
enum ParameterTypeCheck {
    /// Checks the values given for the parameters of a unit and converts them to the
    /// declared data types.
    ///
    /// A value that its data type admits is converted to that type, so that an `Int16`
    /// given for an `EInt` parameter takes part in expressions as an `Int`.
    ///
    /// - Parameters:
    ///   - values: The given values, by parameter name.
    ///   - parameters: The parameters of the unit; values of undeclared parameters are
    ///     returned unchanged.
    ///   - unit: The name of the unit, for the error.
    /// - Returns: The values, converted to the declared data types of their parameters.
    /// - Throws: ``HenshinError/parameterTypeMismatch(unit:parameter:expected:)`` for the
    ///   first value, in parameter order, that its parameter's data type does not admit.
    static func checked(_ values: ParameterValues, against parameters: [UnitParameter], of unit: String) throws -> ParameterValues {
        var result = values
        for parameter in parameters {
            guard let typeName = parameter.typeName, let value = values[parameter.name] else { continue }
            guard accepts(value, typeNamed: typeName) else {
                throw HenshinError.parameterTypeMismatch(unit: unit, parameter: parameter.name, expected: typeName)
            }
            if EcoreDataType(rawValue: typeName) != nil {
                result[parameter.name] = ValueSemantics.cast(value, toTypeNamed: typeName) ?? value
            }
        }
        return result
    }

    /// Whether a data type admits a value.
    ///
    /// Integer types admit integers of any width; real types admit any number; text types
    /// admit text; Boolean types admit Boolean values. No conversion between these kinds is
    /// made, so text that looks like a number is not a number.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - typeName: The name of the declared type, such as `EInt`.
    /// - Returns: `true` if the type admits the value or is not one of the checked types.
    static func accepts(_ value: any EcoreValue, typeNamed typeName: String) -> Bool {
        guard let type = EcoreDataType(rawValue: typeName) else { return true }
        switch type {
        case .eString, .eStringObject:
            return value is String
        case .eBoolean, .eBooleanObject:
            return value is Bool
        case .eInt, .eIntegerObject, .eLong, .eLongObject, .eShort, .eShortObject, .eByte, .eByteObject, .eBigInteger:
            return ValueSemantics.isIntegral(value)
        case .eDouble, .eDoubleObject, .eFloat, .eFloatObject, .eBigDecimal:
            return ValueSemantics.isNumeric(value)
        default:
            return true
        }
    }
}
