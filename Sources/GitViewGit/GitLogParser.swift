import Foundation
import GitViewCore

/// Incremental state machine over `git log --unified=0 -p` output.
///
/// Incremental rather than buffer-then-parse because a repository with 10k+ commits
/// produces hundreds of megabytes of patch text. Only the parsed model is retained;
/// raw diff bodies are discarded as they stream past.
public struct GitLogParser {
    /// Line prefix that marks a commit header. Chosen because diff bodies contain bare
    /// `@@` hunk headers, so splitting on `@@` would shred every commit.
    private static let sentinel: StaticString = "@@@"

    public private(set) var commits: [Commit] = []

    // Current commit
    private var sha: String?
    private var author: String = ""
    private var date: Date = .distantPast
    private var subject: String = ""
    private var fileChanges: [FileChange] = []

    // Current file within the commit
    private var path: String?
    private var oldPath: String?
    private var hunks: [Hunk] = []
    /// True when the new side is /dev/null, i.e. the file was deleted by this commit.
    private var newSideDeleted = false

    /// Lines skipped because they looked like a commit header but did not parse.
    public private(set) var malformedHeaderCount = 0

    public init() {}

    public mutating func consume(line: ArraySlice<UInt8>) {
        if line.hasPrefix(Self.sentinel), let header = Self.parseCommitHeader(line) {
            flushFile()
            flushCommit()
            sha = header.sha
            author = header.author
            date = header.date
            subject = header.subject
            return
        }

        // Everything below only makes sense inside a commit.
        guard sha != nil else { return }

        if line.hasPrefix("diff --git ") {
            flushFile()
            return
        }
        if line.hasPrefix("@@ ") {
            if let hunk = HunkHeaderParser.parse(line) { hunks.append(hunk) }
            return
        }
        if line.hasPrefix("+++ ") {
            let value = line.dropFirst(4)
            if value.elementsEqual("/dev/null".utf8) {
                newSideDeleted = true
            } else {
                path = Self.unquote(Self.stripPrefixLetter(value.decoded))
            }
            return
        }
        if line.hasPrefix("--- ") {
            let value = line.dropFirst(4)
            if !value.elementsEqual("/dev/null".utf8) {
                oldPath = Self.unquote(Self.stripPrefixLetter(value.decoded))
            }
            return
        }
        if line.hasPrefix("rename from ") {
            oldPath = Self.unquote(line.dropFirst(12).decoded)
            return
        }
        if line.hasPrefix("rename to ") {
            path = Self.unquote(line.dropFirst(10).decoded)
            return
        }
    }

    public mutating func finish() -> [Commit] {
        flushFile()
        flushCommit()
        return commits
    }

    // MARK: - Flushing

    private mutating func flushFile() {
        defer {
            path = nil
            oldPath = nil
            hunks = []
            newSideDeleted = false
        }
        // A file deleted by this commit has no counterpart in the current checkout, so no
        // units can be attributed to it. Drop it rather than carrying a dead path.
        guard !newSideDeleted, let path, !hunks.isEmpty else { return }
        // Only report oldPath when it genuinely differs — the `--- a/x` line is present on
        // every diff, rename or not, and a spurious oldPath would look like a rename.
        let rename = (oldPath != nil && oldPath != path) ? oldPath : nil
        fileChanges.append(FileChange(path: path, oldPath: rename, hunks: hunks))
    }

    private mutating func flushCommit() {
        defer {
            sha = nil
            author = ""
            date = .distantPast
            subject = ""
            fileChanges = []
        }
        guard let sha else { return }
        commits.append(Commit(sha: sha, author: author, date: date, subject: subject, fileChanges: fileChanges))
    }

    // MARK: - Header parsing

    struct Header { let sha: String; let author: String; let date: Date; let subject: String }

    /// Field separator in the commit header: ASCII unit separator, emitted by `%x1f`.
    static let fieldSeparator: Character = "\u{1F}"

    /// Parses `@@@<sha> US <author> US <iso8601 date> [US <subject>]`.
    ///
    /// Author names and subjects are arbitrary text — pipes, colons and tabs all occur in
    /// real histories — so no printable separator is safe. 0x1F is a control character git
    /// never emits inside these fields. The subject is split with `maxSplits` so a stray
    /// separator inside it cannot shift fields.
    static func parseCommitHeader(_ line: ArraySlice<UInt8>) -> Header? {
        let body = line.dropFirst(3).decoded
        let fields = body.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }

        let sha = String(fields[0])
        // A sha is 40 (or 64) hex characters. Requiring that stops a diff body line
        // beginning with "@@@" from being mistaken for a commit boundary.
        guard sha.count == 40 || sha.count == 64,
              sha.allSatisfy({ $0.isHexDigit }) else { return nil }

        guard let date = ISO8601.parse(String(fields[2])) else { return nil }
        let subject = fields.count > 3 ? String(fields[3]) : ""
        return Header(sha: sha, author: String(fields[1]), date: date, subject: subject)
    }

    // MARK: - Path handling

    /// Strips the `a/` or `b/` prefix git puts on diff paths.
    private static func stripPrefixLetter(_ s: String) -> String {
        if s.count > 2, s.first == "a" || s.first == "b" {
            let second = s.index(after: s.startIndex)
            if s[second] == "/" { return String(s[s.index(after: second)...]) }
        }
        return s
    }

    /// Git wraps paths containing quotes, backslashes or control characters in double
    /// quotes with C-style escapes, even with `core.quotePath=false`.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        var out = ""
        var iterator = s.dropFirst().dropLast().makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append(escaped)
            }
        }
        return out
    }
}
