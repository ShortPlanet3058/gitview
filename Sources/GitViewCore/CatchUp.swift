import Foundation
import CryptoKit

/// Remembers where each repository was the last time you looked at it.
///
/// Stored in Application Support rather than Caches: unlike the analysis cache this is not
/// reconstructible, and losing it means losing the one thing GitHub cannot tell you —
/// when *you* last looked.
public enum VisitLog {
    public struct Visit: Codable, Hashable, Sendable {
        public let headSHA: String
        public let date: Date
        public init(headSHA: String, date: Date) { self.headSHA = headSHA; self.date = date }
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fr.liriscom.gitview", isDirectory: true)
    }

    static func url(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(name).visit")
    }

    public static func lastVisit(to root: URL) -> Visit? {
        guard let data = try? Data(contentsOf: url(for: root)) else { return nil }
        return try? JSONDecoder().decode(Visit.self, from: data)
    }

    @discardableResult
    public static func record(headSHA: String, to root: URL, at date: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Visit(headSHA: headSHA, date: date))
            try data.write(to: url(for: root), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func forget(root: URL) {
        try? FileManager.default.removeItem(at: url(for: root))
    }
}

/// Who the person using GitView is, so the app can say "your code" and mean it.
///
/// Matched by author name because that is what the log stores, already resolved through
/// .mailmap. Several names are allowed: the same person commits as "Finn Vignon" from one
/// machine and a different spelling from another, and a repository's local git config often
/// differs from the global one.
public struct Identity: Hashable, Sendable {
    public let names: Set<String>
    public init(names: Set<String>) { self.names = names }
    public func wrote(_ commit: Commit) -> Bool { names.contains(commit.author) }
    public var isEmpty: Bool { names.isEmpty }
}

/// What changed since the last visit — the question a repository dashboard should open with.
public struct CatchUp: Sendable {
    /// Commits that are new since the last visit, newest first.
    public let commits: [Commit]
    /// When the last visit was. Nil on a first visit.
    public let since: Date?
    /// True when there was no previous visit, so `commits` is a recent window instead.
    public let isFirstVisit: Bool
    /// Days covered when `isFirstVisit`.
    public let fallbackWindowDays: Int
    /// Commits in this batch written by you.
    public let yours: [Commit]
    /// Commits by other people that touched files you have worked on.
    public let touchingYourCode: [Commit]
    /// Paths changed in this batch, most changed first.
    public let busiestPaths: [(path: String, changes: Int)]

    public var authorCount: Int { Set(commits.map(\.author)).count }
    public var fileCount: Int { Set(commits.flatMap { $0.fileChanges.map(\.path) }).count }
    public var isEmpty: Bool { commits.isEmpty }

    /// "since Tuesday", "since your last visit 3 days ago", "in the last 7 days".
    public func headline(now: Date) -> String {
        guard !commits.isEmpty else {
            return isFirstVisit ? "Nothing in the last \(fallbackWindowDays) days" : "Nothing new since you were last here"
        }
        let count = commits.count == 1 ? "1 new commit" : "\(commits.count.formatted()) new commits"
        if isFirstVisit { return "\(count) in the last \(fallbackWindowDays) days" }
        guard let since else { return count }
        return "\(count) since you were last here, \(RiskExplanation.relative(since, now: now))"
    }
}

public enum CatchUpBuilder {
    /// - Parameters:
    ///   - commits: full history, newest first, as `git log` returns it.
    ///   - lastVisit: the previous visit, if any.
    ///   - identity: who "you" are; pass an empty identity to skip the personal parts.
    public static func build(
        commits: [Commit],
        lastVisit: VisitLog.Visit?,
        identity: Identity,
        now: Date = Date(),
        fallbackWindowDays: Int = 7,
        limit: Int = 500
    ) -> CatchUp {
        let isFirstVisit = lastVisit == nil
        var fresh: [Commit]

        if let lastVisit {
            if let index = commits.firstIndex(where: { $0.sha == lastVisit.headSHA }) {
                // The cheap and exact case: everything before the commit we saw last.
                fresh = Array(commits.prefix(index))
            } else {
                // The tip we remember is gone — a rebase, a force-push, or a different
                // branch checked out. Fall back to the date, which is approximate but never
                // claims commits the person has already seen.
                fresh = commits.filter { $0.date > lastVisit.date }
            }
        } else {
            let cutoff = now.addingTimeInterval(-Double(fallbackWindowDays) * 86_400)
            fresh = commits.filter { $0.date > cutoff }
        }
        if fresh.count > limit { fresh = Array(fresh.prefix(limit)) }

        let yours = identity.isEmpty ? [] : fresh.filter { identity.wrote($0) }

        // Files you have worked on, from the whole history rather than this batch.
        var yourFiles = Set<String>()
        if !identity.isEmpty {
            for commit in commits where identity.wrote(commit) {
                for change in commit.fileChanges { yourFiles.insert(change.path) }
            }
        }
        let touching = yourFiles.isEmpty ? [] : fresh.filter { commit in
            !identity.wrote(commit) && commit.fileChanges.contains { yourFiles.contains($0.path) }
        }

        var counts: [String: Int] = [:]
        for commit in fresh {
            for change in commit.fileChanges { counts[change.path, default: 0] += 1 }
        }
        let busiest = counts.map { (path: $0.key, changes: $0.value) }
            .sorted { $0.changes != $1.changes ? $0.changes > $1.changes : $0.path < $1.path }
            .prefix(8)
            .map { $0 }

        return CatchUp(commits: fresh, since: lastVisit?.date, isFirstVisit: isFirstVisit,
                       fallbackWindowDays: fallbackWindowDays, yours: yours,
                       touchingYourCode: touching, busiestPaths: busiest)
    }
}
