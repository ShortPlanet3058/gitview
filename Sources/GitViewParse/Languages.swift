import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterPython
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterJava
import TreeSitterRust
import TreeSitterGo
import TreeSitterRuby
import TreeSitterPHP
import TreeSitterKotlin
import TreeSitterCSS

extension LanguageSupport {
    public static let all: [LanguageSupport] = [
        .swift, .c, .cpp, .cSharp, .python, .javascript, .typescript, .tsx,
        .java, .rust, .go, .ruby, .php, .kotlin, .css,
    ]

    // Operators shared by the C family.
    private static let cLikeLogical: Set<String> = ["&&", "||", "??"]

    // MARK: Swift

    public static let swift = LanguageSupport(
        id: "swift", displayName: "Swift", extensions: ["swift"],
        makeLanguage: { Language(language: tree_sitter_swift()) },
        unitQuery: """
        (function_declaration) @unit.function
        ; init/deinit/subscript have no name field, so the keyword itself is the name.
        (init_declaration "init" @name) @unit.method
        (deinit_declaration "deinit" @name) @unit.method
        (subscript_declaration "subscript" @name) @unit.method
        (class_declaration) @unit.type
        (protocol_declaration) @unit.type
        (property_declaration computed_value: (computed_property)) @unit.method
        """,
        branching: ["if_statement", "guard_statement", "for_statement", "while_statement",
                    "repeat_while_statement", "catch_block", "ternary_expression",
                    "conjunction_expression", "disjunction_expression", "nil_coalescing_expression"],
        caseNodes: ["switch_entry"],
        // `guard` is deliberately absent from nesting: it is an early exit, so counting it
        // would penalise the idiom that reduces nesting.
        nesting: ["if_statement", "for_statement", "while_statement", "repeat_while_statement",
                  "switch_statement", "do_statement", "catch_block", "lambda_literal"],
        typeDeclarations: ["class_declaration", "protocol_declaration"],
        identifierTypes: ["simple_identifier", "type_identifier", "pattern"])

    // MARK: C family

    public static let c = LanguageSupport(
        id: "c", displayName: "C", extensions: ["c", "h"],
        makeLanguage: { Language(language: tree_sitter_c()) },
        unitQuery: """
        (function_definition) @unit.function
        (struct_specifier name: (type_identifier) @name) @unit.type
        (enum_specifier name: (type_identifier) @name) @unit.type
        """,
        branching: ["if_statement", "for_statement", "while_statement", "do_statement",
                    "conditional_expression"],
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["case_statement"],
        nesting: ["if_statement", "for_statement", "while_statement", "do_statement", "switch_statement"],
        identifierTypes: ["identifier", "field_identifier", "type_identifier"])

    public static let cpp = LanguageSupport(
        id: "cpp", displayName: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ipp"],
        makeLanguage: { Language(language: tree_sitter_cpp()) },
        unitQuery: """
        (function_definition) @unit.function
        (class_specifier name: (type_identifier) @name) @unit.type
        (struct_specifier name: (type_identifier) @name) @unit.type
        """,
        branching: ["if_statement", "for_statement", "for_range_loop", "while_statement",
                    "do_statement", "catch_clause", "conditional_expression"],
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["case_statement"],
        nesting: ["if_statement", "for_statement", "for_range_loop", "while_statement",
                  "do_statement", "switch_statement", "try_statement", "lambda_expression"],
        typeDeclarations: ["class_specifier", "struct_specifier", "namespace_definition"],
        identifierTypes: ["identifier", "field_identifier", "type_identifier", "qualified_identifier"])

