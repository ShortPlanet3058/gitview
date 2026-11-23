import Foundation
import GitViewCore
import GitViewGit

/// Directory tree built from tracked paths with size, count, and hotspot aggregates.
///
/// Built once when analysis or risk rankings change, then queried with an O(N) bottom-up
/// search pass so expanding folders or typing into the file filter stays instantaneous.
struct FileTree: Sendable {
    final class Node: Identifiable, @unchecked Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        var bytes: Int64 = 0
        var fileCount: Int = 0
        var modified: Date?
        var children: [Node] = []
        var hotspotCounts: [RiskLevel: Int] = [:]
        var depth: Int = 0
        var id: String { path }

        init(path: String, name: String, isDirectory: Bool) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
        }

        var hotspots: Int {
            (hotspotCounts[.critical] ?? 0) + (hotspotCounts[.high] ?? 0)
        }
    }

    let root: Node
    private var index: [String: Node] = [:]

    init(files: [FileInventory.TrackedFile], rows: [RiskRow]) {
        self.init(entries: files.map { ($0.path, $0.bytes, $0.modified) }, rows: rows)
    }

    init(paths: [String]) {
        self.init(entries: paths.map { ($0, 0, nil) }, rows: [])
    }

    private init(entries: [(path: String, bytes: Int64, modified: Date?)], rows: [RiskRow]) {
        root = Node(path: "", name: "/", isDirectory: true)
        index[""] = root
        var attention: [String: [RiskLevel: Int]] = [:]
        for row in rows where row.level == .critical || row.level == .high {
            attention[row.filePath, default: [:]][row.level, default: 0] += 1
        }
        for file in entries {
            var parent = root
            let components = file.path.split(separator: "/").map(String.init)
            var current = ""
            for (i, component) in components.enumerated() {
                current = current.isEmpty ? component : current + "/" + component
                let isLeaf = i == components.count - 1
                let node: Node
                if let existing = index[current] {
                    node = existing
                } else {
                    node = Node(path: current, name: component, isDirectory: !isLeaf)
                    node.depth = i + 1
                    index[current] = node
                    parent.children.append(node)
                }
                node.bytes += file.bytes
                node.fileCount += 1
                if let m = file.modified, node.modified.map({ m > $0 }) ?? true { node.modified = m }
                if let counts = attention[file.path] {
                    for (level, count) in counts { node.hotspotCounts[level, default: 0] += count }
                }
                parent = node
            }
            root.bytes += file.bytes
            root.fileCount += 1
            if let m = file.modified, root.modified.map({ m > $0 }) ?? true { root.modified = m }
            if let counts = attention[file.path] {
                for (level, count) in counts { root.hotspotCounts[level, default: 0] += count }
            }
        }
        // Leaves represent 1 file each; directories carry descendant file count.
        for node in index.values where !node.isDirectory { node.fileCount = 1 }
        Self.sort(root)
    }

    private static func sort(_ node: Node) {
        node.children.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        node.children.forEach(sort)
    }

    func node(at path: String) -> Node? { index[path] }

    /// First node whose path contains `fragment`, for `--select-file`.
    func firstNode(matching fragment: String) -> Node? {
        index.values.filter { !$0.isDirectory && $0.path.contains(fragment) }
            .min { $0.path.count < $1.path.count }
    }

    /// Depth-first visible list honoring folder expansion and O(N) bottom-up search matching.
    func visibleNodes(expanded: Set<String>, filter: String) -> [Node] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        var kept: Set<String>?
        if !q.isEmpty {
            var matched: Set<String> = []
            _ = Self.collectMatchingPaths(root, query: q, into: &matched)
            kept = matched
        }

        var result: [Node] = []
        func walk(_ node: Node) {
            for child in node.children {
                if let kept, !kept.contains(child.path) { continue }
                result.append(child)
                if child.isDirectory && (expanded.contains(child.path) || !q.isEmpty) {
                    walk(child)
                }
            }
        }
        walk(root)
        return result
    }

    private static func collectMatchingPaths(_ node: Node, query: String, into kept: inout Set<String>) -> Bool {
        let selfMatches = !node.path.isEmpty && node.path.localizedCaseInsensitiveContains(query)
        var anyChildMatches = false
        for child in node.children {
            if collectMatchingPaths(child, query: query, into: &kept) {
                anyChildMatches = true
            }
        }
        if selfMatches || anyChildMatches {
            if !node.path.isEmpty { kept.insert(node.path) }
            return true
        }
        return false
    }
}
