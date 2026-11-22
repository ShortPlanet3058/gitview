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
    /// True when git emitted `rename from`/`rename to` headers for this file.
    private var sawRename = false

    /// Lines skipped because they looked like a commit header but did not parse.
    public private(set) var malformedHeaderCount = 0

    public init() {}

    public mutating func consume(line: ArraySlice<UInt8>) {
        if line.hasPrefix(Self.sentinel) {
            if let header = Self.parseCommitHeader(line) {
                flushFile()
                flushCommit()
                sha = header.sha
                author = header.author
                date = header.date
                subject = header.subject
                return
            } else if line.contains(0x1F) {
                malformedHeaderCount += 1
            }
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
                path = Self.stripPrefixLetter(Self.unquote(value.decoded))
            }
            return
        }
        if line.hasPrefix("--- ") {
            let value = line.dropFirst(4)
            if !value.elementsEqual("/dev/null".utf8) {
                oldPath = Self.stripPrefixLetter(Self.unquote(value.decoded))
            }
            return
        }
        if line.hasPrefix("rename from ") {
            oldPath = Self.unquote(line.dropFirst(12).decoded)
            sawRename = true
            return
        }
        if line.hasPrefix("rename to ") {
            path = Self.unquote(line.dropFirst(10).decoded)
            sawRename = true
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
            sawRename = false
        }
        // Only report oldPath when it genuinely differs — the `--- a/x` line is present on
        // every diff, rename or not, and a spurious oldPath would look like a rename.
        let rename = (oldPath != nil && oldPath != path) ? oldPath : nil
        // A file deleted by this commit has no counterpart in the current checkout, so no
        // units can be attributed to it. Drop it rather than carrying a dead path.
        // Keep pure 100% renames (no hunks) so rename chains preserve pre-move history.
        guard !newSideDeleted, let path, (!hunks.isEmpty || (sawRename && rename != nil)) else { return }
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

    /// Git wraps paths containing quotes, backslashes, control characters, or octal escapes
    /// in double quotes with C-style escapes, even with `core.quotePath=false`.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let bytes = Array(s.utf8.dropFirst().dropLast())
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == 0x5C else { // '\'
                out.append(b)
                i += 1
                continue
            }
            i += 1
            guard i < bytes.count else { break }
            let esc = bytes[i]
            if esc >= 0x30 && esc <= 0x37, i + 2 < bytes.count,
               bytes[i + 1] >= 0x30 && bytes[i + 1] <= 0x37,
               bytes[i + 2] >= 0x30 && bytes[i + 2] <= 0x37 {
                let value = (Int(esc - 0x30) << 6)
                    | (Int(bytes[i + 1] - 0x30) << 3)
                    | Int(bytes[i + 2] - 0x30)
                out.append(UInt8(value & 0xFF))
                i += 3
                continue
            }
            i += 1
            switch esc {
            case 0x61: out.append(0x07) // \a
            case 0x62: out.append(0x08) // \b
            case 0x66: out.append(0x0C) // \f
            case 0x6E: out.append(0x0A) // \n
            case 0x72: out.append(0x0D) // \r
            case 0x74: out.append(0x09) // \t
            case 0x76: out.append(0x0B) // \v
            case 0x22: out.append(0x22) // \"
            case 0x5C: out.append(0x5C) // \\
            default: out.append(esc)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
