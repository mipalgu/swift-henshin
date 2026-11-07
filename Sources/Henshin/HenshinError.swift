//
//  HenshinError.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase
import Foundation

/// Errors raised while Henshin modules are loaded or applied.
public enum HenshinError: Error, Sendable, Equatable {
    /// The bundled Henshin metamodel could not be found among the resources of the package.
    case metamodelMissing
    /// The document holds no Henshin module.
    ///
    /// The associated value is the location of the document.
    case noModule(String)
    /// A reference of the document could not be resolved.
    ///
    /// The associated values name the referring element and describe the reference.
    case unresolvedReference(element: String, reference: String)
    /// A Henshin element is malformed, such as an edge whose end is not in its graph.
    ///
    /// The associated value describes the problem.
    case malformed(String)
    /// The module has no unit of the given name.
    case unknownUnit(String)
    /// A parameter that must be given before the unit is applied has no value.
    case missingParameter(unit: String, parameter: String)
    /// A value was given for a parameter that the unit does not declare or does not accept.
    case invalidParameter(unit: String, parameter: String)
    /// A value was given for a parameter whose declared data type does not admit it, such
    /// as text for an `EInt` parameter.
    ///
    /// The associated values name the unit, the parameter and the declared data type.
    case parameterTypeMismatch(unit: String, parameter: String, expected: String)
    /// An attribute expression uses JavaScript that cannot be translated.
    ///
    /// The associated values are the expression and the reason.
    case unsupportedExpression(expression: String, reason: String)
    /// An attribute expression could not be evaluated.
    ///
    /// The associated values are the expression and the reason.
    case evaluationFailed(expression: String, reason: String)
    /// An expression refers to a parameter that has no value when it is evaluated.
    case unboundParameter(expression: String, parameter: String)
    /// The model could not be changed as a rule demands.
    ///
    /// The associated values are the rule and the reason.
    case changeFailed(rule: String, reason: String)
    /// A Henshin Text document has errors, so that no module is read from it.
    ///
    /// The associated values are the location of the document and its error diagnostics,
    /// with their positions.
    case invalidText(document: String, diagnostics: [SourceDiagnostic])
}

extension HenshinError: CustomStringConvertible, LocalizedError {
    /// A sentence that describes the error.
    public var description: String {
        switch self {
        case .metamodelMissing:
            return "The Henshin metamodel is missing from the resources of the package"
        case .noModule(let location):
            return "\(location) holds no Henshin module"
        case .unresolvedReference(let element, let reference):
            return "Cannot resolve \(reference) of \(element)"
        case .malformed(let problem):
            return "Malformed Henshin element: \(problem)"
        case .unknownUnit(let name):
            return "The module has no unit named '\(name)'"
        case .missingParameter(let unit, let parameter):
            return "\(unit): parameter '\(parameter)' must be given a value"
        case .invalidParameter(let unit, let parameter):
            return "\(unit): parameter '\(parameter)' does not accept a value"
        case .parameterTypeMismatch(let unit, let parameter, let expected):
            return "\(unit): parameter '\(parameter)' expects a value of type \(expected)"
        case .unsupportedExpression(let expression, let reason):
            return "Unsupported expression '\(expression)': \(reason)"
        case .evaluationFailed(let expression, let reason):
            return "Cannot evaluate '\(expression)': \(reason)"
        case .unboundParameter(let expression, let parameter):
            return "Cannot evaluate '\(expression)': parameter '\(parameter)' has no value"
        case .changeFailed(let rule, let reason):
            return "Rule '\(rule)' cannot change the model: \(reason)"
        case .invalidText(let document, let diagnostics):
            let first = diagnostics.first.map { diagnostic in
                diagnostic.range.map { "\($0.start.line):\($0.start.column): " }.map { $0 + diagnostic.message } ?? diagnostic.message
            }
            return "\(document) is not valid Henshin Text (\(diagnostics.count) error(s))" + (first.map { "; \($0)" } ?? "")
        }
    }

    /// The ``description`` of the error.
    public var errorDescription: String? { description }
}

