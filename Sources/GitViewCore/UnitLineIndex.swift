import Foundation

/// Per-file index answering "which units overlap this line range?".
///
/// A linear scan would be O(hunks × units-in-file); git/git has 1.48M hunks, so that is
/// the difference between seconds and minutes. Units are sorted by start line and carry a
/// running maximum of end lines, which lets a backwards scan stop as soon as no earlier
/// unit could possibly reach the query.
///
/// The running maximum is what makes this correct in the presence of *nested* units: a
/// type starts long before its methods and ends long after them, so "sorted by start" alone
/// gives no valid stopping condition.
public struct UnitLineIndex: Sendable {
    private var starts: [Int]
    private var ends: [Int]
    private var ids: [UUID]
    /// `maxEndSoFar[i]` is the largest end line among units `0...i`.
    private var maxEndSoFar: [Int]

    public init(units: [CodeUnit]) {
        let entries = units.map { ($0.lineRange.lowerBound, $0.lineRange.upperBound, $0.id) }
        self.init(entries: entries)
    }

    private init(entries: [(start: Int, end: Int, id: UUID)]) {
        let sorted = entries.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        self.starts = sorted.map(\.start)
        self.ends = sorted.map(\.end)
        self.ids = sorted.map(\.id)

        var running = -1
        var maxima: [Int] = []
        maxima.reserveCapacity(sorted.count)
        for end in self.ends {
            running = max(running, end)
            maxima.append(running)
        }
        self.maxEndSoFar = maxima
    }

    public var count: Int { ids.count }

    /// Appends the ids of every unit overlapping `range` to `result`.
    ///
    /// Appends rather than returns so the caller can reuse one buffer across millions of
    /// hunks instead of allocating an array per query.
    public func units(overlapping range: ClosedRange<Int>, into result: inout [UUID]) {
        guard !ids.isEmpty else { return }

        // Last unit whose start is <= range.upperBound. Anything after it starts too late.
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= range.upperBound { low = mid + 1 } else { high = mid }
        }
        var index = low - 1

        while index >= 0 {
            // No unit at or before `index` reaches the query — nothing left to find.
            if maxEndSoFar[index] < range.lowerBound { return }
            if ends[index] >= range.lowerBound {
                result.append(ids[index])
            }
            index -= 1
        }
    }

    public func units(overlapping range: ClosedRange<Int>) -> [UUID] {
        var result: [UUID] = []
        units(overlapping: range, into: &result)
        return result
    }

    /// Maps unit line intervals backward from post-commit coordinates to pre-commit
    /// coordinates across `change`, retiring units created in this commit or file.
    public mutating func applyReverseChange(_ change: FileChange) {
        guard !ids.isEmpty else { return }
        if change.isNewFile {
            starts = []; ends = []; ids = []; maxEndSoFar = []
            return
        }
        guard !change.hunks.isEmpty else { return }
        let hunks = change.hunks.count > 1
            ? change.hunks.sorted { ($0.newStart, $0.oldStart) < ($1.newStart, $1.oldStart) }
            : change.hunks

        // Fast skip when no hunk shifts line counts at all (pure in-place edits or synthetic zero-delta hunks).
        let anyShift = hunks.contains { $0.oldLineCount != $0.newLineCount || ($0.oldLineCount == 0 && $0.newLineCount > 0) }
        guard anyShift else { return }

        var shifted: [(start: Int, end: Int, id: UUID)] = []
        shifted.reserveCapacity(ids.count)
        for idx in 0..<ids.count {
            guard let mapped = Self.mapRangeBackward(starts[idx]...ends[idx], hunks: hunks) else {
                continue
            }
            shifted.append((mapped.lowerBound, mapped.upperBound, ids[idx]))
        }
        self = UnitLineIndex(entries: shifted)
    }

    private static func mapRangeBackward(_ range: ClosedRange<Int>, hunks: [Hunk]) -> ClosedRange<Int>? {
        let low = mapStartBackward(range.lowerBound, hunks: hunks)
        let high = mapEndBackward(range.upperBound, hunks: hunks)
        guard low <= high else { return nil }
        return max(1, low)...max(1, high)
    }

    private static func mapStartBackward(_ point: Int, hunks: [Hunk]) -> Int {
        var delta = 0
        for hunk in hunks {
            if hunk.newLineCount == 0 {
                if point <= hunk.newStart { break }
                delta += hunk.oldLineCount
            } else {
                let hunkNewEnd = hunk.newStart + hunk.newLineCount - 1
                if point < hunk.newStart { break }
                if point <= hunkNewEnd {
                    return hunk.oldLineCount == 0 ? hunk.oldStart + 1 : max(1, hunk.oldStart)
                }
                delta += hunk.oldLineCount - hunk.newLineCount
            }
        }
        return point + delta
    }

    private static func mapEndBackward(_ point: Int, hunks: [Hunk]) -> Int {
        var delta = 0
        for hunk in hunks {
            if hunk.newLineCount == 0 {
                if point <= hunk.newStart { break }
                delta += hunk.oldLineCount
            } else {
                let hunkNewEnd = hunk.newStart + hunk.newLineCount - 1
                if point < hunk.newStart { break }
                if point <= hunkNewEnd {
                    return hunk.oldLineCount == 0 ? hunk.oldStart : hunk.oldStart + hunk.oldLineCount - 1
                }
                delta += hunk.oldLineCount - hunk.newLineCount
            }
        }
        return point + delta
    }
}
