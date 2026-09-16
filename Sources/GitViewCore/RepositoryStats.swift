import Foundation

// MARK: - Contributors

public struct Contributor: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let commits: Int
    /// Fraction of all commits, 0...1.
    public let share: Double
    public let firstCommit: Date
    public let lastCommit: Date
    /// Automation rather than a person: excluded from the health check that asks how many
    /// people are active, and marked in the contributor list.
    public let isBot: Bool

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

public enum ContributorStats {
    /// Most commits first; ties broken by name for a stable order.
    public static func compute(commits: [Commit]) -> [Contributor] {
        guard !commits.isEmpty else { return [] }
        struct Acc { var count = 0; var first = Date.distantFuture; var last = Date.distantPast }
        var byAuthor: [String: Acc] = [:]
        for commit in commits {
            var acc = byAuthor[commit.author, default: Acc()]
            acc.count += 1
            acc.first = min(acc.first, commit.date)
            acc.last = max(acc.last, commit.date)
            byAuthor[commit.author] = acc
        }
        let total = Double(commits.count)
        return byAuthor.map { name, acc in
            Contributor(name: name, commits: acc.count, share: Double(acc.count) / total,
                        firstCommit: acc.first, lastCommit: acc.last, isBot: isBotName(name))
        }
        .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
    }

    /// Distinct authors with a commit on or after `since`.
    public static func activeAuthors(commits: [Commit], since: Date, excludingBots: Bool = false) -> Int {
        Set(commits.lazy
            .filter { $0.date >= since && !(excludingBots && isBotName($0.author)) }
            .map(\.author)).count
    }

    /// Recognises the conventional `name[bot]` suffix plus the common CI identities.
    public static func isBotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix("[bot]") { return true }
        return ["dependabot", "renovate", "github-actions", "greenkeeper", "snyk-bot",
                "semantic-release-bot", "codecov"].contains(lower)
    }
}

// MARK: - Activity over time

public struct ActivityBucket: Hashable, Sendable, Identifiable {
    public var id: Date { start }
    public let start: Date
    public let commits: Int
    public let authors: Int
}

public enum ActivitySeries {
    public enum Granularity: Sendable { case week, month }

    /// Commits per bucket between `from` and `to` inclusive, with empty buckets filled in so
    /// a chart shows gaps as gaps rather than skipping them.
    public static func buckets(
        commits: [Commit],
        granularity: Granularity,
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) -> [ActivityBucket] {
        let component: Calendar.Component = granularity == .week ? .weekOfYear : .month
        guard let firstStart = start(of: from, component: component, calendar: calendar),
              let lastStart = start(of: to, component: component, calendar: calendar),
              firstStart <= lastStart else { return [] }

        var counts: [Date: (Int, Set<String>)] = [:]
        for commit in commits where commit.date >= firstStart && commit.date <= to {
            guard let key = start(of: commit.date, component: component, calendar: calendar) else { continue }
            var entry = counts[key, default: (0, [])]
            entry.0 += 1
            entry.1.insert(commit.author)
            counts[key] = entry
        }

        var result: [ActivityBucket] = []
        var cursor = firstStart
        while cursor <= lastStart {
            let entry = counts[cursor]
            result.append(ActivityBucket(start: cursor, commits: entry?.0 ?? 0, authors: entry?.1.count ?? 0))
            guard let next = calendar.date(byAdding: component == .weekOfYear ? .weekOfYear : .month, value: 1, to: cursor)
            else { break }
            cursor = next
        }
        return result
    }

    private static func start(of date: Date, component: Calendar.Component, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: component, for: date)?.start
    }
}

// MARK: - Change frequency