    public static let cSharp = LanguageSupport(
        id: "csharp", displayName: "C#", extensions: ["cs"],
        makeLanguage: { Language(language: tree_sitter_c_sharp()) },
        unitQuery: """
        (method_declaration name: (identifier) @name) @unit.method
        (constructor_declaration name: (identifier) @name) @unit.method
        (local_function_statement name: (identifier) @name) @unit.function
        (class_declaration name: (identifier) @name) @unit.type
        (interface_declaration name: (identifier) @name) @unit.type
        (struct_declaration name: (identifier) @name) @unit.type
        (record_declaration name: (identifier) @name) @unit.type
        """,
        branching: ["if_statement", "for_statement", "foreach_statement", "while_statement",
                    "do_statement", "catch_clause", "conditional_expression",
                    "conditional_access_expression", "switch_expression_arm"],
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["switch_section"], caseRequiresChildContaining: "pattern",
        nesting: ["if_statement", "for_statement", "foreach_statement", "while_statement",
                  "do_statement", "switch_statement", "try_statement", "lambda_expression"],
        typeDeclarations: ["class_declaration", "interface_declaration", "struct_declaration",
                           "record_declaration", "enum_declaration"])

    // MARK: Python

    public static let python = LanguageSupport(
        id: "python", displayName: "Python", extensions: ["py", "pyi", "pyw"],
        makeLanguage: { Language(language: tree_sitter_python()) },
        unitQuery: """
        (function_definition name: (identifier) @name) @unit.function
        (class_definition name: (identifier) @name) @unit.type
        """,
        branching: ["if_statement", "elif_clause", "for_statement", "while_statement",
                    "except_clause", "conditional_expression", "assert_statement", "if_clause"],
        // Python spells its short-circuit operators as words.
        logicalNodes: ["boolean_operator"], logicalOperators: ["and", "or"],
        caseNodes: ["case_clause"],
        nesting: ["if_statement", "for_statement", "while_statement", "try_statement",
                  "with_statement", "match_statement"],
        typeDeclarations: ["class_definition"])

    // MARK: JavaScript / TypeScript

    private static let jsBranching: Set<String> = [
        "if_statement", "for_statement", "for_in_statement", "while_statement",
        "do_statement", "catch_clause", "ternary_expression",
    ]
    private static let jsNesting: Set<String> = [
        "if_statement", "for_statement", "for_in_statement", "while_statement",
        "do_statement", "switch_statement", "try_statement",
    ]
    private static let jsQuery = """
    (function_declaration name: (identifier) @name) @unit.function
    (generator_function_declaration name: (identifier) @name) @unit.function
    (method_definition name: (property_identifier) @name) @unit.method
    (class_declaration name: (identifier) @name) @unit.type
    (variable_declarator name: (identifier) @name value: (arrow_function)) @unit.function
    (variable_declarator name: (identifier) @name value: (function_expression)) @unit.function
    """

    public static let javascript = LanguageSupport(
        id: "javascript", displayName: "JavaScript", extensions: ["js", "jsx", "mjs", "cjs"],
        makeLanguage: { Language(language: tree_sitter_javascript()) },
        unitQuery: jsQuery,
        branching: jsBranching,
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["switch_case"],
        nesting: jsNesting,
        typeDeclarations: ["class_declaration"],
        identifierTypes: ["identifier", "property_identifier"])

    /// TypeScript names types with `type_identifier` where JavaScript uses `identifier`,
    /// so it cannot share the JavaScript query — a wrong node type fails to compile rather
    /// than silently matching nothing, which is how this was caught.
    private static let tsQuery = """
    (function_declaration name: (identifier) @name) @unit.function
    (generator_function_declaration name: (identifier) @name) @unit.function
    (method_definition name: (property_identifier) @name) @unit.method
    (class_declaration name: (type_identifier) @name) @unit.type
    (abstract_class_declaration name: (type_identifier) @name) @unit.type
    (interface_declaration name: (type_identifier) @name) @unit.type
    (variable_declarator name: (identifier) @name value: (arrow_function)) @unit.function
    (variable_declarator name: (identifier) @name value: (function_expression)) @unit.function
    """