/// The codes of the diagnostics that the Henshin engine and validator report.
public enum HenshinDiagnosticCode: String, Sendable, Hashable, CaseIterable {
    /// An expression uses JavaScript that cannot be translated.
    case unsupportedExpression = "henshin.unsupported-expression"
    /// An expression refers to a name that is not a parameter.
    case unknownVariable = "henshin.unknown-variable"
    /// A mapping does not lead from the left-hand side to the right-hand side.
    case invalidMapping = "henshin.invalid-mapping"
    /// A rule creates a node of an abstract class.
    case abstractCreation = "henshin.abstract-creation"
    /// A rule changes a derived or unchangeable feature.
    case unchangeableFeature = "henshin.unchangeable-feature"
    /// An edge's type is not a reference of its source node's class.
    case invalidEdgeType = "henshin.invalid-edge-type"
    /// An attribute's feature is not an attribute of its node's class.
    case invalidAttributeType = "henshin.invalid-attribute-type"
    /// A unit refers to a sub-unit that is not in the module.
    case unknownSubUnit = "henshin.unknown-sub-unit"
    /// A unit declares two parameters of the same name.
    case duplicateParameter = "henshin.duplicate-parameter"
    /// Two rules or units have the same name and the same parameter list.
    case duplicateSignature = "henshin.duplicate-signature"
    /// A variable parameter of a rule occurs nowhere in its left-hand side, so matching can
    /// never give it a value.
    case varParameterNotInLeftSide = "henshin.var-parameter-not-in-lhs"
    /// A unit invokes a sub-unit without passing a value to one of the sub-unit's input or
    /// input-output parameters.
    case unpassedParameter = "henshin.unpassed-parameter"
    /// A rule deletes a node without deleting the containment edge that holds it, so that
    /// the dangling condition usually prevents its application.
    case deletionWithoutContainment = "henshin.deletion-without-containment"
    /// A graph of a rule holds a cycle of containment edges.
    case containmentCycle = "henshin.containment-cycle"
    /// An edge position is given; positions are read but not interpreted.
    case edgeIndexIgnored = "henshin.edge-index-ignored"
    /// A parameter is used nowhere: a rule parameter names no node and occurs in no
    /// attribute value, edge position or attribute condition, or a unit parameter takes
    /// part in no parameter mapping and no iteration count.
    case unusedParameter = "henshin.unused-parameter"
    /// Several mappings of one list lead from the same node into the same graph, or onto
    /// the same node from different nodes.
    case ambiguousMapping = "henshin.ambiguous-mapping"
    /// A mapping connects nodes of different classes, or, in a nested condition, of
    /// unrelated classes.
    case mappingTypeMismatch = "henshin.mapping-type-mismatch"
    /// A multi-mapping does not lead from the kernel rule's left-hand side to the
    /// multi-rule's left-hand side or from right-hand side to right-hand side, or a rule that
    /// is not a multi-rule has multi-mappings.
    case invalidMultiMapping = "henshin.invalid-multi-mapping"
    /// A mapping of a nested condition does not lead from the graph that holds the
    /// condition to its conclusion.
    case invalidConditionMapping = "henshin.invalid-condition-mapping"
    /// The right-hand side of a rule has an application condition, which is never checked.
    case rightSideFormula = "henshin.rhs-formula"
    /// A nested condition always holds or can never hold, so it decides nothing.
    case trivialCondition = "henshin.trivial-condition"
    /// A multi-rule repeats its kernel rule exactly and adds nothing to it.
    case redundantMultiRule = "henshin.redundant-multi-rule"
    /// A multi-rule preserves, deletes or creates a copy of a kernel edge differently from
    /// its kernel rule.
    case multiRuleEdgeMismatch = "henshin.multi-rule-edge-mismatch"
    /// A multi-rule declares a parameter of its kernel rule with another kind or type.
    case multiRuleParameterMismatch = "henshin.multi-rule-parameter-mismatch"
    /// An iterated unit gives no number of iterations.
    case emptyIterations = "henshin.empty-iterations"
    /// A parameter mapping refers to a unit that is neither its own unit nor a direct
    /// sub-unit of it, or to a parameter that unit does not declare.
    case invalidParameterMapping = "henshin.invalid-parameter-mapping"
    /// A module imports a metamodel package that none of its nodes uses.
    case unusedImport = "henshin.unused-import"
    /// A node's class belongs to a metamodel package that the module does not import.
    case missingImport = "henshin.missing-import"
    /// A sequential, priority or independent unit was rolled back.
    case rolledBack = "henshin.rolled-back"
    /// A loop or iteration stopped at the configured iteration limit.
    case iterationLimit = "henshin.iteration-limit"
    /// A model object is not a dynamic object and takes no part in matching.
    case foreignObject = "henshin.foreign-object"
}

extension SourceDiagnostic {
    /// Creates a diagnostic of the Henshin engine or validator.
    ///
    /// - Parameters:
    ///   - severity: How serious the finding is.
    ///   - code: The code that classifies the finding.
    ///   - message: A sentence that describes the finding.
    /// - Returns: The diagnostic, without a source range.
    static func henshin(_ severity: DiagnosticSeverity, _ code: HenshinDiagnosticCode, _ message: String) -> SourceDiagnostic {
        SourceDiagnostic(severity: severity, code: code.rawValue, message: message)
    }
}
