import Foundation
import SwiftTreeSitter
import GitViewCore

/// Extracts `CodeUnit`s from one source file, in whichever language the registry matched.
public struct UnitExtractor: Sendable {
    public let support: LanguageSupport
    private let language: Language
    private let query: Query

    public init(support: LanguageSupport, registry: LanguageRegistry = .shared) throws {
        self.support = support
        (self.language, self.query) = try registry.compiled(support)
    }

    public func extract(source: String, filePath: String) throws -> [CodeUnit] {
        let parser = Parser()
        try parser.setLanguage(language)
        guard let tree = parser.parse(source), let root = tree.rootNode else { return [] }

        // Node ranges are UTF-16 offsets (the parser's default encoding), which is exactly
        // what NSString indexes with, so no transcoding is needed to read node text.
        let text = source as NSString

        struct Found { let node: Node; let kindCapture: String; let nameNode: Node? }
        var found: [Found] = []
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            var unit: (Node, String)?
            var nameNode: Node?
            for capture in match.captures {
                let name = capture.nameComponents.joined(separator: ".")
                if name.hasPrefix("unit.") { unit = (capture.node, name) }
                else if name == "name" { nameNode = capture.node }
            }
            if let unit { found.append(Found(node: unit.0, kindCapture: unit.1, nameNode: nameNode)) }
        }

        let unitIDs = Set(found.map(\.node.id))
        let analyzer = ComplexityAnalyzer(support: support, unitNodeIDs: unitIDs, text: text)

        return found.compactMap { entry -> CodeUnit? in
            guard let range = lineRange(of: entry.node) else { return nil }
            let metrics = analyzer.analyze(root: entry.node)
            return CodeUnit(
                filePath: filePath,
                name: qualifiedName(of: entry.node, nameNode: entry.nameNode, text: text),
                kind: kind(of: entry.node, capture: entry.kindCapture),
                lineRange: range,
                complexity: metrics.complexity,
                nestingDepth: metrics.nestingDepth,
                lineCount: range.count,
                language: support.id)
        }
    }

    /// Same walk as `extract`, but reporting which node types were counted.
    public func trace(source: String) throws -> [(String, Int, [String: Int])] {
        let parser = Parser()
        try parser.setLanguage(language)
        guard let tree = parser.parse(source), let root = tree.rootNode else { return [] }
        let text = source as NSString
        var nodes: [(Node, Node?)] = []
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            var unit: Node?
            var nameNode: Node?
            for capture in match.captures {
                let name = capture.nameComponents.joined(separator: ".")
                if name.hasPrefix("unit.") { unit = capture.node } else if name == "name" { nameNode = capture.node }
            }
            if let unit { nodes.append((unit, nameNode)) }
        }
        let analyzer = ComplexityAnalyzer(support: support, unitNodeIDs: Set(nodes.map(\.0.id)), text: text)
        return nodes.map { node, nameNode in
            let result = analyzer.analyze(root: node)
            return (qualifiedName(of: node, nameNode: nameNode, text: text), result.complexity, result.counted)
        }
    }

    // MARK: - Line ranges

    /// Converts a node's point range to a 1-based inclusive line range.
    ///
    /// tree-sitter rows are 0-based and the end point is exclusive. A node whose end lands
    /// in column 0 finished on the *previous* line, so counting its end row would claim one
    /// line too many — and `lineCount` feeds the risk score.
    private func lineRange(of node: Node) -> ClosedRange<Int>? {
        let points = node.pointRange
        let startRow = Int(points.lowerBound.row)
        var endRow = Int(points.upperBound.row)
        if points.upperBound.column == 0, endRow > startRow { endRow -= 1 }
        guard endRow >= startRow else { return nil }
        return (startRow + 1)...(endRow + 1)
    }

    // MARK: - Kind and naming

    private func kind(of node: Node, capture: String) -> CodeUnit.Kind {
        if capture == "unit.type" { return .class }
        if capture == "unit.method" { return .method }
        var parent = node.parent
        while let current = parent {
            if let type = current.nodeType, support.typeDeclarations.contains(type) { return .method }
            parent = current.parent
        }
        return .function
    }

    /// Builds `Outer.Inner.name` so a unit reads without its file path.
    private func qualifiedName(of node: Node, nameNode: Node?, text: NSString) -> String {
        var components: [String] = []
        var parent = node.parent
        while let current = parent {
            if let type = current.nodeType, support.typeDeclarations.contains(type),
               let name = declaredName(of: current, text: text), !name.isEmpty {
                components.append(name)
            }
            parent = current.parent
        }
        let own = nameNode.map { text.substring(with: $0.range) }
            ?? declaredName(of: node, text: text)
            ?? "<anonymous>"
        return (components.reversed() + [own]).joined(separator: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds a node's own name without a `@name` capture.
    ///
    /// Three fallbacks in order, because grammars disagree: a `name` field (most), a chain
    /// of `declarator` fields (C and C++ bury the identifier under pointer/array
    /// declarators), then the nearest identifier-ish descendant.
    private func declaredName(of node: Node, text: NSString) -> String? {
        if let named = node.child(byFieldName: "name") { return text.substring(with: named.range) }

        var declarator = node.child(byFieldName: "declarator")
        var hops = 0
        while let current = declarator, hops < 6 {
            if let type = current.nodeType, support.identifierTypes.contains(type) {
                return text.substring(with: current.range)
            }
            declarator = current.child(byFieldName: "declarator") ?? current.child(byFieldName: "name")
            hops += 1
        }
        return nearestIdentifier(in: node, depth: 0, text: text)
    }

    private func nearestIdentifier(in node: Node, depth: Int, text: NSString) -> String? {
        guard depth < 4 else { return nil }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if let type = child.nodeType, support.identifierTypes.contains(type) {
                return text.substring(with: child.range)
            }
        }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if let found = nearestIdentifier(in: child, depth: depth + 1, text: text) { return found }
        }
        return nil
    }
}

