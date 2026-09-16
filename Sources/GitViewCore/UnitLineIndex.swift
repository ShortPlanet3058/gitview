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
    private let starts: [Int]
    private let ends: [Int]
    private let ids: [UUID]
    /// `maxEndSoFar[i]` is the largest end line among units `0...i`.
    private let maxEndSoFar: [Int]

    public init(units: [CodeUnit]) {
        let sorted = units.sorted {
            $0.lineRange.lowerBound == $1.lineRange.lowerBound
                ? $0.lineRange.upperBound < $1.lineRange.upperBound
                : $0.lineRange.lowerBound < $1.lineRange.lowerBound
        }
        self.starts = sorted.map(\.lineRange.lowerBound)
        self.ends = sorted.map(\.lineRange.upperBound)
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
}