public enum ChangeFrequency {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let changes: Int
    }

    /// Files touched most often since `since`, most changed first.
    public static func topFiles(commits: [Commit], since: Date, limit: Int) -> [Entry] {
        var counts: [String: Int] = [:]
        for commit in commits where commit.date >= since {
            for change in commit.fileChanges { counts[change.path, default: 0] += 1 }
        }
        return counts.map { Entry(path: $0.key, changes: $0.value) }
            .sorted { $0.changes != $1.changes ? $0.changes > $1.changes : $0.path < $1.path }
            .prefix(limit).map { $0 }
    }
}

// MARK: - Health

/// A single number for "how is this repository doing", built from five explained checks.
///
/// This is a heuristic, not a verdict: each item says what was measured and how many of
/// its points it earned, so a reader can disagree with the weighting rather than with a
/// number they cannot inspect.
public struct RepositoryHealth: Hashable, Sendable {
    public enum Status: Hashable, Sendable { case good, warning, bad }

    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let status: Status
        public let points: Int
        public let maxPoints: Int
    }

    /// A function at or above this many decision points counts as complex. Ten, not twenty:
    /// measured across swift-nio, 3674 of 5620 functions have complexity 1 and only 16
    /// reach 20, so a threshold of 20 put every repository under 1% and awarded full marks
    /// unconditionally. At 10 the check actually discriminates (swift-nio 4.4%,
    /// GitView 10.1% of recent changes).
    public static let complexThreshold = 10

    /// Health is always assessed over this window, independent of the risk model's
    /// half-life — tuning a ranking parameter must not move the repository's health score.
    public static let assessmentWindow: TimeInterval = 730 * 86_400

    public struct Inputs: Sendable {
        public var lastCommit: Date?
        /// Distinct human authors in the last 90 days.
        public var activeAuthors: Int
        /// Local branches other than the default that are unmerged and older than 90 days.
        public var staleLocalBranches: Int
        /// Local branches in total. One means there is nothing to judge.
        public var localBranches: Int
        /// Stale branches that exist only on the remote. Reported, never scored: they are
        /// other people's pull requests, not this checkout's hygiene.
        public var staleRemoteBranches: Int
        public var largeFiles: Int
        /// Share of recent function-touching commits that landed in a complex function.
        /// Churn-weighted rather than counted per function, so one hot complex function
        /// registers more than a complex one nobody touches. Nil when no code was analysed.
        public var complexChurnShare: Double?
        public var complexFunctionsChanged: Int
        public var now: Date

        public init(lastCommit: Date?, activeAuthors: Int, staleLocalBranches: Int, localBranches: Int,
                    staleRemoteBranches: Int, largeFiles: Int, complexChurnShare: Double?,
                    complexFunctionsChanged: Int, now: Date) {
            self.lastCommit = lastCommit; self.activeAuthors = activeAuthors
            self.staleLocalBranches = staleLocalBranches; self.localBranches = localBranches
            self.staleRemoteBranches = staleRemoteBranches; self.largeFiles = largeFiles
            self.complexChurnShare = complexChurnShare
            self.complexFunctionsChanged = complexFunctionsChanged; self.now = now
        }
    }

    public let score: Int
    public let items: [Item]

    public var label: String {
        switch score {
        case 80...: return "Good"
        case 60...: return "Fair"
        default: return "Needs attention"
        }
    }

    public var summary: String {
        switch score {
        case 80...: return "Overall, this repository looks healthy."
        case 60...: return "Mostly fine, with a few things worth a look."
        default: return "Several signs this repository needs care."
        }
    }

    public static func assess(_ inputs: Inputs) -> RepositoryHealth {
        var items: [Item] = []

        // Recent activity — 25
        let days = inputs.lastCommit.map { Int(inputs.now.timeIntervalSince($0) / 86_400) }
        let activityPoints: Int
        switch days {
        case .some(...7): activityPoints = 25
        case .some(...30): activityPoints = 20
        case .some(...90): activityPoints = 12
        case .some(...365): activityPoints = 5
        default: activityPoints = 0
        }
        items.append(Item(
            title: "Recent activity",
            detail: inputs.lastCommit.map { "Last commit \(RiskExplanation.relative($0, now: inputs.now))" } ?? "No commits",
            status: activityPoints >= 20 ? .good : activityPoints >= 5 ? .warning : .bad,
            points: activityPoints, maxPoints: 25))

        // Active contributors — 20
        let contributorPoints: Int
        switch inputs.activeAuthors {
        case 5...: contributorPoints = 20
        case 3...4: contributorPoints = 15
        case 2: contributorPoints = 10
        case 1: contributorPoints = 5
        default: contributorPoints = 0
        }
        items.append(Item(
            title: "Active contributors",
            detail: inputs.activeAuthors == 1 ? "1 person in the last 90 days"
                                              : "\(inputs.activeAuthors) people in the last 90 days",
            status: contributorPoints >= 15 ? .good : contributorPoints >= 5 ? .warning : .bad,
            points: contributorPoints, maxPoints: 20))

        // Branch hygiene — 15, local branches only
        // Kept short: these read in a half-width card beside their title.
        let remoteNote = inputs.staleRemoteBranches > 0 ? " · \(inputs.staleRemoteBranches) stale on origin" : ""
        let branchPoints: Int
        let branchTitle: String
        let branchDetail: String
        if inputs.localBranches <= 1 {
            branchPoints = 15
            branchTitle = "Clean branch structure"
            branchDetail = "Default branch only" + remoteNote
        } else {
            switch inputs.staleLocalBranches {
            case 0: branchPoints = 15
            case 1...2: branchPoints = 10
            case 3...5: branchPoints = 5
            default: branchPoints = 0
            }
            branchTitle = inputs.staleLocalBranches == 0 ? "Clean branch structure" : "Stale branches"
            branchDetail = inputs.staleLocalBranches == 0
                ? "\(inputs.localBranches) local branches, none stale" + remoteNote
                : "\(inputs.staleLocalBranches) local unmerged for 90+ days" + remoteNote
        }
        items.append(Item(title: branchTitle, detail: branchDetail,
                          status: branchPoints >= 10 ? .good : branchPoints >= 5 ? .warning : .bad,
                          points: branchPoints, maxPoints: 15))

        // Large files — 15
        let largePoints = inputs.largeFiles == 0 ? 15 : inputs.largeFiles <= 2 ? 8 : 0
        items.append(Item(
            title: inputs.largeFiles == 0 ? "No large files" : "Some large files",
            detail: inputs.largeFiles == 0 ? "Nothing over 10 MB tracked"
                                           : "\(inputs.largeFiles) file\(inputs.largeFiles == 1 ? "" : "s") over 10 MB",
            status: largePoints == 15 ? .good : largePoints > 0 ? .warning : .bad,
            points: largePoints, maxPoints: 15))

        // Complex code under change — 25
        let complexPoints: Int
        let complexDetail: String
        if let share = inputs.complexChurnShare {
            switch share {
            case ..<0.03: complexPoints = 25
            case ..<0.06: complexPoints = 18
            case ..<0.12: complexPoints = 10
            default: complexPoints = 4
            }
            complexDetail = inputs.complexFunctionsChanged == 0
                ? "No complex function changed recently"
                : "\(share.healthPercent) of recent changes hit complex code"
        } else {
            complexPoints = 25
            complexDetail = "No code analysed"
        }
        items.append(Item(
            title: "Complex code under change",
            detail: complexDetail,
            status: complexPoints >= 18 ? .good : complexPoints >= 10 ? .warning : .bad,
            points: complexPoints, maxPoints: 25))

        return RepositoryHealth(score: items.reduce(0) { $0 + $1.points }, items: items)
    }
}

extension Double {
    /// "4%" normally, "0.3%" below one percent so a small share does not read as nothing.
    var healthPercent: String {
        let percent = self * 100
        if percent > 0 && percent < 1 { return String(format: "%.1f%%", percent) }
        return "\(Int(percent.rounded()))%"
    }
}