    public static let typescript = LanguageSupport(
        id: "typescript", displayName: "TypeScript", extensions: ["ts", "mts", "cts"],
        makeLanguage: { Language(language: tree_sitter_typescript()) },
        unitQuery: tsQuery,
        branching: jsBranching,
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["switch_case"],
        nesting: jsNesting,
        typeDeclarations: ["class_declaration", "abstract_class_declaration", "interface_declaration"],
        identifierTypes: ["identifier", "property_identifier", "type_identifier"])

    public static let tsx = LanguageSupport(
        id: "tsx", displayName: "TSX", extensions: ["tsx"],
        makeLanguage: { Language(language: tree_sitter_tsx()) },
        unitQuery: tsQuery,
        branching: jsBranching,
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["switch_case"],
        nesting: jsNesting,
        typeDeclarations: ["class_declaration", "abstract_class_declaration", "interface_declaration"],
        identifierTypes: ["identifier", "property_identifier", "type_identifier"])

    // MARK: JVM

    public static let java = LanguageSupport(
        id: "java", displayName: "Java", extensions: ["java"],
        makeLanguage: { Language(language: tree_sitter_java()) },
        unitQuery: """
        (method_declaration name: (identifier) @name) @unit.method
        (constructor_declaration name: (identifier) @name) @unit.method
        (class_declaration name: (identifier) @name) @unit.type
        (interface_declaration name: (identifier) @name) @unit.type
        (enum_declaration name: (identifier) @name) @unit.type
        (record_declaration name: (identifier) @name) @unit.type
        """,
        branching: ["if_statement", "for_statement", "enhanced_for_statement", "while_statement",
                    "do_statement", "catch_clause", "ternary_expression"],
        logicalNodes: ["binary_expression"], logicalOperators: cLikeLogical,
        caseNodes: ["switch_label"],
        nesting: ["if_statement", "for_statement", "enhanced_for_statement", "while_statement",
                  "do_statement", "switch_expression", "try_statement", "lambda_expression"],
        typeDeclarations: ["class_declaration", "interface_declaration", "enum_declaration",
                           "record_declaration"])

    public static let kotlin = LanguageSupport(
        id: "kotlin", displayName: "Kotlin", extensions: ["kt", "kts"],
        makeLanguage: { Language(language: tree_sitter_kotlin()) },
        unitQuery: """
        (function_declaration) @unit.function
        (class_declaration) @unit.type
        (object_declaration) @unit.type
        """,
        branching: ["if_expression", "for_statement", "while_statement", "do_while_statement",
                    "catch_block", "conjunction_expression", "disjunction_expression",
                    "elvis_expression"],
        caseNodes: ["when_entry"],
        nesting: ["if_expression", "for_statement", "while_statement", "do_while_statement",
                  "when_expression", "try_expression", "catch_block", "lambda_literal"],
        typeDeclarations: ["class_declaration", "object_declaration"],
        identifierTypes: ["simple_identifier", "type_identifier"])

    // MARK: Systems / scripting

    public static let rust = LanguageSupport(
        id: "rust", displayName: "Rust", extensions: ["rs"],
        makeLanguage: { Language(language: tree_sitter_rust()) },
        unitQuery: """
        (function_item name: (identifier) @name) @unit.function
        (struct_item name: (type_identifier) @name) @unit.type
        (enum_item name: (type_identifier) @name) @unit.type
        (trait_item name: (type_identifier) @name) @unit.type
        (impl_item) @unit.type
        """,
        branching: ["if_expression", "while_expression", "loop_expression", "for_expression"],
        logicalNodes: ["binary_expression"], logicalOperators: ["&&", "||"],
        // Every arm counts, including the `_` catch-all: Rust matches must be exhaustive,
        // so the wildcard usually carries real logic rather than being a fall-through.
        caseNodes: ["match_arm"], defaultCaseMarkers: [],
        nesting: ["if_expression", "while_expression", "loop_expression", "for_expression",
                  "match_expression", "closure_expression"],
        typeDeclarations: ["impl_item", "struct_item", "enum_item", "trait_item", "mod_item"],
        identifierTypes: ["identifier", "type_identifier", "field_identifier"])

