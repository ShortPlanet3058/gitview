import Foundation
import GitViewCore

/// One recorded ref movement in `git reflog`, enabling recovery of lost commits or branches.
public struct ReflogEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(selector):\(sha)" }
    public let selector: String
    public let sha: String
    public var shortSHA: String { String(sha.prefix(7)) }
    public let action: String
    public let message: String
    public let date: Date

    public init(selector: String, sha: String, action: String, message: String, date: Date) {
        self.selector = selector
        self.sha = sha
        self.action = action
        self.message = message
        self.date = date
    }
}

public enum ReflogParser {
    /// Parses `git reflog --date=iso-strict --format=%H%x1f%gd%x1f%gs%x1f%cI`.
    public static func parse(_ output: String) -> [ReflogEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let fields = String(rawLine)
                    .split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 4 else { return nil }
                let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let selector = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let fullSummary = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sha.isEmpty,
                      !selector.isEmpty,
                      let date = ISO8601.parse(fields[3]) else {
                    return nil
                }

                let action: String
                let message: String
                if let colonRange = fullSummary.range(of: ": ") {
                    action = String(fullSummary[..<colonRange.lowerBound])
                    message = String(fullSummary[colonRange.upperBound...])
                } else if fullSummary.hasSuffix(":") {
                    action = String(fullSummary.dropLast())
                    message = ""
                } else {
                    action = "event"
                    message = fullSummary
                }

                return ReflogEntry(
                    selector: selector,
                    sha: sha,
                    action: action,
                    message: message,
                    date: date
                )
            }
    }
}

extension GitRepository {
    /// Reads the recent reflog entries for HEAD (`git reflog`).
    public func reflog(limit: Int = 100) throws -> [ReflogEntry] {
        let root = try validate()
        do {
            let output = try GitProcess.capture(
                arguments: [
                    "reflog",
                    "-n", "\(max(1, limit))",
                    "--date=iso-strict",
                    "--format=%H%x1f%gd%x1f%gs%x1f%cI",
                ],
                in: root
            )
            return ReflogParser.parse(output)
        } catch GitError.failed(_, _, let stderr)
            where stderr.contains("does not have any commits yet") || stderr.contains("bad default revision") {
            return []
        }
    }
}
