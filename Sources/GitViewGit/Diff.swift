import Foundation
import GitViewCore

/// One line of a unified diff, with the numbers it has on each side.
public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable, Hashable { case context, addition, deletion }

    public let id: Int
    public let kind: Kind
    /// Its number in the old file; nil for an added line.
    public let oldNumber: Int?
    /// Its number in the new file; nil for a removed line.
    public let newNumber: Int?
    public let text: String
    /// git's "\ No newline at end of file" applies to the line above it.
    public let missingTrailingNewline: Bool
}

public struct DiffHunk: Hashable, Sendable, Identifiable {
    public var id: Int { oldStart << 20 | newStart }
    public let oldStart: Int
    public let newStart: Int
    /// The context git prints after the second `@@`, usually the enclosing function.
    public let section: String
    public let lines: [DiffLine]
}

public struct FileDiff: Hashable, Sendable {
    public let path: String
    public let oldPath: String?
    public let hunks: [DiffHunk]
    public let isBinary: Bool
    public let isNew: Bool
    public let isDeleted: Bool
    /// True when the diff was cut off at the configured line budget.
    public let truncated: Bool

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .addition }) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .deletion }) } }
    public var isEmpty: Bool { hunks.isEmpty && !isBinary }
    public var isRename: Bool { oldPath != nil && oldPath != path }

    public static func empty(path: String) -> FileDiff {
        FileDiff(path: path, oldPath: nil, hunks: [], isBinary: false,
                 isNew: false, isDeleted: false, truncated: false)
    }
}

/// Parses git's unified diff.
///
/// Written against captured output rather than the documentation, because the awkward parts
/// are only visible in real output: a new file's old side is `/dev/null`, a `\` line is a
/// marker attached to the line above rather than a line of its own, and a binary file has a
/// prose sentence where its hunks would be.
public enum DiffParser {
    /// - Parameter maxLines: a budget, because one commit can rewrite a 20,000-line file and
    ///   nobody reads that in a panel.
    public static func parse(_ output: String, path: String, maxLines: Int = 3000) -> FileDiff {
        var hunks: [DiffHunk] = []
        var isBinary = false, isNew = false, isDeleted = false, truncated = false
        var oldPath: String?
        var newPath: String?

        var oldNumber = 0, newNumber = 0
        var currentLines: [DiffLine] = []
        var currentOldStart = 0, currentNewStart = 0, currentSection = ""
        var started = false
        var counter = 0

        func closeHunk() {
            guard started else { return }
            hunks.append(DiffHunk(oldStart: currentOldStart, newStart: currentNewStart,
                                  section: currentSection, lines: currentLines))
            currentLines = []
            started = false
        }

        // git's output ends with a newline, and splitting on it leaves a final empty
        // component. Left in, every diff gains a phantom blank line at the end.
        var rawLines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }

