import Foundation
import GitViewCore

/// A tag, which for most repositories means a release.
public struct TagInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// The commit the tag ultimately points at, peeled through an annotated tag object.
    public let commitSHA: String
    public let date: Date
    /// Only annotated tags carry a tagger and a message of their own.
    public let taggerName: String?
    /// The tag's own message when annotated; otherwise the subject of the commit it points
    /// at, which is not the same thing and is labelled differently in the UI.
    public let subject: String
    public let isAnnotated: Bool
}

/// Lines added and removed between two points.
public struct DiffStat: Hashable, Sendable {
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int

    public init(filesChanged: Int, insertions: Int, deletions: Int) {
        self.filesChanged = filesChanged; self.insertions = insertions; self.deletions = deletions
    }

    public static let zero = DiffStat(filesChanged: 0, insertions: 0, deletions: 0)
    public var isEmpty: Bool { filesChanged == 0 }
}

public struct FileDelta: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let insertions: Int
    public let deletions: Int

    /// True for a binary file, where git reports "-" instead of counts.
    public let isBinary: Bool
    public var churn: Int { insertions + deletions }

    public init(path: String, insertions: Int, deletions: Int, isBinary: Bool) {
        self.path = path; self.insertions = insertions
        self.deletions = deletions; self.isBinary = isBinary
    }
}

extension GitRepository {
    /// Tags, newest first.
    ///
    /// Handles both kinds. A lightweight tag is just a name on a commit: `objecttype` is
    /// `commit`, there is no tagger, and what looks like a tag message is really the
    /// commit's subject. All 188 of swift-nio's tags are lightweight, so this is the normal
    /// case, not the exception.
    public func tags(limit: Int = 1000) throws -> [TagInfo] {
        let root = try validate()
        let format = [
            "%(refname:short)", "%(objecttype)", "%(objectname)", "%(*objectname)",
            "%(creatordate:iso-strict)", "%(taggername)", "%(contents:subject)",
        ].joined(separator: "%1f")
        let output = try GitProcess.capture(
            arguments: ["for-each-ref", "refs/tags", "--sort=-creatordate",
                        "--count=\(limit)", "--format=\(format)"], in: root)
        return TagParser.parse(output)
    }

    /// Commits reachable from `to` but not from `from`, with their file changes.
    public func commits(from: String, to: String) throws -> [Commit] {
        try loadHistory(range: "\(from)..\(to)")
    }

    /// Per-file line counts between two points.
    public func fileDeltas(from: String, to: String) throws -> [FileDelta] {
        let root = try validate()
        let output = try GitProcess.capture(
            arguments: ["diff", "--numstat", "-z", "--find-renames", "\(from)..\(to)"], in: root)
        return DiffStatParser.parseNumstat(output)
    }

    public func diffStat(from: String, to: String) throws -> DiffStat {
        let deltas = try fileDeltas(from: from, to: to)
        return DiffStat(filesChanged: deltas.count,
                        insertions: deltas.reduce(0) { $0 + $1.insertions },
                        deletions: deltas.reduce(0) { $0 + $1.deletions })
    }

    /// Every ref that can be compared: branches first, then tags.
    public func comparableRefs(branches: [BranchInfo], tags: [TagInfo]) -> [String] {
        branches.map { $0.isRemote ? "origin/\($0.name)" : $0.name } + tags.map(\.name)
    }
}

enum TagParser {
    static func parse(_ output: String) -> [TagInfo] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 6, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 7, !fields[0].isEmpty else { return nil }
            let isAnnotated = fields[1] == "tag"
            // An annotated tag's own object id is not the commit; the peeled field is.
            let commit = fields[3].isEmpty ? fields[2] : fields[3]
            guard let date = ISO8601DateFormatter().date(from: fields[4]) else { return nil }
            return TagInfo(name: fields[0], commitSHA: commit, date: date,
                           taggerName: fields[5].isEmpty ? nil : fields[5],
                           subject: fields[6], isAnnotated: isAnnotated)
        }
    }
}

enum DiffStatParser {
    /// `git diff --numstat -z`: `<added>\t<removed>\t<path>` with NUL terminators, and for a
    /// rename the old and new paths follow as two further NUL-separated fields.
    static func parseNumstat(_ output: String) -> [FileDelta] {
        var deltas: [FileDelta] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 2 else { continue }
            // A binary file reports "-" for both counts.
            let isBinary = parts[0] == "-" || parts[1] == "-"
            let added = Int(parts[0]) ?? 0
            let removed = Int(parts[1]) ?? 0

            var path: String
            if parts.count == 3, !parts[2].isEmpty {
                path = parts[2]
            } else {
                // Rename: the record ends after the counts, and the two paths follow.
                let old = index < records.count ? records[index] : ""
                index += 1
                let new = index < records.count ? records[index] : ""
                index += 1
                path = new.isEmpty ? old : new
            }
            guard !path.isEmpty else { continue }
            deltas.append(FileDelta(path: path, insertions: added, deletions: removed, isBinary: isBinary))
        }
        return deltas.sorted { $0.churn != $1.churn ? $0.churn > $1.churn : $0.path < $1.path }
    }
}
