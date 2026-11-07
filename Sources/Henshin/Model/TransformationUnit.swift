//
//  TransformationUnit.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore

/// The direction in which a parameter passes values into or out of a unit.
public enum ParameterKind: String, Sendable, Hashable, CaseIterable {
    /// A parameter of unspecified direction, as in documents written before kinds existed.
    case unknown = "UNKNOWN"
    /// A parameter whose value must be given before the unit is applied.
    case `in` = "IN"
    /// A parameter whose value the unit computes.
    case out = "OUT"
    /// A parameter whose value must be given and that the unit may change.
    case `inout` = "INOUT"
    /// A variable of the unit, neither given nor returned.
    case `var` = "VAR"

    /// Whether a value must be given for the parameter before the unit is applied.
    public var isRequired: Bool { self == .in || self == .inout }

    /// Whether the value of the parameter is kept in the result of a unit application.
    ///
    /// As in Henshin, the results of composite units keep only output, input-output and
    /// variable parameters; rules keep all of them.
    public var isKeptInResult: Bool { self == .out || self == .inout || self == .var }

    /// Whether a caller may give a value for the parameter.
    public var acceptsInput: Bool { self != .out && self != .var }

    /// Whether the value of the parameter is reported to the caller of a unit.
    ///
    /// The values of variable parameters are hidden from the outside world: they are
    /// local to the rule or unit that declares them and to the parameter mappings within
    /// its parent unit. All other parameters may pass values between units and back to
    /// the caller.
    public var isVisibleToCaller: Bool { self != .var }
}

/// A parameter of a rule or unit.
public struct UnitParameter: Sendable, Hashable {
    /// The name of the parameter.
    public var name: String

    /// The direction of the parameter.
    public var kind: ParameterKind

    /// The name of the parameter's type, if it declares one.
    ///
    /// For a parameter that passes a model object, this is the name of a class; for one that
    /// passes a value, the name of a data type such as `EInt`.
    public var typeName: String?

    /// Creates a parameter.
    ///
    /// - Parameters:
    ///   - name: The name of the parameter.
    ///   - kind: The direction of the parameter (default ``ParameterKind/unknown``).
    ///   - typeName: The name of the parameter's type, if any.
    public init(name: String, kind: ParameterKind = .unknown, typeName: String? = nil) {
        self.name = name
        self.kind = kind
        self.typeName = typeName
    }
}

/// A condition on the parameter values of a rule.
public struct AttributeCondition: Sendable, Hashable {
    /// The name of the condition, if it has one.
    public var name: String?

    /// The Boolean expression that must hold, in the JavaScript subset of
    /// ``JavaScriptTranslator``.
    public var conditionText: String

    /// Creates an attribute condition.
    ///
    /// - Parameters:
    ///   - name: The name of the condition, if any.
    ///   - conditionText: The Boolean expression that must hold.
    public init(name: String? = nil, conditionText: String) {
        self.name = name
        self.conditionText = conditionText
    }
}

/// A transformation rule: a left-hand side to find and a right-hand side to produce.
///
/// Nodes and edges of the left-hand side without a counterpart on the right are deleted;
/// those of the right-hand side without a counterpart on the left are created; mapped ones
/// are preserved. A rule may contain multi-rules, which are applied at every match that
/// extends the match of the rule (amalgamation).
public struct Rule: Sendable {
    /// The name of the rule.
    public var name: String

    /// The description of the rule, if any.
    public var description: String?

    /// The parameters of the rule.
    public var parameters: [UnitParameter]

    /// The left-hand side, together with its application conditions.
    public var lhs: RuleGraph

    /// The right-hand side.
    public var rhs: RuleGraph

    /// The mappings from the left-hand side to the right-hand side.
    public var mappings: [NodeMapping]

    /// The conditions on the parameter values of the rule.
    public var attributeConditions: [AttributeCondition]

    /// Whether the rule is only applicable if deleting nodes leaves no dangling reference.
    public var checkDangling: Bool

    /// Whether different nodes must match different objects.
    public var injectiveMatching: Bool

    /// The multi-rules that are applied at every extension of a match of this rule.
    public var multiRules: [Rule]

    /// For a multi-rule, the mappings from the nodes of its kernel rule to its own nodes.
    ///
    /// They lead from left-hand side to left-hand side and from right-hand side to
    /// right-hand side.
    public var multiMappings: [NodeMapping]

    /// Whether the rule takes part in transformations; an inactive rule succeeds without
    /// effect.
    public var isActivated: Bool

    /// The Java packages that the rule's expressions import, such as `java.lang.Math`.
    ///
    /// They are kept so that a document can be written again; Java calls are not
    /// interpreted.
    public var javaImports: [String]

