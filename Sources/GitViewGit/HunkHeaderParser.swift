import Foundation
import GitViewCore

/// Parses `@@ -oldStart,oldCount +newStart,newCount @@ optional section heading`.
///
/// Only the new side is retained. Counts are optional in the format and default to 1
/// when omitted (`@@ -3 +3 @@` means one line on each side).
public enum HunkHeaderParser {
    public static func parse(_ line: ArraySlice<UInt8>) -> Hunk? {
        guard line.hasPrefix("@@ ") else { return nil }

        // The ranges never contain '@', so the first " @@" after the opening marker
        // reliably terminates them — a section heading after it cannot confuse us.
        var i = line.index(line.startIndex, offsetBy: 3)
        var rangesEnd: ArraySlice<UInt8>.Index?
        var j = i
        while j < line.endIndex {
            if line[j] == 0x20, // space
               line.index(after: j) < line.endIndex, line[line.index(after: j)] == 0x40, // @
               line.index(j, offsetBy: 2) < line.endIndex, line[line.index(j, offsetBy: 2)] == 0x40 {
                rangesEnd = j
                break
            }
            j = line.index(after: j)
        }
        guard let end = rangesEnd else { return nil }

        // Scan forward for the '-' that opens the old-side range.
        while i < end, line[i] != 0x2D { i = line.index(after: i) }
        guard i < end else { return nil }
        i = line.index(after: i)

        guard let (oldStart, afterOldStart) = readInt(line, from: i, upTo: end) else { return nil }
        var oldCount = 1
        var cursor = afterOldStart
        if cursor < end, line[cursor] == 0x2C { // ','
            guard let (c, afterOldCount) = readInt(line, from: line.index(after: cursor), upTo: end) else { return nil }
            oldCount = c
            cursor = afterOldCount
        }

        // Scan forward for the '+' that opens the new-side range.
        i = cursor
        while i < end, line[i] != 0x2B { i = line.index(after: i) }
        guard i < end else { return nil }
        i = line.index(after: i)

        guard let (newStart, afterNewStart) = readInt(line, from: i, upTo: end) else { return nil }

        var newCount = 1
        if afterNewStart < end, line[afterNewStart] == 0x2C { // ','
            guard let (c, _) = readInt(line, from: line.index(after: afterNewStart), upTo: end) else { return nil }
            newCount = c
        }
        return Hunk(oldStart: oldStart, oldLineCount: oldCount, newStart: newStart, newLineCount: newCount)
    }

    /// Convenience overload; the byte version is the one used on the hot path.
    public static func parse(_ line: String) -> Hunk? {
        parse(ArraySlice(Array(line.utf8)))
    }

    private static func readInt(
        _ line: ArraySlice<UInt8>,
        from: ArraySlice<UInt8>.Index,
        upTo end: ArraySlice<UInt8>.Index
    ) -> (Int, ArraySlice<UInt8>.Index)? {
        var i = from
        var value = 0
        var digits = 0
        while i < end, line[i] >= 0x30, line[i] <= 0x39 {
            value = value * 10 + Int(line[i] - 0x30)
            digits += 1
            i = line.index(after: i)
        }
        return digits > 0 ? (value, i) : nil
    }
}
