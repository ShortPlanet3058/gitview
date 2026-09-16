import Foundation
import SwiftTreeSitter
import TreeSitterSwift

/// The tree-sitter Swift grammar, plus the query used to locate code units.
public enum SwiftLanguage {
    public static let language = Language(language: tree_sitter_swift())

    /// Captures every declaration that becomes a `CodeUnit`.
    ///
    /// A query rather than a hand-rolled tree walk: the grammar's shape is the grammar's
    /// business, and a walk would have to be re-audited every time it changes.
    ///
    /// Note `class_declaration` in this grammar covers class / struct / enum / actor /
    /// extension, distinguished by the `declaration_kind` field — there is no separate
    /// `struct_declaration` node.
    static let unitQuerySource = """
    (function_declaration) @unit.function
    (init_declaration) @unit.init
    (deinit_declaration) @unit.deinit
    (subscript_declaration) @unit.subscript
    (class_declaration) @unit.type
    (protocol_declaration) @unit.protocol

    ; Computed properties are ordinary code and routinely contain branches. Matching on
    ; the `computed_value` field excludes stored properties, which have `value:` instead.
    (property_declaration computed_value: (computed_property)) @unit.property
    """

    static func makeUnitQuery() throws -> Query {
        try Query(language: language, data: Data(unitQuerySource.utf8))
    }
}

enum SwiftNodeType {
    /// Nodes that introduce a decision point.
    ///
    /// The spec listed if/guard/for/while/switch-case/catch/ternary/`&&`. Two additions:
    /// `||` (`disjunction_expression`) is a short-circuit branch exactly as `&&` is, and
    /// `??` (`nil_coalescing_expression`) is Swift's most common implicit branch — omitting
    /// it would systematically under-rate optional-heavy code.
    static let branching: Set<String> = [
        "if_statement",
        "guard_statement",
        "for_statement",
        "while_statement",
        "repeat_while_statement",
        "catch_block",
        "ternary_expression",
        "conjunction_expression",      // &&
        "disjunction_expression",      // ||
        "nil_coalescing_expression",   // ??
    ]

    /// Nodes that add a level of nesting.
    ///
    /// `guard_statement` is deliberately absent. A guard is an early exit: its body does
    /// not contain the code that follows, so counting it as nesting would penalise exactly
    /// the idiom that *reduces* nesting in Swift. It still counts toward complexity above.
    static let nesting: Set<String> = [
        "if_statement",
        "for_statement",
        "while_statement",
        "repeat_while_statement",
        "switch_statement",
        "do_statement",
        "catch_block",
        "lambda_literal",              // trailing / inline closures
    ]

    /// Bodies whose direct declarations are methods rather than free functions.
    static let typeBodies: Set<String> = [
        "class_body",
        "enum_class_body",
        "protocol_body",
    ]

    static let typeDeclarations: Set<String> = [
        "class_declaration",
        "protocol_declaration",
    ]
}

extension SwiftLanguage {
    /// Development aid for checking query patterns against the real grammar output.
    public static func sExpression(of source: String) -> String? {
        let parser = Parser()
        try? parser.setLanguage(language)
        return parser.parse(source)?.rootNode?.sExpressionString
    }
}