    /// Creates a rule.
    ///
    /// - Parameters:
    ///   - name: The name of the rule.
    ///   - description: The description of the rule, if any.
    ///   - parameters: The parameters of the rule.
    ///   - lhs: The left-hand side.
    ///   - rhs: The right-hand side.
    ///   - mappings: The mappings from the left-hand side to the right-hand side.
    ///   - attributeConditions: The conditions on parameter values.
    ///   - checkDangling: Whether to check the dangling condition (default `true`).
    ///   - injectiveMatching: Whether to match injectively (default `true`).
    ///   - multiRules: The multi-rules of the rule.
    ///   - multiMappings: For a multi-rule, the mappings from its kernel rule.
    ///   - isActivated: Whether the rule is active (default `true`).
    ///   - javaImports: The Java packages that the rule imports (default none).
    public init(
        name: String, description: String? = nil, parameters: [UnitParameter] = [], lhs: RuleGraph,
        rhs: RuleGraph, mappings: [NodeMapping] = [], attributeConditions: [AttributeCondition] = [],
        checkDangling: Bool = HenshinConstants.Defaults.checkDangling,
        injectiveMatching: Bool = HenshinConstants.Defaults.injectiveMatching, multiRules: [Rule] = [],
        multiMappings: [NodeMapping] = [], isActivated: Bool = HenshinConstants.Defaults.activated,
        javaImports: [String] = []
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.lhs = lhs
        self.rhs = rhs
        self.mappings = mappings
        self.attributeConditions = attributeConditions
        self.checkDangling = checkDangling
        self.injectiveMatching = injectiveMatching
        self.multiRules = multiRules
        self.multiMappings = multiMappings
        self.isActivated = isActivated
        self.javaImports = javaImports
    }

    /// Finds a parameter of the rule by name.
    ///
    /// - Parameter name: The name of the parameter.
    /// - Returns: The parameter, or `nil` if the rule has none of that name.
    public func parameter(named name: String) -> UnitParameter? {
        parameters.first { $0.name == name }
    }

    /// The right-hand side node that a left-hand side node is mapped to, if any.
    ///
    /// - Parameter lhsNode: A node of the left-hand side.
    /// - Returns: The image of the node, or `nil` if the rule deletes it.
    public func image(of lhsNode: NodeID) -> NodeID? {
        mappings.first { $0.origin == lhsNode }?.image
    }

    /// The left-hand side node that a right-hand side node is mapped from, if any.
    ///
    /// - Parameter rhsNode: A node of the right-hand side.
    /// - Returns: The origin of the node, or `nil` if the rule creates it.
    public func origin(of rhsNode: NodeID) -> NodeID? {
        mappings.first { $0.image == rhsNode }?.origin
    }
}

/// The identity of a unit within a ``HenshinModule``.
public struct UnitID: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The position of the unit in the module's list of units.
    public let rawValue: Int

    /// Creates a unit identity.
    ///
    /// - Parameter rawValue: The position of the unit in its module's list of units.
    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Orders unit identities by position.
    ///
    /// - Parameters:
    ///   - lhs: The first identity.
    ///   - rhs: The second identity.
    /// - Returns: `true` if the first identity comes before the second.
    public static func < (lhs: UnitID, rhs: UnitID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The position of the unit, prefixed with `unit`.
    public var description: String { "unit\(rawValue)" }
}

/// A reference to a parameter of a particular unit.
public struct ParameterReference: Sendable, Hashable {
    /// The unit that declares the parameter.
    public var unit: UnitID

    /// The name of the parameter.
    public var name: String

    /// Creates a parameter reference.
    ///
    /// - Parameters:
    ///   - unit: The unit that declares the parameter.
    ///   - name: The name of the parameter.
    public init(unit: UnitID, name: String) {
        self.unit = unit
        self.name = name
    }
}

/// A mapping that passes a parameter value between a unit and one of its sub-units.
public struct ParameterMapping: Sendable, Hashable {
    /// The parameter whose value is passed.
    public var source: ParameterReference

    /// The parameter that receives the value.
    public var target: ParameterReference

    /// Creates a parameter mapping.
    ///
    /// - Parameters:
    ///   - source: The parameter whose value is passed.
    ///   - target: The parameter that receives the value.
    public init(source: ParameterReference, target: ParameterReference) {
        self.source = source
        self.target = target
    }
}

/// What a transformation unit does.
public enum UnitKind: Sendable {
    /// A rule.
    case rule(Rule)
    /// Applies one applicable sub-unit, tried in random order (or in order when matching
    /// deterministically).
    case independent([UnitID])
    /// Applies the sub-units in order.
    ///
    /// A strict unit fails as soon as a sub-unit fails and, if it rolls back, undoes what it
    /// changed.
    case sequential([UnitID], strict: Bool, rollback: Bool)
    /// Applies the then-unit if the condition unit succeeds, and the else-unit otherwise.
    case conditional(if: UnitID, then: UnitID, else: UnitID?)
    /// Applies the first sub-unit that succeeds.
    case priority([UnitID])
    /// Applies the sub-unit a number of times given by an expression.
    case iterated(UnitID, iterations: String, strict: Bool, rollback: Bool)
    /// Applies the sub-unit for as long as it succeeds.
    case loop(UnitID)

