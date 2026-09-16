import Foundation
import GitViewCore

/// Line-level ownership of one file: who wrote the code that is actually there now.
///
/// This is the exact answer, where `OwnershipIndex` gives the cheap one. It costs a process
/// and about a quarter of a second per file, so it is computed for the file being looked at
/// and never across a repository.
public struct BlameOwnership: Sendable, Hashable {
    public struct Share: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let lines: Int
        /// Fraction of the file's current lines, 0...1.
        public let share: Double
        public let newestLine: Date
    }

    public let path: String
    public let totalLines: Int
    /// Most lines first.
    public let authors: [Share]
    public let oldestLine: Date?
    public let newestLine: Date?

    public var primary: Share? { authors.first }
}

public enum BlameParser {
    /// Parses `git blame --line-porcelain`, which repeats a full header for every line.
    ///
    /// Names arrive already resolved through .mailmap — verified against swift-nio, whose
    /// mailmap merges two spellings of its top contributor — so blame and history agree on
    /// who someone is.
    public static func parse(_ output: String, path: String) -> BlameOwnership {
        struct Totals { var lines = 0; var newest = Date.distantPast }
        var byAuthor: [String: Totals] = [:]
        var total = 0
        var oldest: Date?
        var newest: Date?

        var pendingAuthor: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("author ") && !line.hasPrefix("author-") {
                pendingAuthor = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time "), let author = pendingAuthor,
                      let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                let date = Date(timeIntervalSince1970: seconds)
                var totals = byAuthor[author, default: Totals()]
                totals.lines += 1
                totals.newest = max(totals.newest, date)
                byAuthor[author] = totals
                total += 1
                oldest = min(oldest ?? date, date)
                newest = max(newest ?? date, date)
                pendingAuthor = nil
            }
        }

        let authors = byAuthor
            .map { name, totals in
                BlameOwnership.Share(name: name, lines: totals.lines,
                                     share: total > 0 ? Double(totals.lines) / Double(total) : 0,
                                     newestLine: totals.newest)
            }
            .sorted { $0.lines != $1.lines ? $0.lines > $1.lines : $0.name < $1.name }
        return BlameOwnership(path: path, totalLines: total, authors: authors,
                              oldestLine: oldest, newestLine: newest)
    }
}

extension GitRepository {
    /// Line ownership of one file as it stands now.
    ///
    /// `-w` ignores whitespace-only changes and `-M` follows lines moved within the file,
    /// so a reformatting pass does not make whoever ran it the owner of everything.
    public func blame(path: String) throws -> BlameOwnership {
        let root = try validate()
        let output = try GitProcess.capture(
            arguments: ["blame", "--line-porcelain", "-w", "-M", "--", path], in: root)
        return BlameParser.parse(output, path: path)
    }
}