/// Counts decision points and nesting within a unit's subtree, using one language's rules.
///
/// These numbers exist to *rank units against each other*. They are not cyclomatic
/// complexity in any certified sense and should not be reported as such.
struct ComplexityAnalyzer {
    let support: LanguageSupport
    /// Node ids of every extracted unit, so a walk can stop at a nested declaration.
    let unitNodeIDs: Set<UInt>
    let text: NSString

    struct Result {
        var complexity: Int
        var nestingDepth: Int
        /// Which node types contributed, for the `langs --verbose` probe. Keeping this
        /// always-on makes a wrong branch set visible instead of merely plausible.
        var counted: [String: Int] = [:]
    }

    /// Walks `root`'s subtree, pruning at any nested unit.
    ///
    /// Pruning matters: without it a type's complexity would be the sum of all its methods,
    /// so every class would outrank every function and the ranking would be worthless.
    /// Closures are *not* separate units, so they stay counted in their enclosing function —
    /// which is right, since a closure's branches are that function's branches.
    func analyze(root: Node) -> Result {
        // Complexity starts at 1: a unit with no branches still has one path through it.
        var result = Result(complexity: 1, nestingDepth: 0)
        visit(node: root, depth: 0, isRoot: true, into: &result)
        return result
    }

    private func visit(node: Node, depth: Int, isRoot: Bool, into result: inout Result) {
        if !isRoot, unitNodeIDs.contains(node.id) { return }
        let type = node.nodeType ?? ""

        // Only *named* nodes can be decision points. Several grammars give a keyword token
        // the same name as the statement it introduces — Ruby's `for`, `if` and `when` are
        // both an anonymous keyword and a named node — so counting unnamed nodes scored
        // every such construct twice.
        guard node.isNamed || isRoot else {
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(node: child, depth: depth, isRoot: false, into: &result)
            }
            return
        }

        if support.countsDeclarations {
            if support.declarationNodes.contains(type) {
                result.complexity += 1; result.counted[type, default: 0] += 1
            }
        } else {
            if support.branching.contains(type) {
                result.complexity += 1; result.counted[type, default: 0] += 1
            }
            if support.logicalNodes.contains(type), isShortCircuit(node) {
                result.complexity += 1; result.counted["\(type) (short-circuit)", default: 0] += 1
            }
            if support.caseNodes.contains(type), !isDefaultCase(node) {
                result.complexity += 1; result.counted[type, default: 0] += 1
            }
        }

        var childDepth = depth
        if support.nesting.contains(type) {
            childDepth += 1
            result.nestingDepth = max(result.nestingDepth, childDepth)
        }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            visit(node: child, depth: childDepth, isRoot: false, into: &result)
        }
    }

    /// True when a binary node's operator short-circuits. Without this check `a + b` would
    /// count as a branch in every C-family language, because it is the same node type
    /// as `a && b`.
    private func isShortCircuit(_ node: Node) -> Bool {
        if let op = node.child(byFieldName: "operator") {
            return support.logicalOperators.contains(text.substring(with: op.range))
        }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index), !child.isNamed else { continue }
            if support.logicalOperators.contains(text.substring(with: child.range)) { return true }
        }
        return false
    }

    /// The fall-through arm of a switch is not a decision point.
    private func isDefaultCase(_ node: Node) -> Bool {
        // C# has no label node: `case 1:` and `default:` are both `switch_section`, told
        // apart by whether a pattern child is present.
        if let required = support.caseRequiresChildContaining {
            for index in 0..<node.childCount {
                if let type = node.child(at: index)?.nodeType, type.contains(required) { return false }
            }
            return true
        }
        guard !support.defaultCaseMarkers.isEmpty else { return false }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if let type = child.nodeType, support.defaultCaseMarkers.contains(type) { return true }
            if !child.isNamed, support.defaultCaseMarkers.contains(text.substring(with: child.range)) { return true }
        }
        return false
    }
}
