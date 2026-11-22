import Foundation

/// Token-level Myers/LCS diff over UTF-16 slices for highlighting multiple independent edits within a single line.
public enum InlineWordDiff {
    private struct Token {
        let range: Range<Int>
        let isWhitespace: Bool
    }

    private static let maxTokensPerLine = 240

    /// Returns merged UTF-16 ranges of changed tokens on the old and new lines.
    public static func changedUTF16Ranges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard !a.isEmpty, !b.isEmpty, a.count <= 2000, b.count <= 2000 else {
            return ([], [])
        }

        let oldTokens = tokenize(a)
        let newTokens = tokenize(b)
        guard oldTokens.count <= maxTokensPerLine, newTokens.count <= maxTokensPerLine else {
            return prefixSuffixFallback(a, b)
        }

        let m = oldTokens.count
        let n = newTokens.count
        var dp = [Int](repeating: 0, count: (m + 1) * (n + 1))
        let rowStride = n + 1

        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if tokensEqual(a, oldTokens[i].range, b, newTokens[j].range) {
                        dp[i * rowStride + j] = 1 + dp[(i + 1) * rowStride + (j + 1)]
                    } else {
                        let skipOld = dp[(i + 1) * rowStride + j]
                        let skipNew = dp[i * rowStride + (j + 1)]
                        dp[i * rowStride + j] = skipOld >= skipNew ? skipOld : skipNew
                    }
                }
            }
        }

        var oldMatched = [Bool](repeating: false, count: m)
        var newMatched = [Bool](repeating: false, count: n)
        var matchedContentTokens = 0
        var matchedContentUTF16Units = 0
        var i = 0
        var j = 0
        while i < m && j < n {
            if tokensEqual(a, oldTokens[i].range, b, newTokens[j].range) {
                oldMatched[i] = true
                newMatched[j] = true
                if !oldTokens[i].isWhitespace {
                    matchedContentTokens += 1
                    matchedContentUTF16Units += oldTokens[i].range.count
                }
                i += 1
                j += 1
            } else if dp[(i + 1) * rowStride + j] >= dp[i * rowStride + (j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }

        // Unrelated lines without shared non-whitespace structure should not be lit up edge-to-edge.
        let maxContentTokens = max(
            oldTokens.count(where: { !$0.isWhitespace }),
            newTokens.count(where: { !$0.isWhitespace })
        )
        guard matchedContentTokens >= 1,
              matchedContentUTF16Units >= 2 || maxContentTokens <= 2 else {
            return ([], [])
        }

        return (
            collectChangedRanges(tokens: oldTokens, matched: oldMatched),
            collectChangedRanges(tokens: newTokens, matched: newMatched)
        )
    }

    // MARK: - Tokenization & Merging

    private static func tokenize(_ units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            let u = units[i]
            if isHorizontalWhitespace(u) {
                let start = i
                while i < units.count && isHorizontalWhitespace(units[i]) { i += 1 }
                tokens.append(Token(range: start..<i, isWhitespace: true))
            } else if isWordUnit(u) {
                let start = i
                while i < units.count && isWordUnit(units[i]) { i += 1 }
                tokens.append(Token(range: start..<i, isWhitespace: false))
            } else if UTF16.isLeadSurrogate(u), i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) {
                tokens.append(Token(range: i..<(i + 2), isWhitespace: false))
                i += 2
            } else {
                tokens.append(Token(range: i..<(i + 1), isWhitespace: false))
                i += 1
            }
        }
        return tokens
    }

    private static func isHorizontalWhitespace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09
    }

    private static func isWordUnit(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39)
            || (u >= 0x41 && u <= 0x5A)
            || (u >= 0x61 && u <= 0x7A)
            || u == 0x5F
    }

    private static func tokensEqual(_ a: [UInt16], _ r1: Range<Int>, _ b: [UInt16], _ r2: Range<Int>) -> Bool {
        guard r1.count == r2.count else { return false }
        for offset in 0..<r1.count {
            if a[r1.lowerBound + offset] != b[r2.lowerBound + offset] { return false }
        }
        return true
    }

    private static func collectChangedRanges(tokens: [Token], matched: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var currentStart: Int?
        var currentEnd: Int = 0

        for idx in tokens.indices {
            let token = tokens[idx]
            if !matched[idx] && !token.isWhitespace {
                if currentStart == nil {
                    currentStart = token.range.lowerBound
                }
                currentEnd = token.range.upperBound
            } else if matched[idx] {
                if let start = currentStart, start < currentEnd {
                    ranges.append(start..<currentEnd)
                }
                currentStart = nil
            } else if currentStart != nil && !token.isWhitespace {
                currentEnd = token.range.upperBound
            } else if currentStart != nil && token.isWhitespace {
                // Keep bridging across whitespace only if the next token is also unmatched.
                let nextUnmatched = idx + 1 < tokens.count && !matched[idx + 1]
                if nextUnmatched {
                    currentEnd = token.range.upperBound
                } else {
                    if let start = currentStart, start < currentEnd {
                        ranges.append(start..<currentEnd)
                    }
                    currentStart = nil
                }
            }
        }
        if let start = currentStart, start < currentEnd {
            ranges.append(start..<currentEnd)
        }
        return ranges
    }

    private static func prefixSuffixFallback(_ a: [UInt16], _ b: [UInt16]) -> (old: [Range<Int>], new: [Range<Int>]) {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0,
           (prefix < a.count && UTF16.isTrailSurrogate(a[prefix]))
            || (prefix < b.count && UTF16.isTrailSurrogate(b[prefix])) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < (a.count - prefix), suffix < (b.count - prefix),
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0,
           UTF16.isTrailSurrogate(a[a.count - suffix]) || UTF16.isTrailSurrogate(b[b.count - suffix]) {
            suffix -= 1
        }
        guard prefix + suffix >= 2 else { return ([], []) }
        let oldRanges = prefix < (a.count - suffix) ? [prefix..<(a.count - suffix)] : []
        let newRanges = prefix < (b.count - suffix) ? [prefix..<(b.count - suffix)] : []
        return (oldRanges, newRanges)
    }
}
