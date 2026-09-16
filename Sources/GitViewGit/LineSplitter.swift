import Foundation

/// Splits an arbitrary byte stream into newline-terminated lines, carrying a partial
/// line across chunk boundaries.
///
/// Works on bytes rather than `String` on purpose: `git log -p` output can contain
/// invalid UTF-8 (binary hunks, files in legacy encodings). Decoding the whole stream
/// would either throw away good commits or replace bytes lossily. Only the handful of
/// header lines we actually care about get decoded, and only once identified.
struct LineSplitter {
    private var carry: [UInt8] = []

    /// Feeds a chunk, invoking `onLine` for each complete line (newline stripped).
    mutating func feed(_ chunk: Data, onLine: (ArraySlice<UInt8>) -> Void) {
        var buffer = carry
        buffer.append(contentsOf: chunk)
        carry = []

        var lineStart = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            if buffer[i] == 0x0A { // \n
                onLine(buffer[lineStart..<i])
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart < buffer.endIndex {
            carry = Array(buffer[lineStart...])
        }
    }

    /// Emits any trailing line that was not newline-terminated.
    mutating func finish(onLine: (ArraySlice<UInt8>) -> Void) {
        if !carry.isEmpty {
            onLine(carry[...])
            carry = []
        }
    }
}

extension ArraySlice<UInt8> {
    func hasPrefix(_ ascii: StaticString) -> Bool {
        let count = ascii.utf8CodeUnitCount
        guard self.count >= count else { return false }
        let base = ascii.utf8Start
        var i = startIndex
        for k in 0..<count {
            if self[i] != base[k] { return false }
            i += 1
        }
        return true
    }

    /// Decodes the slice as UTF-8, substituting replacement characters rather than failing.
    var decoded: String { String(decoding: self, as: UTF8.self) }
}
