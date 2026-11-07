//
//  HenshinConstants.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore

/// The names that the Henshin transformation metamodel and its bundled resources define.
///
/// Every class, feature and literal name of the Henshin metamodel that the module reader
/// relies on is declared here, so that the reader never spells a metamodel name itself.
public enum HenshinConstants {
    /// The namespace URI of the Henshin transformation metamodel.
    public static let nsURI = "http://www.eclipse.org/emf/2011/Henshin"

    /// The conventional file extension of documents that hold Henshin modules.
    public static let fileExtension = "henshin"

    /// The name of the bundled Henshin metamodel document, without its extension.
    static let metamodelResourceName = "henshin"

    /// The directory of the target's resource bundle that holds the bundled documents.
    static let resourceSubdirectory = "Resources"

    /// The name of the package that ships the bundled resources, as its manifest gives it.
    ///
    /// The package manager names the resource directory of a target after this name and the
    /// name of the target, and that directory is looked up by name where no resource bundle
    /// is available, such as on WASI.
    static let resourcePackageName = "swift-henshin"

    /// The name of the target that ships the bundled resources.
    static let resourceTargetName = "Henshin"

    /// The fragment that names the root package of a metamodel document.
    static let rootFragment = "/"

    /// The separator between the segments of a name-based fragment such as `//Bank/clients`.
    static let fragmentSeparator: Character = "/"

    /// The Ecore feature that holds the namespace URI of a package.
    static let nsURIFeature = "nsURI"

    /// The separator between a document URI and the fragment of an object within it.
    static let fragmentMarker: Character = "#"

    /// The names of the classes of the Henshin metamodel.
    public enum ClassName {
        /// A module, the root of a Henshin document.
        public static let module = "Module"
        /// A rule.
        public static let rule = "Rule"
        /// A unit that applies one of its sub-units, chosen at random.
        public static let independentUnit = "IndependentUnit"
        /// A unit that applies its sub-units in order.
        public static let sequentialUnit = "SequentialUnit"
        /// A unit that branches on the success of a condition unit.
        public static let conditionalUnit = "ConditionalUnit"
        /// A unit that applies the first applicable sub-unit.
        public static let priorityUnit = "PriorityUnit"
        /// A unit that applies its sub-unit a given number of times.
        public static let iteratedUnit = "IteratedUnit"
        /// A unit that applies its sub-unit for as long as possible.
        public static let loopUnit = "LoopUnit"
        /// A nested graph condition.
        public static let nestedCondition = "NestedCondition"
        /// A negated formula.
        public static let not = "Not"
        /// A conjunction of formulas.
        public static let and = "And"
        /// A disjunction of formulas.
        public static let or = "Or"
        /// An exclusive disjunction of formulas.
        public static let xor = "Xor"
        /// The formula that always holds.
        public static let `true` = "True"
    }

    /// The names of the structural features of the Henshin metamodel.
    public enum FeatureName {
        /// The name of a named element.
        public static let name = "name"
        /// The description of a named element.
        public static let description = "description"
        /// The units of a module.
        public static let units = "units"
        /// The nested modules of a module.
        public static let subModules = "subModules"
        /// The metamodel packages that a module imports.
        public static let imports = "imports"
        /// The parameters of a unit.
        public static let parameters = "parameters"
        /// The parameter mappings of a unit.
        public static let parameterMappings = "parameterMappings"
        /// Whether a unit is activated.
        public static let activated = "activated"
        /// The kind of a parameter.
        public static let kind = "kind"
        /// The type of a parameter, node, edge or attribute.
        public static let type = "type"
        /// The source of an edge or parameter mapping.
        public static let source = "source"
        /// The target of an edge or parameter mapping.
        public static let target = "target"
        /// The left-hand side of a rule.
        public static let lhs = "lhs"
        /// The right-hand side of a rule.
        public static let rhs = "rhs"
        /// The attribute conditions of a rule.
        public static let attributeConditions = "attributeConditions"
        /// The mappings of a rule or nested condition.
        public static let mappings = "mappings"
        /// Whether a rule checks the dangling condition.
        public static let checkDangling = "checkDangling"
        /// Whether a rule matches injectively.
        public static let injectiveMatching = "injectiveMatching"
        /// The multi-rules of a rule.
        public static let multiRules = "multiRules"
        /// The multi-mappings of a multi-rule.
        public static let multiMappings = "multiMappings"
        /// The condition text of an attribute condition.
        public static let conditionText = "conditionText"
        /// The nodes of a graph.
        public static let nodes = "nodes"
        /// The edges of a graph.
        public static let edges = "edges"
        /// The formula of a graph.
        public static let formula = "formula"
        /// The attributes of a node.
        public static let attributes = "attributes"
        /// The value expression of an attribute.
        public static let value = "value"
        /// Whether an attribute stands for the null value.
        public static let null = "null"
        /// The position expression of an edge.
        public static let index = "index"
        /// The constant position of an edge.
        public static let indexConstant = "indexConstant"
        /// The origin of a mapping.
        public static let origin = "origin"
        /// The image of a mapping.
        public static let image = "image"
        /// The conclusion graph of a nested condition.
        public static let conclusion = "conclusion"
        /// The operand of a unary formula.
        public static let child = "child"
        /// The left operand of a binary formula.
        public static let left = "left"
        /// The right operand of a binary formula.
        public static let right = "right"
        /// The sub-unit of a unary unit.
        public static let subUnit = "subUnit"
        /// The sub-units of a multi-unit.
        public static let subUnits = "subUnits"
        /// Whether a sequential or iterated unit fails when a sub-unit fails.
        public static let strict = "strict"
        /// Whether a failing strict unit undoes its changes.
        public static let rollback = "rollback"
        /// The condition unit of a conditional unit.
        public static let `if` = "if"
        /// The unit applied when the condition of a conditional unit succeeds.
        public static let then = "then"
        /// The unit applied when the condition of a conditional unit fails.
        public static let `else` = "else"
        /// The number of iterations of an iterated unit.
        public static let iterations = "iterations"
        /// The Java packages that a rule imports.
        public static let javaImports = "javaImports"
    }

    /// The default values that the Henshin metamodel declares for optional features.
    public enum Defaults {
        /// Whether a rule checks the dangling condition unless stated otherwise.
        public static let checkDangling = true
        /// Whether a rule matches injectively unless stated otherwise.
        public static let injectiveMatching = true
        /// Whether a unit is activated unless stated otherwise.
        public static let activated = true
        /// Whether a sequential unit is strict unless stated otherwise.
        public static let sequentialStrict = true
        /// Whether a sequential unit rolls back unless stated otherwise.
        public static let sequentialRollback = true
        /// Whether an iterated unit is strict unless stated otherwise.
        public static let iteratedStrict = false
        /// Whether an iterated unit rolls back unless stated otherwise.
        public static let iteratedRollback = true
    }

    /// The text that an attribute value uses for the null value.
    static let nullLiteral = "null"

    /// The names of the Ecore data types that the value conversions recognise.
    typealias DataType = EcoreDataType
}
