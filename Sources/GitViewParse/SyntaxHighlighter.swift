import Foundation
import SwiftTreeSitter

/// Coarse syntax categories produced by the tree-sitter CST highlighter.
public enum SyntaxTokenKind: Sendable, Hashable {
    case keyword
    case type
    case function
    case string
    case comment
    case number
    case property
}

/// One highlighted span on a single line, using UTF-16 code unit offsets within that line.
public struct HighlightSpan: Sendable, Hashable {
    public let range: Range<Int>
    public let kind: SyntaxTokenKind

    public init(range: Range<Int>, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Minimal line descriptor for highlighting old/new sides of a unified diff without pulling `GitViewGit` into `GitViewParse`.
public struct DiffHighlightLineInput: Sendable {
    public let id: Int
    public let text: String
    public let includesInOld: Bool
    public let includesInNew: Bool

    public init(id: Int, text: String, includesInOld: Bool, includesInNew: Bool) {
        self.id = id
        self.text = text
        self.includesInOld = includesInOld
        self.includesInNew = includesInNew
    }
}

/// Highlights source code per line using the same tree-sitter grammars as `UnitExtractor`.
public enum SyntaxHighlighter {
    private static let maxSourceBytes = 250_000

    /// Returns an array aligned 1-to-1 with lines split by `\n` (omitting no empty subsequences).
    /// Returns `[]` if the file extension is unsupported or the input exceeds the highlight size budget.
    public static func highlightLines(source: String, filePath: String,
                                      registry: LanguageRegistry = .shared) -> [[HighlightSpan]] {
        guard !source.isEmpty,
              source.utf8.count <= maxSourceBytes,
              let (support, language) = registry.treeSitterLanguage(forPath: filePath) else {
            return []
        }

        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
              let tree = parser.parse(source),
              let root = tree.rootNode else {
            return []
        }

        let lineBounds = computeUTF16LineBounds(for: source)
        var lineSpans = Array(repeating: [HighlightSpan](), count: lineBounds.count)
        let nsSource = source as NSString

        collectSpans(root: root, support: support, source: nsSource,
                     lineBounds: lineBounds, into: &lineSpans)

        for index in lineSpans.indices where lineSpans[index].count > 1 {
            lineSpans[index].sort { $0.range.lowerBound < $1.range.lowerBound }
        }
        return lineSpans
    }

    /// Highlights both old-side and new-side reconstructions of diff lines, keyed by `DiffHighlightLineInput.id`.
    public static func highlightDiffLines(_ lines: [DiffHighlightLineInput], filePath: String,
                                          registry: LanguageRegistry = .shared) -> [Int: [HighlightSpan]] {
        guard !lines.isEmpty else { return [:] }
        let oldLines = lines.filter(\.includesInOld)
        let newLines = lines.filter(\.includesInNew)

        var result: [Int: [HighlightSpan]] = [:]
        if !oldLines.isEmpty {
            let oldSource = oldLines.map(\.text).joined(separator: "\n")
            let oldSpans = highlightLines(source: oldSource, filePath: filePath, registry: registry)
            for (index, line) in oldLines.enumerated() where index < oldSpans.count {
                if !oldSpans[index].isEmpty {
                    result[line.id] = oldSpans[index]
                }
            }
        }
        if !newLines.isEmpty {
            let newSource = newLines.map(\.text).joined(separator: "\n")
            let newSpans = highlightLines(source: newSource, filePath: filePath, registry: registry)
            for (index, line) in newLines.enumerated() where index < newSpans.count {
                result[line.id] = newSpans[index]
            }
        }
        return result
    }

    // MARK: - AST walk & classification

    private struct WalkFrame {
        let node: Node
        let parentType: String
        let inheritedKind: SyntaxTokenKind?
        let overrideKind: SyntaxTokenKind?
    }

    private static let functionDeclarationNodes: Set<String> = [
        "function_declaration", "function_definition", "function_item",
        "method_declaration", "method_definition", "method", "singleton_method",
    ]
    private static let callNodes: Set<String> = ["call_expression", "call", "method_invocation"]
    private static let memberAccessNodes: Set<String> = [
        "navigation_expression", "member_expression", "field_expression",
        "attribute", "selector_expression", "scoped_identifier",
    ]
    private static let numberTypes: Set<String> = [
        "decimal_literal", "hex_literal", "octal_literal", "binary_literal",
        "boolean_literal", "true", "false", "nil", "null", "none", "undefined",
    ]
    private static let explicitTypeNodes: Set<String> = [
        "type_identifier", "primitive_type", "builtin_type", "predefined_type",
        "user_type", "constant",
    ]
    private static let explicitKeywordNodes: Set<String> = [
        "self", "super", "this", "self_expression", "super_expression",
        "true_keyword", "false_keyword",
    ]
    private static let propertyLeafNodes: Set<String> = [
        "property_identifier", "field_identifier", "property_name",
    ]

    private static func collectSpans(root: Node, support: LanguageSupport, source: NSString,
                                     lineBounds: [(start: Int, end: Int)], into lineSpans: inout [[HighlightSpan]]) {
        var stack: [WalkFrame] = [WalkFrame(node: root, parentType: "", inheritedKind: nil, overrideKind: nil)]
        stack.reserveCapacity(128)

        while let frame = stack.popLast() {
            let node = frame.node
            let type = node.nodeType ?? ""

            if isCommentNode(type) {
                emitSpan(range: node.range, kind: .comment, lineBounds: lineBounds, into: &lineSpans)
                continue
            }

            if isPureRegexOrStringLeaf(type, node: node) {
                emitSpan(range: node.range, kind: .string, lineBounds: lineBounds, into: &lineSpans)
                continue
            }

            let count = node.childCount
            if count == 0 {
                if let kind = classifyLeaf(node: node, type: type, parentType: frame.parentType,
                                           inheritedKind: frame.inheritedKind, overrideKind: frame.overrideKind,
                                           support: support, source: source) {
                    emitSpan(range: node.range, kind: kind, lineBounds: lineBounds, into: &lineSpans)
                }
                continue
            }

            let nextInherited = nextInheritedKind(current: frame.inheritedKind, nodeType: type)
            let functionTargetID = functionNameChildID(for: node, type: type, support: support,
                                                      inheritedOverride: frame.overrideKind)

            // Push children in reverse so index 0 is popped first.
            for index in stride(from: count - 1, through: 0, by: -1) {
                guard let child = node.child(at: index) else { continue }
                let childOverride: SyntaxTokenKind? = (child.id == functionTargetID) ? .function : nil
                stack.append(WalkFrame(node: child, parentType: type,
                                       inheritedKind: nextInherited, overrideKind: childOverride))
            }
        }
    }

    private static func isCommentNode(_ type: String) -> Bool {
        type.contains("comment")
    }

    private static func isPureRegexOrStringLeaf(_ type: String, node: Node) -> Bool {
        if type == "regex_pattern" || type == "character_literal" || type == "char_literal" {
            return true
        }
        return node.childCount == 0 && type.contains("string") && !type.contains("type")
    }

    private static func nextInheritedKind(current: SyntaxTokenKind?, nodeType: String) -> SyntaxTokenKind? {
        if nodeType.contains("interpolat") || nodeType == "template_substitution" {
            return nil
        }
        if current != nil { return current }
        if nodeType.contains("string") && !nodeType.contains("type") {
            return .string
        }
        return nil
    }

    private static func functionNameChildID(for node: Node, type: String,
                                            support: LanguageSupport,
                                            inheritedOverride: SyntaxTokenKind?) -> UInt? {
        if functionDeclarationNodes.contains(type) {
            return firstIdentifierChild(of: node, identifierTypes: support.identifierTypes)?.id
        }
        if callNodes.contains(type) {
            guard let callee = node.child(at: 0) else { return nil }
            let calleeType = callee.nodeType ?? ""
            if support.identifierTypes.contains(calleeType) {
                return callee.id
            }
            if memberAccessNodes.contains(calleeType) {
                return callee.id
            }
        }
        if inheritedOverride == .function, memberAccessNodes.contains(type) {
            return lastIdentifierChild(of: node, identifierTypes: support.identifierTypes)?.id
        }
        return nil
    }

    private static func firstIdentifierChild(of node: Node, identifierTypes: Set<String>) -> Node? {
        for index in 0..<node.childCount {
            if let child = node.child(at: index),
               let childType = child.nodeType,
               identifierTypes.contains(childType) {
                return child
            }
        }
        return nil
    }

    private static func lastIdentifierChild(of node: Node, identifierTypes: Set<String>) -> Node? {
        for index in stride(from: node.childCount - 1, through: 0, by: -1) {
            if let child = node.child(at: index),
               let childType = child.nodeType,
               identifierTypes.contains(childType) || propertyLeafNodes.contains(childType) {
                return child
            }
        }
        return nil
    }

    private static func classifyLeaf(node: Node, type: String, parentType: String,
                                     inheritedKind: SyntaxTokenKind?, overrideKind: SyntaxTokenKind?,
                                     support: LanguageSupport, source: NSString) -> SyntaxTokenKind? {
        if let inheritedKind { return inheritedKind }
        if isNumberOrBoolean(type) { return .number }
        if type == "escape_sequence" { return .string }
        if explicitTypeNodes.contains(type)
            || (support.typeDeclarations.contains(parentType) && support.identifierTypes.contains(type)) {
            return .type
        }
        if let overrideKind { return overrideKind }
        if propertyLeafNodes.contains(type)
            || (parentType == "navigation_suffix" && support.identifierTypes.contains(type)) {
            return .property
        }
        if explicitKeywordNodes.contains(type) || type.hasSuffix("_keyword") {
            return .keyword
        }
        if !node.isNamed {
            let range = node.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  range.length <= 24,
                  range.location + range.length <= source.length else { return nil }
            let token = source.substring(with: range)
            if isKeywordToken(token) { return .keyword }
        }
        return nil
    }

    private static func isNumberOrBoolean(_ type: String) -> Bool {
        if numberTypes.contains(type) { return true }
        return type.contains("integer") || type.contains("float") || type.contains("number")
    }

    private static func isKeywordToken(_ token: String) -> Bool {
        var hasLetter = false
        for scalar in token.unicodeScalars {
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            if isLetter {
                hasLetter = true
            } else if scalar != "_" && scalar != "@" && scalar != "#" {
                return false
            }
        }
        return hasLetter
    }

    // MARK: - Line offset mapping

    private static func computeUTF16LineBounds(for source: String) -> [(start: Int, end: Int)] {
        var bounds: [(start: Int, end: Int)] = []
        var lineStart = 0
        var offset = 0
        for codeUnit in source.utf16 {
            if codeUnit == 0x000A {
                bounds.append((lineStart, offset))
                lineStart = offset + 1
            }
            offset += 1
        }
        bounds.append((lineStart, offset))
        return bounds
    }

    private static func emitSpan(range: NSRange, kind: SyntaxTokenKind,
                                 lineBounds: [(start: Int, end: Int)],
                                 into lineSpans: inout [[HighlightSpan]]) {
        guard range.location != NSNotFound, range.length > 0, !lineBounds.isEmpty else { return }
        let spanStartGlobal = range.location
        let spanEndGlobal = range.location + range.length

        // Binary search for the first line whose end >= spanStartGlobal.
        var low = 0
        var high = lineBounds.count - 1
        while low < high {
            let mid = (low + high) / 2
            if lineBounds[mid].end < spanStartGlobal {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var lineIndex = low
        while lineIndex < lineBounds.count {
            let (lineStart, lineEnd) = lineBounds[lineIndex]
            if lineStart >= spanEndGlobal { break }
            let localStart = max(0, spanStartGlobal - lineStart)
            let localEnd = min(lineEnd - lineStart, spanEndGlobal - lineStart)
            if localStart < localEnd {
                lineSpans[lineIndex].append(HighlightSpan(range: localStart..<localEnd, kind: kind))
            }
            lineIndex += 1
        }
    }
}
