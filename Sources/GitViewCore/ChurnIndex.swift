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

    public func commits(for unit: CodeUnit) -> [Commit] {
        (touchesByUnit[unit.id] ?? []).map { commits[Int($0)] }
    }

    public func commitCount(for unit: CodeUnit) -> Int {
        touchesByUnit[unit.id]?.count ?? 0
    }

    public func authors(for unit: CodeUnit) -> Set<String> {
        Set((touchesByUnit[unit.id] ?? []).map { commits[Int($0)].author })
    }

    /// Newest commit touching the unit. Nil when the unit has no recorded history.
    public func lastTouched(for unit: CodeUnit) -> Date? {
        (touchesByUnit[unit.id] ?? []).map { commits[Int($0)].date }.max()
    }
}
