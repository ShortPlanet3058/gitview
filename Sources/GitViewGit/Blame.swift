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

    public struct Line: Sendable, Hashable, Identifiable {
        public var id: Int { lineNumber }
        public let lineNumber: Int
        public let originalLine: Int
        public let sha: String
        public let author: String
        public let date: Date?
        public let summary: String
        public let previousSHA: String?
        public let previousPath: String?
        public let text: String

        public init(
            lineNumber: Int,
            originalLine: Int,
            sha: String,
            author: String,
            date: Date?,
            summary: String,
            previousSHA: String? = nil,
            previousPath: String? = nil,
            text: String
        ) {
            self.lineNumber = lineNumber
            self.originalLine = originalLine
            self.sha = sha
            self.author = author
            self.date = date
            self.summary = summary
            self.previousSHA = previousSHA
            self.previousPath = previousPath
            self.text = text
        }

        public var isUncommitted: Bool {
            !sha.isEmpty && sha.allSatisfy { $0 == "0" }
        }
    }

    public let path: String
    public let revision: String?
    public let totalLines: Int
    /// Most lines first.
    public let authors: [Share]
    public let oldestLine: Date?
    public let newestLine: Date?
    public let lines: [Line]

    public var primary: Share? { authors.first }

    public init(
        path: String,
        revision: String? = nil,
        totalLines: Int,
        authors: [Share],
        oldestLine: Date?,
        newestLine: Date?,
        lines: [Line] = []
    ) {
        self.path = path
        self.revision = revision
        self.totalLines = totalLines
        self.authors = authors
        self.oldestLine = oldestLine
        self.newestLine = newestLine
        self.lines = lines
    }
}

public enum BlameParser {
    private struct CommitMeta {
        var author: String = ""
        var date: Date?
        var summary: String = ""
        var previousSHA: String?
        var previousPath: String?
    }

    /// Parses `git blame --line-porcelain` (or abbreviated header repeats cached by SHA).
    ///
    /// Names arrive already resolved through .mailmap — verified against swift-nio, whose
    /// mailmap merges two spellings of its top contributor — so blame and history agree on
    /// who someone is.
    public static func parse(_ output: String, path: String, revision: String? = nil) -> BlameOwnership {
        struct Totals { var lines = 0; var newest = Date.distantPast }
        var byAuthor: [String: Totals] = [:]
        var metaBySHA: [String: CommitMeta] = [:]
        var parsedLines: [BlameOwnership.Line] = []
        var total = 0
        var oldest: Date?
        var newest: Date?

        var currentHeader: (sha: String, originalLine: Int, lineNumber: Int)?
        var currentMeta = CommitMeta()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let header = currentHeader {
                if rawLine.hasPrefix("\t") {
                    metaBySHA[header.sha] = currentMeta
                    var text = String(rawLine.dropFirst())
                    if text.hasSuffix("\r") { text.removeLast() }
                    let authorName = currentMeta.author
                    let date = currentMeta.date
                    if !authorName.isEmpty, let date {
                        var totals = byAuthor[authorName, default: Totals()]
                        totals.lines += 1
                        totals.newest = max(totals.newest, date)
                        byAuthor[authorName] = totals
                        total += 1
                        oldest = min(oldest ?? date, date)
                        newest = max(newest ?? date, date)
                    } else if !authorName.isEmpty {
                        total += 1
                    }
                    parsedLines.append(BlameOwnership.Line(
                        lineNumber: header.lineNumber,
                        originalLine: header.originalLine,
                        sha: header.sha,
                        author: authorName,
                        date: date,
                        summary: currentMeta.summary,
                        previousSHA: currentMeta.previousSHA,
                        previousPath: currentMeta.previousPath,
                        text: text
                    ))
                    currentHeader = nil
                } else if rawLine.hasPrefix("author ") && !rawLine.hasPrefix("author-") {
                    currentMeta.author = String(rawLine.dropFirst("author ".count))
                } else if rawLine.hasPrefix("author-time "),
                          let seconds = TimeInterval(rawLine.dropFirst("author-time ".count)) {
                    currentMeta.date = Date(timeIntervalSince1970: seconds)
                } else if rawLine.hasPrefix("summary ") {
                    currentMeta.summary = String(rawLine.dropFirst("summary ".count))
                } else if rawLine.hasPrefix("previous ") {
                    let rest = rawLine.dropFirst("previous ".count)
                    if let space = rest.firstIndex(of: " ") {
                        currentMeta.previousSHA = String(rest[..<space])
                        currentMeta.previousPath = String(rest[rest.index(after: space)...])
                    }
                }
            } else if !rawLine.isEmpty && !rawLine.hasPrefix("\t") {
                let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3,
                   let originalLine = Int(parts[1]),
                   let lineNumber = Int(parts[2]) {
                    let sha = String(parts[0])
                    currentHeader = (sha, originalLine, lineNumber)
                    currentMeta = metaBySHA[sha] ?? CommitMeta()
                }
            }
        }

