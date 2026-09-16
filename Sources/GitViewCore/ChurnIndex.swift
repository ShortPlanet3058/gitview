import Foundation

/// Which commits touched which units.
///
/// Commits are stored once and referenced by index. Storing a `[Commit]` per unit would
/// duplicate every commit roughly as many times as it has units, which on a large repo is
/// gigabytes for no benefit.
public struct ChurnIndex: Sendable {
    public let commits: [Commit]
    /// Unit id -> indices into `commits`, newest first (git log's own order).
    public let touchesByUnit: [UUID: [Int32]]
    /// Paths seen in history that no longer exist in the checkout, after following renames.
    public let unresolvedPaths: Int
    /// Hunks that fell outside every unit in their file — blank lines, imports, and
    /// (unavoidably in v1) hunks whose line numbers have drifted since they were written.
    public let unmatchedHunks: Int
    public let matchedHunks: Int
    /// Historical path -> path in the current checkout, built from `--find-renames`.
    public let historicalPathToCurrent: [String: String]

    public func commits(for unit: CodeUnit) -> [Commit] {
        (touchesByUnit[unit.id] ?? []).map { commits[Int($0)] }
    }

    public func commitCount(for unit: CodeUnit) -> Int {
        touchesByUnit[unit.id]?.count ?? 0
    }

    public func authors(for unit: CodeUnit) -> Set<String> {
        Set((touchesByUnit[unit.id] ?? []).map { commits[Int($0)].author })
    }

    /// The path the unit's file had at `commit`, or nil when the commit does not touch it.
    ///
    /// Needed to read the file *as it was then* (`git show <sha>:<path>`): before a rename
    /// the file lived under a different name, and asking for today's path would fail.
    public func historicalPath(of unit: CodeUnit, in commit: Commit) -> String? {
        commit.fileChanges.first {
            (historicalPathToCurrent[$0.path] ?? $0.path) == unit.filePath
        }?.path
    }

    /// Newest commit touching the unit. Nil when the unit has no recorded history.
    public func lastTouched(for unit: CodeUnit) -> Date? {
        (touchesByUnit[unit.id] ?? []).map { commits[Int($0)].date }.max()
    }
}
