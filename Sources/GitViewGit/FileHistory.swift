import Foundation
import GitViewCore

/// One commit in a single file's life, with what it did to that file.
public struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { commit.sha }
    public let commit: Commit
    public let insertions: Int
    public let deletions: Int
    public let isBinary: Bool
    /// The name the file had after this commit.
    public let path: String
    /// Set when this commit is the one that moved or renamed it.
    public let previousPath: String?

    public var isRename: Bool { previousPath != nil }
    public var churn: Int { insertions + deletions }
}

extension GitRepository {
    /// A file's history, following renames.
    ///
    /// `--follow` rather than filtering the history already in memory: it genuinely tracks
    /// the file across moves — 106 of swift-nio's SocketChannel.swift commits are under its
    /// old path in `Sources/NIO/` — and one call costs about 0.08s for 312 commits.
    public func fileHistory(path: String, limit: Int = 300) throws -> [FileHistoryEntry] {
        let root = try validate()
        let output = try GitProcess.capture(
            arguments: ["log", "--follow", "--numstat", "--no-color", "--max-count=\(limit)",
                        "--pretty=format:%H%x1f%aN%x1f%aI%x1f%s", "--", path], in: root)
        return FileHistoryParser.parse(output, fallbackPath: path)
    }
}

enum FileHistoryParser {
    static func parse(_ output: String, fallbackPath: String) -> [FileHistoryEntry] {
        var entries: [FileHistoryEntry] = []
        var pending: Commit?
        var stat: (added: Int, removed: Int, binary: Bool, path: String, previous: String?)?

        func flush() {
            guard let commit = pending else { return }
            entries.append(FileHistoryEntry(
                commit: commit,
                insertions: stat?.added ?? 0, deletions: stat?.removed ?? 0,
                isBinary: stat?.binary ?? false,
                path: stat?.path ?? fallbackPath, previousPath: stat?.previous))
            pending = nil
            stat = nil
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.contains("\u{1F}") {
                flush()
                let fields = line.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 4, let date = ISO8601DateFormatter().date(from: fields[2]) else { continue }
                pending = Commit(sha: fields[0], author: fields[1], date: date,
                                 subject: fields[3], fileChanges: [])
                continue
            }
            // `added<TAB>removed<TAB>path`, with "-" for a binary file.
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, pending != nil else { continue }
            let binary = parts[0] == "-" || parts[1] == "-"
            let (previous, current) = resolveRename(parts[2])
            stat = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, binary, current, previous)
        }
        flush()
        return entries
    }

    /// git writes a rename inside a numstat path in one of two forms:
    /// `Sources/{NIO => NIOPosix}/SocketChannel.swift`, where only part of the path moved,
    /// or a bare `old/path => new/path` when the whole thing changed.
    static func resolveRename(_ field: String) -> (previous: String?, current: String) {
        guard field.contains(" => ") else { return (nil, field) }

        if let open = field.firstIndex(of: "{"), let close = field.firstIndex(of: "}"), open < close {
            let prefix = String(field[field.startIndex..<open])
            let suffix = String(field[field.index(after: close)...])
            let middle = String(field[field.index(after: open)..<close])
            let sides = middle.components(separatedBy: " => ")
            guard sides.count == 2 else { return (nil, field) }
            // An empty side means the segment was added or removed, e.g. "{ => Internal}".
            let old = (prefix + sides[0] + suffix).replacingOccurrences(of: "//", with: "/")
            let new = (prefix + sides[1] + suffix).replacingOccurrences(of: "//", with: "/")
            return (old == new ? nil : old, new)
        }

        let sides = field.components(separatedBy: " => ")
        guard sides.count == 2 else { return (nil, field) }
        return (sides[0], sides[1])
    }
}