        for raw in rawLines {
            let line = String(raw)

            if line.hasPrefix("@@") {
                closeHunk()
                guard let header = parseHunkHeader(line) else { continue }
                currentOldStart = header.oldStart
                currentNewStart = header.newStart
                currentSection = header.section
                oldNumber = header.oldStart
                newNumber = header.newStart
                started = true
                continue
            }

            guard started else {
                // Still in the file header.
                if line.hasPrefix("new file mode") { isNew = true }
                else if line.hasPrefix("deleted file mode") { isDeleted = true }
                else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { isBinary = true }
                else if line.hasPrefix("rename from ") { oldPath = String(line.dropFirst(12)) }
                else if line.hasPrefix("rename to ") { newPath = String(line.dropFirst(10)) }
                else if line.hasPrefix("--- ") {
                    let value = String(line.dropFirst(4))
                    if value == "/dev/null" { isNew = true } else { oldPath = stripPrefix(value) }
                } else if line.hasPrefix("+++ ") {
                    let value = String(line.dropFirst(4))
                    if value == "/dev/null" { isDeleted = true } else { newPath = stripPrefix(value) }
                }
                continue
            }

            if currentLines.count + hunks.reduce(0, { $0 + $1.lines.count }) >= maxLines {
                truncated = true
                break
            }

            // A "\" line annotates the previous line rather than being one.
            if line.hasPrefix("\\") {
                if let last = currentLines.popLast() {
                    currentLines.append(DiffLine(id: last.id, kind: last.kind, oldNumber: last.oldNumber,
                                                 newNumber: last.newNumber, text: last.text,
                                                 missingTrailingNewline: true))
                }
                continue
            }

            counter += 1
            switch line.first {
            case "+":
                currentLines.append(DiffLine(id: counter, kind: .addition, oldNumber: nil,
                                             newNumber: newNumber, text: String(line.dropFirst()),
                                             missingTrailingNewline: false))
                newNumber += 1
            case "-":
                currentLines.append(DiffLine(id: counter, kind: .deletion, oldNumber: oldNumber,
                                             newNumber: nil, text: String(line.dropFirst()),
                                             missingTrailingNewline: false))
                oldNumber += 1
            case " ", nil:
                // An unchanged line, or a blank one git emitted without its leading space.
                currentLines.append(DiffLine(id: counter, kind: .context, oldNumber: oldNumber,
                                             newNumber: newNumber,
                                             text: line.isEmpty ? "" : String(line.dropFirst()),
                                             missingTrailingNewline: false))
                oldNumber += 1
                newNumber += 1
            default:
                // Anything else means the hunk has ended (a new "diff --git", say).
                closeHunk()
            }
        }
        closeHunk()

        return FileDiff(path: newPath ?? path, oldPath: oldPath, hunks: hunks, isBinary: isBinary,
                        isNew: isNew, isDeleted: isDeleted, truncated: truncated)
    }

    struct HunkHeader { let oldStart: Int; let newStart: Int; let section: String }

    /// `@@ -oldStart,oldCount +newStart,newCount @@ optional section`
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        guard let close = line.range(of: " @@") else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
        var oldStart: Int?, newStart: Int?
        for token in ranges.split(separator: " ") {
            let numbers = token.dropFirst().split(separator: ",")
            guard let first = numbers.first, let value = Int(first) else { continue }
            if token.hasPrefix("-") { oldStart = value } else if token.hasPrefix("+") { newStart = value }
        }
        guard let oldStart, let newStart else { return nil }
        let section = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return HunkHeader(oldStart: oldStart, newStart: newStart, section: section)
    }

    private static func stripPrefix(_ value: String) -> String {
        if value.count > 2, value.first == "a" || value.first == "b" {
            let second = value.index(after: value.startIndex)
            if value[second] == "/" { return String(value[value.index(after: second)...]) }
        }
        return value
    }
}

/// What to diff.
public enum DiffSource: Hashable, Sendable {
    case commit(sha: String)
    case workingTree(staged: Bool)
    case range(from: String, to: String)
}

extension GitRepository {
    public func diff(_ source: DiffSource, path: String, context: Int = 3, maxLines: Int = 3000) throws -> FileDiff {
        let root = try validate()
        var arguments: [String]
        switch source {
        case .commit(let sha):
            // `--format=` suppresses the commit message, leaving only the patch.
            arguments = ["show", "--format=", "--no-color", "--find-renames", "--unified=\(context)", sha]
        case .workingTree(let staged):
            arguments = ["diff", "--no-color", "--find-renames", "--unified=\(context)"]
            if staged { arguments.append("--cached") }
        case .range(let from, let to):
            arguments = ["diff", "--no-color", "--find-renames", "--unified=\(context)", "\(from)..\(to)"]
        }
        arguments += ["--", path]
        let output = (try? GitProcess.capture(arguments: arguments, in: root)) ?? ""
        return DiffParser.parse(output, path: path, maxLines: maxLines)
    }
}
