//
//  HenshinTextConstants.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase

/// The names, keywords and conventions of Henshin Text, the textual syntax of Henshin.
///
/// Every keyword, symbol and generated name that the reader and writer of Henshin Text rely
/// on is declared here, so that neither spells them itself.
public enum HenshinTextConstants {
    /// The conventional file extension of Henshin Text documents.
    public static let fileExtension = "henshin_text"

    /// The name that a module read from Henshin Text receives, as in Henshin.
    public static let moduleName = "HenshinDSL"

    /// The suffix of the name of a rule's left-hand side, appended to the rule name.
    static let leftSideSuffix = "_LHS"

    /// The suffix of the name of a rule's right-hand side, appended to the rule name.
    static let rightSideSuffix = "_RHS"

    /// The character that marks an identifier that would otherwise be a keyword.
    static let escape: Character = "^"

    /// The separator of the segments of a qualified name such as `bank.Account`.
    static let qualifier: Character = "."

    /// The type that the writer gives to a parameter whose type it cannot determine.
    static let fallbackParameterType = "EJavaObject"

    /// The keywords of Henshin Text, which an identifier can only use when escaped with `^`.
    public enum Keyword {
        /// Imports a metamodel package by name.
        public static let ePackageImport = "ePackageImport"
        /// Declares a rule.
        public static let rule = "rule"
        /// Declares a unit.
        public static let unit = "unit"
        /// Imports a Java package for a rule.
        public static let javaImport = "javaImport"
        /// Sets whether a rule checks the dangling condition.
        public static let checkDangling = "checkDangling"
        /// Sets whether a rule matches injectively.
        public static let injectiveMatching = "injectiveMatching"
        /// Lists the attribute conditions of a rule.
        public static let conditions = "conditions"
        /// Opens the graph of a rule.
        public static let graph = "graph"
        /// Marks an element that a rule keeps.
        public static let preserve = "preserve"
        /// Marks an element that a rule creates.
        public static let create = "create"
        /// Marks an element that a rule deletes.
        public static let delete = "delete"
        /// Marks an element that must not exist for a rule to apply.
        public static let forbid = "forbid"
        /// Marks an element that must exist for a rule to apply.
        public static let require = "require"
        /// Lists edges.
        public static let edges = "edges"
        /// Declares a node.
        public static let node = "node"
        /// Refers to a node of an enclosing graph.
        public static let reuse = "reuse"
        /// Changes the value of a kept attribute.
        public static let set = "set"
        /// Declares a multi-rule.
        public static let multiRule = "multiRule"
        /// Opens an application condition built from condition graphs.
        public static let matchingFormula = "matchingFormula"
        /// Introduces the logical formula of an application condition.
        public static let formula = "formula"
        /// Declares a condition graph.
        public static let conditionGraph = "conditionGraph"
        /// The disjunction of a formula.
        public static let or = "OR"
        /// The exclusive disjunction of a formula.
        public static let xor = "XOR"
        /// The conjunction of a formula or expression.
        public static let and = "AND"
        /// Sets whether a sequence fails when a step fails.
        public static let strict = "strict"
        /// Sets whether a failing strict sequence undoes its changes.
        public static let rollback = "rollback"
        /// Applies one of several alternatives.
        public static let independent = "independent"
        /// Opens a conditional unit.
        public static let `if` = "if"
        /// Introduces the branch of a conditional unit taken on success.
        public static let then = "then"
        /// Introduces the branch of a conditional unit taken on failure.
        public static let `else` = "else"
        /// Applies the first applicable alternative.
        public static let priority = "priority"
        /// Repeats a block a given number of times.
        public static let `for` = "for"
        /// Repeats a block for as long as it succeeds.
        public static let `while` = "while"
        /// The truth value true.
        public static let `true` = "true"
        /// The truth value false.
        public static let `false` = "false"
    }

    /// The data types that Henshin Text names by keyword as parameter types.
    public static let dataTypes: [String] = [
        "EBigDecimal", "EBigInteger", "EBoolean", "EBooleanObject", "EByte", "EByteArray", "EByteObject", "EChar",
        "ECharacterObject", "EDate", "EDiagnosticChain", "EDouble", "EDoubleObject", "EEList", "EEnumerator", "EFeatureMap",
        "EFeatureMapEntry", "EFloat", "EFloatObject", "EInt", "EIntegerObject", "ETreeIterator", "EInvocationTargetException",
        "EJavaClass", "EJavaObject", "ELong", "ELongObject", "EMap", "EResource", "EResourceSet", "EShort", "EShortObject",
        "EString",
    ]

    /// The parameter kinds that Henshin Text names by keyword.
    static let parameterKinds: [String: ParameterKind] = ["IN": .in, "OUT": .out, "INOUT": .inout, "VAR": .var]

    /// The actions of nodes, edges and attributes, by keyword.
    static let actions: [String] = [
        Keyword.preserve, Keyword.create, Keyword.delete, Keyword.forbid, Keyword.require,
    ]