    /// The sub-units that the unit applies, in order.
    public var subUnits: [UnitID] {
        switch self {
        case .rule: return []
        case .independent(let units), .priority(let units), .sequential(let units, _, _): return units
        case .conditional(let condition, let then, let otherwise): return [condition, then] + (otherwise.map { [$0] } ?? [])
        case .iterated(let unit, _, _, _), .loop(let unit): return [unit]
        }
    }

    /// The name of the Henshin class of the unit, such as `SequentialUnit`.
    public var className: String {
        switch self {
        case .rule: return HenshinConstants.ClassName.rule
        case .independent: return HenshinConstants.ClassName.independentUnit
        case .sequential: return HenshinConstants.ClassName.sequentialUnit
        case .conditional: return HenshinConstants.ClassName.conditionalUnit
        case .priority: return HenshinConstants.ClassName.priorityUnit
        case .iterated: return HenshinConstants.ClassName.iteratedUnit
        case .loop: return HenshinConstants.ClassName.loopUnit
        }
    }
}

/// A transformation unit: a rule or a control structure over other units.
public struct TransformationUnit: Sendable, Identifiable {
    /// The identity of the unit within its module.
    public let id: UnitID

    /// The name of the unit.
    public var name: String

    /// The description of the unit, if any.
    public var description: String?

    /// The parameters of the unit.
    public var parameters: [UnitParameter]

    /// The mappings that pass parameter values to and from the sub-units.
    public var parameterMappings: [ParameterMapping]

    /// Whether the unit takes part in transformations; an inactive unit succeeds without
    /// effect.
    public var isActivated: Bool

    /// What the unit does.
    public var kind: UnitKind

    /// Creates a unit.
    ///
    /// - Parameters:
    ///   - id: The identity of the unit within its module.
    ///   - name: The name of the unit.
    ///   - description: The description of the unit, if any.
    ///   - parameters: The parameters of the unit.
    ///   - parameterMappings: The mappings to and from its sub-units.
    ///   - isActivated: Whether the unit is active (default `true`).
    ///   - kind: What the unit does.
    public init(
        id: UnitID, name: String, description: String? = nil, parameters: [UnitParameter] = [],
        parameterMappings: [ParameterMapping] = [], isActivated: Bool = HenshinConstants.Defaults.activated,
        kind: UnitKind
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.parameterMappings = parameterMappings
        self.isActivated = isActivated
        self.kind = kind
    }

    /// Creates the unit of a rule, with the rule's name, parameters and activation.
    ///
    /// - Parameters:
    ///   - id: The identity of the unit within its module.
    ///   - rule: The rule.
    public init(id: UnitID, rule: Rule) {
        self.init(
            id: id, name: rule.name, description: rule.description, parameters: rule.parameters,
            isActivated: rule.isActivated, kind: .rule(rule))
    }

    /// The rule of the unit, if the unit is a rule.
    public var rule: Rule? {
        if case .rule(let rule) = kind { return rule }
        return nil
    }

    /// Finds a parameter of the unit by name.
    ///
    /// - Parameter name: The name of the parameter.
    /// - Returns: The parameter, or `nil` if the unit has none of that name.
    public func parameter(named name: String) -> UnitParameter? {
        parameters.first { $0.name == name }
    }
}

/// A Henshin module: the transformation units of a Henshin document.
///
/// Units of nested modules are flattened into ``units``; their names stay as they are.
public struct HenshinModule: Sendable {
    /// The name of the module, if it has one.
    public var name: String?

    /// The description of the module, if any.
    public var description: String?

    /// The namespace URIs of the metamodels that the module imports.
    public var imports: [String]

    /// All units of the module and its nested modules, in document order.
    ///
    /// The identity of each unit is its position in this list.
    public var units: [TransformationUnit]

    /// Creates a module.
    ///
    /// - Parameters:
    ///   - name: The name of the module, if any.
    ///   - description: The description of the module, if any.
    ///   - imports: The namespace URIs of the imported metamodels.
    ///   - units: The units, whose identities must be their positions in the list.
    public init(name: String? = nil, description: String? = nil, imports: [String] = [], units: [TransformationUnit] = []) {
        self.name = name
        self.description = description
        self.imports = imports
        self.units = units
    }

    /// Creates a module of rules, each of which becomes a unit.
    ///
    /// - Parameters:
    ///   - name: The name of the module, if any.
    ///   - rules: The rules, in order.
    public init(name: String? = nil, rules: [Rule]) {
        self.init(name: name, units: rules.enumerated().map { TransformationUnit(id: UnitID($0.offset), rule: $0.element) })
    }

    /// Looks a unit up by identity.
    ///
    /// - Parameter id: The identity of the unit.
    /// - Returns: The unit, or `nil` if the module has no unit with the identity.
    public func unit(_ id: UnitID) -> TransformationUnit? {
        units.indices.contains(id.rawValue) ? units[id.rawValue] : nil
    }

    /// Looks a unit up by name.
    ///
    /// - Parameter name: The name of the unit.
    /// - Returns: The first unit with the name, or `nil` if there is none.
    public func unit(named name: String) -> TransformationUnit? {
        units.first { $0.name == name }
    }

    /// All rules of the module, in document order.
    public var rules: [Rule] { units.compactMap(\.rule) }
}
