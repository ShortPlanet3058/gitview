import Foundation

/// Joins parsed units against commit history in a single pass over the hunks.
///
/// Deliberately *not* `git log -L <start>,<end>:<file>`: that spawns a process per function
/// and re-walks history each time, which on a few thousand functions takes minutes.
///
/// ## Known imprecision, accepted for v1
///
/// Unit line ranges come from the current checkout, but a hunk's line numbers are those of
/// the file as it stood at that commit. Files drift, so the further back a commit is, the
/// less reliable the attribution. The mitigation is to weight recent commits far more
/// heavily in the risk score rather than to fix the attribution — a `git blame
/// --line-porcelain` per revision would be correct but costs a process per revision.
public enum ChurnJoiner {

    /// - Parameters:
    ///   - units: units from the current checkout.
    ///   - commits: history in `git log` order, **newest first**. Rename resolution walks
    ///     backwards through time and depends on this ordering.
    public static func join(units: [CodeUnit], commits: [Commit]) -> ChurnIndex {
        var indexByPath: [String: UnitLineIndex] = [:]
        for (path, group) in Dictionary(grouping: units, by: \.filePath) {
            indexByPath[path] = UnitLineIndex(units: group)
        }

        var touches: [UUID: [Int32]] = [:]
        touches.reserveCapacity(units.count)

        // Maps a path as it was named at some point in history to its name in the current
        // checkout. Built while walking newest -> oldest: when commit C renames X to Y,
        // every commit older than C that mentions X is talking about what is now Y.
        // Chains compose because Y itself is resolved through the map first.
        var currentPath: [String: String] = [:]

        var unresolved = 0
        var matched = 0
        var unmatched = 0
        var buffer: [UUID] = []
        buffer.reserveCapacity(16)

        for (commitIndex, commit) in commits.enumerated() {
            let commitIndex32 = Int32(commitIndex)

            for change in commit.fileChanges {
                let resolved = currentPath[change.path] ?? change.path
                if let oldPath = change.oldPath {
                    currentPath[oldPath] = resolved
                }

                guard let index = indexByPath[resolved] else {
                    // File no longer exists in the checkout, or is not a language we parse.
                    unresolved += change.hunks.count
                    continue
                }

                for hunk in change.hunks {
                    buffer.removeAll(keepingCapacity: true)
                    index.units(overlapping: hunk.touchedLineRange, into: &buffer)
                    if buffer.isEmpty {
                        unmatched += 1
                        continue
                    }
                    matched += 1
                    for id in buffer {
                        // One commit can touch a unit through several hunks; count it once.
                        // Commits are processed in order, so a duplicate is always last.
                        if touches[id]?.last == commitIndex32 { continue }
                        touches[id, default: []].append(commitIndex32)
                    }
                }
            }
        }

        return ChurnIndex(
            commits: commits,
            touchesByUnit: touches,
            unresolvedPaths: unresolved,
            unmatchedHunks: unmatched,
            matchedHunks: matched,
            historicalPathToCurrent: currentPath
        )
    }
}