    public static let go = LanguageSupport(
        id: "go", displayName: "Go", extensions: ["go"],
        makeLanguage: { Language(language: tree_sitter_go()) },
        unitQuery: """
        (function_declaration name: (identifier) @name) @unit.function
        (method_declaration name: (field_identifier) @name) @unit.method
        (type_declaration (type_spec name: (type_identifier) @name)) @unit.type
        """,
        branching: ["if_statement", "for_statement"],
        logicalNodes: ["binary_expression"], logicalOperators: ["&&", "||"],
        caseNodes: ["expression_case", "type_case", "communication_case"],
        nesting: ["if_statement", "for_statement", "expression_switch_statement",
                  "type_switch_statement", "select_statement", "func_literal"],
        identifierTypes: ["identifier", "field_identifier", "type_identifier"])

    public static let ruby = LanguageSupport(
        id: "ruby", displayName: "Ruby", extensions: ["rb", "rake", "gemspec"],
        makeLanguage: { Language(language: tree_sitter_ruby()) },
        unitQuery: """
        (method name: (identifier) @name) @unit.method
        (singleton_method name: (identifier) @name) @unit.method
        (class name: (constant) @name) @unit.type
        (module name: (constant) @name) @unit.type
        """,
        branching: ["if", "elsif", "unless", "while", "until", "for", "rescue", "conditional",
                    "if_modifier", "unless_modifier", "while_modifier", "until_modifier",
                    "rescue_modifier"],
        logicalNodes: ["binary"], logicalOperators: ["&&", "||", "and", "or"],
        caseNodes: ["when", "in_clause"],
        nesting: ["if", "unless", "while", "until", "for", "case", "case_match", "begin", "do_block", "block"],
        typeDeclarations: ["class", "module", "singleton_class"],
        identifierTypes: ["identifier", "constant"])

    public static let php = LanguageSupport(
        id: "php", displayName: "PHP", extensions: ["php", "phtml"],
        makeLanguage: { Language(language: tree_sitter_php()) },
        unitQuery: """
        (function_definition name: (name) @name) @unit.function
        (method_declaration name: (name) @name) @unit.method
        (class_declaration name: (name) @name) @unit.type
        (interface_declaration name: (name) @name) @unit.type
        (trait_declaration name: (name) @name) @unit.type
        """,
        branching: ["if_statement", "else_if_clause", "for_statement", "foreach_statement",
                    "while_statement", "do_statement", "catch_clause", "conditional_expression",
                    "match_conditional_expression"],
        logicalNodes: ["binary_expression"], logicalOperators: ["&&", "||", "??", "and", "or"],
        caseNodes: ["case_statement"],
        nesting: ["if_statement", "for_statement", "foreach_statement", "while_statement",
                  "do_statement", "switch_statement", "try_statement", "match_expression"],
        typeDeclarations: ["class_declaration", "interface_declaration", "trait_declaration",
                           "enum_declaration"],
        identifierTypes: ["name"])

    // MARK: Stylesheets

    /// CSS has no control flow, so "complexity" here counts declarations in a rule instead
    /// of branches. A rule that keeps changing is still a genuine hotspot; the number beside
    /// it just means something different, and the UI says so.
    public static let css = LanguageSupport(
        id: "css", displayName: "CSS", extensions: ["css"],
        makeLanguage: { Language(language: tree_sitter_css()) },
        unitQuery: """
        (rule_set (selectors) @name) @unit.function
        (keyframe_block_list) @unit.type
        """,
        nesting: ["media_statement", "supports_statement", "keyframe_block_list"],
        identifierTypes: ["selectors", "class_selector", "id_selector", "tag_name"],
        countsDeclarations: true, declarationNodes: ["declaration"])
}
