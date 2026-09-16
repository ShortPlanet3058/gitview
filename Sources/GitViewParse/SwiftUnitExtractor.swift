import Foundation
import SwiftTreeSitter
import GitViewCore

/// Extracts `CodeUnit`s from a single Swift source file.
///
/// Sendable, and deliberately cheap to share: compiling the tree-sitter query is the
/// expensive part and the compiled `Query` is itself immutable and thread-safe, so one
/// extractor serves every file. Only `Parser` holds mutable state, and `extract` makes
/// a fresh one per call.
public struct SwiftUnitExtractor: Sendable {
    private let query: Query

    public init() throws {
        self.query = try SwiftLanguage.makeUnitQuery()
    }

    public func extract(source: String, filePath: String) throws -> [CodeUnit] {
        let parser = Parser()
        try parser.setLanguage(SwiftLanguage.language)
        guard let tree = parser.parse(source), let root = tree.rootNode else { return [] }

        // Node ranges are UTF-16 offsets (the parser's default encoding), which is exactly
        // what NSString indexes with — so no transcoding is needed to read node text.
        let text = source as NSString

        // Collect unit nodes first: the complexity walk needs to know every unit boundary
        // up front so it can prune at nested declarations.
        var unitNodes: [(node: Node, capture: String)] = []
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            for capture in match.captures {
                let name = capture.nameComponents.joined(separator: ".")
                guard name.hasPrefix("unit.") else { continue }
                unitNodes.append((capture.node, name))
            }
        }

        let unitIDs = Set(unitNodes.map(\.node.id))
        let analyzer = ComplexityAnalyzer(unitNodeIDs: unitIDs)

        return unitNodes.compactMap { entry -> CodeUnit? in
            guard let range = lineRange(of: entry.node) else { return nil }
            let metrics = analyzer.analyze(root: entry.node)
            return CodeUnit(
                filePath: filePath,
                name: qualifiedName(of: entry.node, capture: entry.capture, text: text),
                kind: kind(of: entry.node, capture: entry.capture),
                lineRange: range,
                complexity: metrics.complexity,
                nestingDepth: metrics.nestingDepth,
                lineCount: range.count
            )
        }
    }

    // MARK: - Line ranges

    /// Converts a node's point range to a 1-based inclusive line range.
    ///
    /// tree-sitter rows are 0-based, and the end point is exclusive. A node whose end lands
    /// in column 0 finished on the *previous* line, so counting its end row would claim one
    /// line too many — and since `lineCount` feeds the risk score, that would inflate
    /// every unit by one.
    private func lineRange(of node: Node) -> ClosedRange<Int>? {
        let points = node.pointRange
        let startRow = Int(points.lowerBound.row)
        var endRow = Int(points.upperBound.row)
        if points.upperBound.column == 0, endRow > startRow { endRow -= 1 }
        guard endRow >= startRow else { return nil }
        return (startRow + 1)...(endRow + 1)
    }

    // MARK: - Naming

    private func kind(of node: Node, capture: String) -> CodeUnit.Kind {
        if capture == "unit.type" || capture == "unit.protocol" { return .class }
        // A declaration sitting directly inside a type body is a method; anything else
        // (top-level, or nested inside another function) is a free function.
        var parent = node.parent
        while let current = parent {
            if let type = current.nodeType {
                if SwiftNodeType.typeBodies.contains(type) { return .method }
                if type == "function_body" { return .function }
            }
            parent = current.parent
        }
        return .function
    }

    /// Builds `Outer.Inner.method` so the risk table is readable without the file path.
    private func qualifiedName(of node: Node, capture: String, text: NSString) -> String {
        var components: [String] = []
        var parent = node.parent
        while let current = parent {
            if let type = current.nodeType, SwiftNodeType.typeDeclarations.contains(type),
               let name = declaredName(of: current, capture: "unit.type", text: text) {
                components.append(name)
            }
            parent = current.parent
        }
        let own = declaredName(of: node, capture: capture, text: text) ?? "<anonymous>"
        return (components.reversed() + [own]).joined(separator: ".")
    }

    private func declaredName(of node: Node, capture: String, text: NSString) -> String? {
        switch capture {
        case "unit.init": return "init"
        case "unit.deinit": return "deinit"
        case "unit.subscript": return "subscript"
        default: break
        }
        if let named = node.child(byFieldName: "name") {
            return text.substring(with: named.range)
        }
        // `extension Foo` has no `name` field — the extended type is a plain type_identifier.
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.nodeType == "type_identifier" || child.nodeType == "user_type" {
                return text.substring(with: child.range)
            }
        }
        return nil
    }
}
