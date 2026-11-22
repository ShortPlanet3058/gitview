import Foundation
import SwiftTreeSitter
import GitViewCore

/// Everything GitView needs to know to extract and score units in one language.
///
/// Node names differ between grammars — a function is `function_definition` in C and
/// Python, `function_declaration` in Go and JavaScript, `function_item` in Rust, `method`
/// in Ruby — so every entry here is written against that grammar's own node types and
/// covered by a test with a hand-counted snippet. Guessing produces plausible numbers that
/// are wrong, which is worse than no support at all.
public struct LanguageSupport: Sendable {
    public let id: String
    public let displayName: String
    /// Lower-cased file extensions, without the dot.
    public let extensions: Set<String>
    /// Built lazily: constructing every grammar up front costs memory for languages the
    /// repository does not contain.
    public let makeLanguage: @Sendable () -> Language

    /// Query capturing `@unit.function`, `@unit.method`, `@unit.type` and optional `@name`.
    public let unitQuery: String
    /// Optional query capturing `@keyword`, `@type`, `@function`, `@string`, `@comment`, `@number`, `@property`.
    public let highlightQuery: String

    /// Nodes that are unconditionally a decision point.
    public let branching: Set<String>
    /// Nodes whose operator decides: only short-circuit operators count, so `a + b` does
    /// not become a branch just because it is a `binary_expression` like `a && b`.
    public let logicalNodes: Set<String>
    public let logicalOperators: Set<String>
    /// Case-like nodes where the default/else arm is not a decision point.
    public let caseNodes: Set<String>
    public let defaultCaseMarkers: Set<String>
    /// When set, a case node counts only if one of its children's type contains this
    /// substring. C# needs it: both arms of a switch are `switch_section`.
    public let caseRequiresChildContaining: String?

    /// Nodes that add a level of nesting.
    public let nesting: Set<String>
    /// Declarations that contribute a component to a qualified name.
    public let typeDeclarations: Set<String>
    /// Node types that can serve as a unit's name when no `@name` capture matched.
    public let identifierTypes: Set<String>
    /// Counts declarations instead of branches (CSS rule sets have no control flow).
    public let countsDeclarations: Bool
    /// Node types counted when `countsDeclarations` is true.
    public let declarationNodes: Set<String>

    public init(
        id: String, displayName: String, extensions: Set<String>,
        makeLanguage: @escaping @Sendable () -> Language,
        unitQuery: String,
        highlightQuery: String = "",
        branching: Set<String> = [],
        logicalNodes: Set<String> = [],
        logicalOperators: Set<String> = ["&&", "||", "??"],
        caseNodes: Set<String> = [],
        defaultCaseMarkers: Set<String> = ["default", "default_keyword", "else"],
        caseRequiresChildContaining: String? = nil,
        nesting: Set<String> = [],
        typeDeclarations: Set<String> = [],
        identifierTypes: Set<String> = ["identifier"],
        countsDeclarations: Bool = false,
        declarationNodes: Set<String> = []
    ) {
        self.id = id; self.displayName = displayName; self.extensions = extensions
        self.makeLanguage = makeLanguage; self.unitQuery = unitQuery
        self.highlightQuery = highlightQuery
        self.branching = branching; self.logicalNodes = logicalNodes
        self.logicalOperators = logicalOperators
        self.caseNodes = caseNodes; self.defaultCaseMarkers = defaultCaseMarkers
        self.caseRequiresChildContaining = caseRequiresChildContaining
        self.nesting = nesting
        self.typeDeclarations = typeDeclarations; self.identifierTypes = identifierTypes
        self.countsDeclarations = countsDeclarations; self.declarationNodes = declarationNodes
    }
}

/// Maps file extensions to language support, and caches compiled queries.
public final class LanguageRegistry: @unchecked Sendable {
    public static let shared = LanguageRegistry(languages: LanguageSupport.all)

    private let byExtension: [String: LanguageSupport]
    public let languages: [LanguageSupport]
    private var queries: [String: Query] = [:]
    private var highlightQueries: [String: Query] = [:]
    private var tsLanguages: [String: Language] = [:]
    private let lock = NSLock()

    public init(languages: [LanguageSupport]) {
        self.languages = languages
        var map: [String: LanguageSupport] = [:]
        for language in languages {
            for ext in language.extensions { map[ext] = language }
        }
        self.byExtension = map
    }

    public func language(forExtension ext: String) -> LanguageSupport? {
        byExtension[ext.lowercased()]
    }

    public func treeSitterLanguage(forPath path: String) -> (LanguageSupport, Language)? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let support = byExtension[ext] else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let language = tsLanguages[support.id] {
            return (support, language)
        }
        let language = support.makeLanguage()
        tsLanguages[support.id] = language
        return (support, language)
    }

    public var supportedExtensions: Set<String> { Set(byExtension.keys) }

    /// Compiles a language's grammar and query once and reuses them; `Query` and `Language`
    /// are immutable, so sharing them across the parsing task group is safe.
    public func compiled(_ support: LanguageSupport) throws -> (Language, Query) {
        lock.lock(); defer { lock.unlock() }
        if let language = tsLanguages[support.id], let query = queries[support.id] {
            return (language, query)
        }
        let language = tsLanguages[support.id] ?? support.makeLanguage()
        let query = try Query(language: language, data: Data(support.unitQuery.utf8))
        tsLanguages[support.id] = language
        queries[support.id] = query
        return (language, query)
    }

    /// Compiles and caches the syntax-highlighting query for `support`, or returns `nil` if unset.
    public func compiledHighlightQuery(_ support: LanguageSupport) throws -> Query? {
        guard !support.highlightQuery.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let existing = highlightQueries[support.id] {
            return existing
        }
        let language = tsLanguages[support.id] ?? support.makeLanguage()
        tsLanguages[support.id] = language
        let query = try Query(language: language, data: Data(support.highlightQuery.utf8))
        highlightQueries[support.id] = query
        return query
    }
}
