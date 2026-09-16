import Foundation

/// A syntactic unit extracted from the *current* checkout of a file.
///
/// Line ranges are 1-based and inclusive, matching both editor convention and
/// the line numbers git reports in hunk headers.
public struct CodeUnit: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case function, method, `class`
    }

    public let id: UUID
    public let filePath: String
    public let name: String
    public let kind: Kind
    public let lineRange: ClosedRange<Int>
    public let complexity: Int
    public let nestingDepth: Int
    public let lineCount: Int
    /// Identifier of the language this unit was parsed from ("swift", "python", …).
    public let language: String

    public init(
        id: UUID = UUID(),
        filePath: String,
        name: String,
        kind: Kind,
        lineRange: ClosedRange<Int>,
        complexity: Int,
        nestingDepth: Int,
        lineCount: Int,
        language: String = "swift"
    ) {
        self.id = id
        self.filePath = filePath
        self.name = name
        self.kind = kind
        self.lineRange = lineRange
        self.complexity = complexity
        self.nestingDepth = nestingDepth
        self.lineCount = lineCount
        self.language = language
    }
}

public struct Commit: Hashable, Sendable {
    public let sha: String
    public let author: String
    public let date: Date
    /// First line of the commit message.
    public let subject: String
    public let fileChanges: [FileChange]

    public init(sha: String, author: String, date: Date, subject: String = "", fileChanges: [FileChange]) {
        self.sha = sha
        self.author = author
        self.date = date
        self.subject = subject
        self.fileChanges = fileChanges
    }
}

public struct FileChange: Hashable, Sendable {
    /// Path as of this commit's *new* side. Nil-path (deleted file) changes are dropped
    /// by the parser, since a deleted file has no units in the current checkout.
    public let path: String
    /// Populated only when git detected a rename (`--find-renames`).
    public let oldPath: String?
    public let hunks: [Hunk]

    public init(path: String, oldPath: String?, hunks: [Hunk]) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks
    }
}

/// One `@@` hunk header, new-side only.
///
/// With `--unified=0` there is no context, so `newStart ..< newStart + newLineCount`
/// is exactly the set of lines this commit added or modified.
///
/// `newLineCount == 0` is a **pure deletion**: the commit removed lines and added
/// nothing. Git reports `+start,0` where `start` is the line *before* which the
/// removal happened. Such a hunk covers no new lines at all, so callers that need
/// a non-empty range must decide how to represent it — see `touchedLineRange`.
public struct Hunk: Hashable, Sendable {
    public let newStart: Int
    public let newLineCount: Int

    public init(newStart: Int, newLineCount: Int) {
        self.newStart = newStart
        self.newLineCount = newLineCount
    }

    /// The inclusive line range this hunk touches, for intersecting against unit ranges.
    ///
    /// For an ordinary hunk this is `newStart ... newStart + newLineCount - 1`.
    ///
    /// For a pure deletion (`newLineCount == 0`) there is no new line to point at, so we
    /// attribute the change to the single line at `newStart`. This is a deliberate choice,
    /// not an off-by-one: a deletion inside a function is real churn for that function and
    /// dropping it would under-count. It does mean a deletion sitting exactly on a unit
    /// boundary can be attributed to the neighbouring unit.
    public var touchedLineRange: ClosedRange<Int> {
        let start = max(newStart, 1)
        guard newLineCount > 0 else { return start ... start }
        return start ... (start + newLineCount - 1)
    }
}
