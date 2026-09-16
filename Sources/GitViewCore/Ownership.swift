import Foundation

/// One person's stake in a file, measured in commits that touched it.
///
/// Commits rather than lines: a line count needs `git blame`, which costs about a quarter
/// of a second per file and so cannot be run across a whole repository. For the question
/// this answers — who do I ask about this — "has changed it most often, most recently" is
/// the right signal anyway. `BlameOwnership` gives the exact line-level answer on demand
/// for a single file.
public struct AuthorShare: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let commits: Int
    /// Fraction of this file's commits, 0...1.
    public let share: Double
    public let firstTouched: Date
    public let lastTouched: Date
}

public struct FileOwnership: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Most commits first.
    public let authors: [AuthorShare]
    public let totalCommits: Int
    public let lastAuthor: String
    public let lastChange: Date
    public let firstChange: Date

    public var primary: AuthorShare? { authors.first }
    /// Exactly one person has ever touched this file.
    public var isSoleAuthor: Bool { authors.count == 1 }

    /// "Ask Cory Benfield — 12 of 18 changes, last 3 days ago."
    public func recommendation(now: Date) -> String {
        guard let primary else { return "No recorded history for this file." }
        if isSoleAuthor {
            return "Only \(primary.name) has ever changed this — \(primary.commits) "
                 + "\(primary.commits == 1 ? "change" : "changes"), last \(RiskExplanation.relative(primary.lastTouched, now: now))."
        }
        let recent = lastAuthor == primary.name
            ? "last \(RiskExplanation.relative(lastChange, now: now))"
            : "last touched by \(lastAuthor) \(RiskExplanation.relative(lastChange, now: now))"
        return "Ask \(primary.name) — \(primary.commits) of \(totalCommits) changes, \(recent)."
    }
}

/// Ownership rolled up over a directory.
public struct DirectoryOwnership: Hashable, Sendable {
    public let path: String
    public let authors: [AuthorShare]
    public let fileCount: Int
    public let totalCommits: Int
    public var primary: AuthorShare? { authors.first }
}

/// Who knows what, built once from history.
public struct OwnershipIndex: Sendable {
    public let files: [String: FileOwnership]
    /// The date of the newest commit in the repository, the reference for "inactive".
    public let latestActivity: Date
    /// Last commit date per author anywhere in the repository.
    public let lastActivityByAuthor: [String: Date]

    public func ownership(of path: String) -> FileOwnership? { files[path] }

    /// Files whose path begins with `directory`, rolled up. Pass "" for the whole repository.
    public func ownership(ofDirectory directory: String) -> DirectoryOwnership {
        let prefix = directory.isEmpty ? "" : (directory.hasSuffix("/") ? directory : directory + "/")
        let matching = files.values.filter { prefix.isEmpty || $0.path.hasPrefix(prefix) }
        return Self.rollUp(matching, path: directory)
    }

    /// Files where this person has made the most changes.
    public func filesOwned(by author: String) -> [FileOwnership] {
        files.values.filter { $0.primary?.name == author }
            .sorted { $0.totalCommits != $1.totalCommits ? $0.totalCommits > $1.totalCommits : $0.path < $1.path }
    }

    /// Files only one person has ever touched, where that person has since gone quiet.
    ///
    /// This is the actionable half of the bus-factor question: a file only one person knows
    /// is fine while that person is around, and a problem once they are not.
    public func knowledgeRisks(inactiveFor days: Double = 180, now: Date, limit: Int = 50) -> [FileOwnership] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        return files.values
            .filter { file in
                guard file.isSoleAuthor, let primary = file.primary else { return false }
                return (lastActivityByAuthor[primary.name] ?? .distantPast) < cutoff
            }
            .sorted { $0.totalCommits != $1.totalCommits ? $0.totalCommits > $1.totalCommits : $0.path < $1.path }
            .prefix(limit)
            .map { $0 }
    }

    public var soleAuthorFileCount: Int { files.values.count(where: \.isSoleAuthor) }

    /// Accumulator for the directory roll-up. Declared at file scope because a generic
    /// function cannot nest a type.
    private struct AuthorTotals {
        var commits = 0
        var first = Date.distantFuture
        var last = Date.distantPast
    }

    static func rollUp(_ files: some Collection<FileOwnership>, path: String) -> DirectoryOwnership {
        var byAuthor: [String: AuthorTotals] = [:]
        var total = 0
        for file in files {
            for author in file.authors {
                var totals = byAuthor[author.name, default: AuthorTotals()]
                totals.commits += author.commits
                totals.first = min(totals.first, author.firstTouched)
                totals.last = max(totals.last, author.lastTouched)
                byAuthor[author.name] = totals
                total += author.commits
            }
        }
        let shares = byAuthor
            .map { name, totals in
                AuthorShare(name: name, commits: totals.commits,
                            share: total > 0 ? Double(totals.commits) / Double(total) : 0,
                            firstTouched: totals.first, lastTouched: totals.last)
            }
            .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
        return DirectoryOwnership(path: path, authors: shares, fileCount: files.count, totalCommits: total)
    }
}

public enum OwnershipBuilder {
    /// - Parameters:
    ///   - commits: full history. Renames are followed, so a file's history survives a move.
    ///   - currentPaths: paths that still exist; history for anything else is dropped.
    public static func build(commits: [Commit], currentPaths: Set<String>? = nil) -> OwnershipIndex {
        struct Entry { var commits = 0; var first = Date.distantFuture; var last = Date.distantPast }
        var perFile: [String: [String: Entry]] = [:]
        var fileLast: [String: (author: String, date: Date)] = [:]
        var fileFirst: [String: Date] = [:]
        var authorLast: [String: Date] = [:]
        var latest = Date.distantPast

        // Same rename resolution as the churn join: walk newest to oldest and map each
        // historical path to the name the file has now.
        var currentPath: [String: String] = [:]

        for commit in commits {
            latest = max(latest, commit.date)
            authorLast[commit.author] = max(authorLast[commit.author] ?? .distantPast, commit.date)

            for change in commit.fileChanges {
                let resolved = currentPath[change.path] ?? change.path
                if let oldPath = change.oldPath { currentPath[oldPath] = resolved }
                if let currentPaths, !currentPaths.contains(resolved) { continue }

                var entry = perFile[resolved, default: [:]][commit.author, default: Entry()]
                entry.commits += 1
                entry.first = min(entry.first, commit.date)
                entry.last = max(entry.last, commit.date)
                perFile[resolved, default: [:]][commit.author] = entry

                // Commits arrive newest first, so the first one seen is the latest change.
                if fileLast[resolved] == nil { fileLast[resolved] = (commit.author, commit.date) }
                fileFirst[resolved] = min(fileFirst[resolved] ?? .distantFuture, commit.date)
            }
        }

        var files: [String: FileOwnership] = [:]
        files.reserveCapacity(perFile.count)
        for (path, byAuthor) in perFile {
            let total = byAuthor.values.reduce(0) { $0 + $1.commits }
            let authors = byAuthor
                .map { name, entry in
                    AuthorShare(name: name, commits: entry.commits,
                                share: total > 0 ? Double(entry.commits) / Double(total) : 0,
                                firstTouched: entry.first, lastTouched: entry.last)
                }
                .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
            guard let last = fileLast[path] else { continue }
            files[path] = FileOwnership(path: path, authors: authors, totalCommits: total,
                                        lastAuthor: last.author, lastChange: last.date,
                                        firstChange: fileFirst[path] ?? last.date)
        }
        return OwnershipIndex(files: files, latestActivity: latest, lastActivityByAuthor: authorLast)
    }
}