    /// All reserved words of Henshin Text.
    public static let keywords: Set<String> = Set(
        [
            Keyword.ePackageImport, Keyword.rule, Keyword.unit, Keyword.javaImport, Keyword.checkDangling,
            Keyword.injectiveMatching, Keyword.conditions, Keyword.graph, Keyword.edges, Keyword.node, Keyword.reuse,
            Keyword.set, Keyword.multiRule, Keyword.matchingFormula, Keyword.formula, Keyword.conditionGraph, Keyword.or,
            Keyword.xor, Keyword.and, Keyword.strict, Keyword.rollback, Keyword.independent, Keyword.if, Keyword.then,
            Keyword.else, Keyword.priority, Keyword.for, Keyword.while, Keyword.true, Keyword.false,
        ] + actions + dataTypes + parameterKinds.keys)

    /// The infixes of the names of the units that Henshin Text introduces for nested
    /// blocks, after the name of the enclosing unit.
    enum AuxiliaryUnit {
        /// A block within a sequence.
        static let sequence = "Sequence"
        /// The condition of a conditional unit.
        static let `if` = "IF"
        /// The success branch of a conditional unit.
        static let then = "THEN"
        /// The failure branch of a conditional unit.
        static let `else` = "ELSE"
        /// The body of an iterated unit.
        static let iterated = "ITERATED"
        /// The body of a loop unit.
        static let loop = "LOOP"
        /// An alternative of a priority unit.
        static let priority = "PRIORITY"
        /// An alternative of an independent unit.
        static let independent = "INDEPENDENT"
    }

    /// The symbols of Henshin Text, longest first.
    static let symbols = ["->", "==", "!=", ">=", "<=", "(", ")", "{", "}", "[", "]", ",", ":", ".", "=", ">", "<", "+", "-", "*", "/", "!"]

    /// The text of an expression operator in Henshin Text and the JavaScript operator it
    /// stands for, where they differ.
    static let logicalOperators: [String: String] = [Keyword.or: "||", Keyword.and: "&&"]
}

/// The kinds of node in the outline of a Henshin Text document.
///
/// The kinds are the values of `OutlineNode.kind` in the outline that
/// ``HenshinTextParseResult`` carries.
public enum HenshinTextOutlineKind {
    /// A metamodel import.
    public static let `import` = "import"
    /// A rule.
    public static let rule = "rule"
    /// A unit.
    public static let unit = "unit"
    /// A multi-rule within a rule.
    public static let multiRule = "multiRule"
    /// A node of a rule graph.
    public static let node = "node"
    /// A condition graph of an application condition.
    public static let conditionGraph = "conditionGraph"
}

/// The stable codes of the diagnostics that reading and writing Henshin Text report.
///
/// Each code is a dotted identifier that tools can match on without depending on the
/// wording of a message.
public enum HenshinTextDiagnosticCode: String, Sendable, CaseIterable, Hashable {
    /// A character cannot start any token.
    case unexpectedCharacter = "henshin-text.unexpected-character"
    /// A string literal or comment has no end.
    case unterminated = "henshin-text.unterminated"
    /// A token appears where the grammar does not allow it.
    case unexpectedToken = "henshin-text.unexpected-token"
    /// A name refers to no metamodel package, class, attribute or reference.
    case unknownMetamodelElement = "henshin-text.unknown-metamodel-element"
    /// A name refers to no node, parameter, condition graph, rule or unit.
    case unknownName = "henshin-text.unknown-name"
    /// Two elements of the same scope share a name.
    case duplicateName = "henshin-text.duplicate-name"
    /// A rule has no graph, or more than one.
    case graphCount = "henshin-text.graph-count"
    /// An option, condition list or matching formula is given more than once.
    case repeatedElement = "henshin-text.repeated-element"
    /// The actions of an element and of its nodes do not fit together.
    case actionMismatch = "henshin-text.action-mismatch"
    /// A `set` attribute has no kept attribute whose value it changes.
    case setWithoutPreserve = "henshin-text.set-without-preserve"
    /// A call passes a number of arguments that differs from the number of parameters of
    /// the called unit that are not variables.
    case argumentCount = "henshin-text.argument-count"
    /// A parameter has no kind, which Henshin deprecates.
    case missingParameterKind = "henshin-text.missing-parameter-kind"
    /// A node of an abstract class or interface is created.
    case abstractCreation = "henshin-text.abstract-creation"
    /// The writer cannot express part of a module in Henshin Text.
    case notExpressible = "henshin-text.not-expressible"
    /// The writer changed the module to express it, such as by adding a parameter.
    case adjusted = "henshin-text.adjusted"
}

/// The diagnostics of reading and writing Henshin Text.
extension SourceDiagnostic {
    /// Creates a diagnostic of Henshin Text.
    ///
    /// - Parameters:
    ///   - severity: How serious the finding is.
    ///   - code: The code that classifies the finding.
    ///   - message: A sentence that describes the finding.
    ///   - range: The range of the source that the finding concerns, if any.
    /// - Returns: The diagnostic.
    static func henshinText(
        _ severity: DiagnosticSeverity, _ code: HenshinTextDiagnosticCode, _ message: String, at range: SourceRange? = nil
    ) -> SourceDiagnostic {
        SourceDiagnostic(severity: severity, code: code.rawValue, message: message, range: range)
    }
}
