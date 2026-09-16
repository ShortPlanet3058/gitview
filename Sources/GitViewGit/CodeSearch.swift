import Foundation
import GitViewCore

/// One matching line in the working tree.
public struct CodeMatch: Identifiable, Hashable, Sendable {
    public var id: String { "\(path):\(line)" }
    public let path: String
    public let line: Int
    public let text: String
}

extension GitRepository {
    /// Searches the contents of tracked files. About 0.08s across swift-nio, so it is fast
    /// enough to run as part of a search rather than behind a separate button.
    ///
    /// `-I` skips binary files, and `-z` separates the path and line number with NUL so a
    /// path containing a colon cannot be mis-split — which `path:line:text` would.
    public func grep(_ pattern: String, limit: Int = 200) throws -> [CodeMatch] {
        let root = try validate()
        // A fixed-string search: people type symbols, not regular expressions.
        let output = try? GitProcess.capture(
            arguments: ["grep", "-z", "-n", "-I", "--no-color", "--fixed-strings",
                        "--max-count=\(max(limit / 10, 3))", "-e", pattern], in: root)
        return CodeSearchParser.parseGrep(output ?? "", limit: limit)
    }

    /// Commits that changed how many times `term` appears — git's "pickaxe".
    ///
    /// This is the archaeology question: when was this symbol introduced, and when did it
    /// disappear? No header-only log parser exists elsewhere, because the main history read
    /// needs diffs; this one deliberately does not.
    public func commitsChanging(_ term: String, limit: Int = 40) throws -> [Commit] {
        let root = try validate()
        let output = try GitProcess.capture(
            arguments: ["log", "--max-count=\(limit)", "--pretty=format:%H%x1f%aN%x1f%aI%x1f%s",
                        "-S", term, "--no-color"], in: root)
        return CodeSearchParser.parseCommitHeaders(output)
    }
}

enum CodeSearchParser {
    /// `git grep -z -n` emits `path NUL line NUL text` per matching line.
    static func parseGrep(_ output: String, limit: Int) -> [CodeMatch] {
        var matches: [CodeMatch] = []
        for row in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = row.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let line = Int(fields[1]) else { continue }
            let text = String(fields[2]).trimmingCharacters(in: .whitespaces)
            matches.append(CodeMatch(path: String(fields[0]), line: line, text: text))
            if matches.count >= limit { break }
        }
        return matches
    }

    /// `%H %aN %aI %s`, one commit per line, with no diff.
    static func parseCommitHeaders(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 4, let date = ISO8601DateFormatter().date(from: fields[2]) else { return nil }
            return Commit(sha: fields[0], author: fields[1], date: date,
                          subject: fields[3], fileChanges: [])
        }
    }
}