        let authors = byAuthor
            .map { name, totals in
                BlameOwnership.Share(name: name, lines: totals.lines,
                                     share: total > 0 ? Double(totals.lines) / Double(total) : 0,
                                     newestLine: totals.newest)
            }
            .sorted { $0.lines != $1.lines ? $0.lines > $1.lines : $0.name < $1.name }
        return BlameOwnership(
            path: path,
            revision: revision,
            totalLines: total,
            authors: authors,
            oldestLine: oldest,
            newestLine: newest,
            lines: parsedLines
        )
    }
}

extension GitRepository {
    /// Line ownership of one file as it stands now, or at an explicit commit `revision`.
    ///
    /// `-w` ignores whitespace-only changes and `-M` follows lines moved within the file,
    /// so a reformatting pass does not make whoever ran it the owner of everything.
    public func blame(path: String, revision: String? = nil) throws -> BlameOwnership {
        let root = try validate()
        var arguments = ["blame", "--line-porcelain", "-w", "-M"]
        if let revision { arguments.append(revision) }
        arguments += ["--", path]
        let output = try GitProcess.capture(arguments: arguments, in: root)
        return BlameParser.parse(output, path: path, revision: revision)
    }

    /// Reads file contents from the working copy (or at `revision`), capping large files safely.
    public func fileContent(path: String, revision: String? = nil, maxBytes: Int = 512_000) throws -> (text: String, isBinary: Bool, truncated: Bool) {
        let root = try validate()
        let rawData: Data
        if let revision {
            rawData = try readBlobBytes(revision: revision, path: path, in: root, maxBytes: maxBytes + 1)
        } else {
            let fileURL = root.appendingPathComponent(path)
            if FileManager.default.isReadableFile(atPath: fileURL.path),
               let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                rawData = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
            } else {
                rawData = try readBlobBytes(revision: "HEAD", path: path, in: root, maxBytes: maxBytes + 1)
            }
        }

        if rawData.prefix(8192).contains(0) {
            return ("", true, false)
        }

        let truncated = rawData.count > maxBytes
        var bounded = truncated ? Data(rawData.prefix(maxBytes)) : rawData
        if truncated {
            // Drop any incomplete multi-byte UTF-8 sequence at the cut boundary.
            while !bounded.isEmpty && (bounded.last! & 0xC0) == 0x80 {
                bounded.removeLast()
            }
            if let last = bounded.last, last >= 0xC0 {
                bounded.removeLast()
            }
        }
        let text = String(decoding: bounded, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        return (text, false, truncated)
    }

    private func readBlobBytes(revision: String, path: String, in root: URL, maxBytes: Int) throws -> Data {
        let box = DataBox()
        try GitProcess.stream(arguments: ["show", "\(revision):\(path)"], in: root) { chunk in
            if box.get().count < maxBytes {
                box.append(chunk)
            }
        }
        return box.get()
    }
}
