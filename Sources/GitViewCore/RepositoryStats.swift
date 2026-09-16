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
                        firstCommit: acc.first, lastCommit: acc.last)
        }
        .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
    }

    /// Distinct authors with a commit on or after `since`.
    public static func activeAuthors(commits: [Commit], since: Date) -> Int {
        Set(commits.lazy.filter { $0.date >= since }.map(\.author)).count
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

    public struct Inputs: Sendable {
        public var lastCommit: Date?
        public var activeAuthors: Int          // distinct authors in the last 90 days
        public var staleBranches: Int          // unmerged and older than 90 days
        public var totalBranches: Int
        public var largeFiles: Int             // tracked files >= 10 MB
        /// Among functions changed recently, the share with complexity >= 20. Nil when no
        /// code was analysed.
        public var complexChangedShare: Double?
        public var complexChangedCount: Int
        public var now: Date

        public init(lastCommit: Date?, activeAuthors: Int, staleBranches: Int, totalBranches: Int,
                    largeFiles: Int, complexChangedShare: Double?, complexChangedCount: Int, now: Date) {
            self.lastCommit = lastCommit; self.activeAuthors = activeAuthors
            self.staleBranches = staleBranches; self.totalBranches = totalBranches
            self.largeFiles = largeFiles; self.complexChangedShare = complexChangedShare
            self.complexChangedCount = complexChangedCount; self.now = now
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
            detail: inputs.activeAuthors == 1 ? "1 person in the last 90 days" : "\(inputs.activeAuthors) people in the last 90 days",
            status: contributorPoints >= 15 ? .good : contributorPoints >= 5 ? .warning : .bad,
            points: contributorPoints, maxPoints: 20))

        // Branch hygiene — 15
        let branchPoints: Int
        switch inputs.staleBranches {
        case 0: branchPoints = 15
        case 1...2: branchPoints = 10
        case 3...5: branchPoints = 5
        default: branchPoints = 0
        }
        items.append(Item(
            title: inputs.staleBranches == 0 ? "Clean branch structure" : "Stale branches",
            detail: inputs.staleBranches == 0
                ? "\(inputs.totalBranches) branch\(inputs.totalBranches == 1 ? "" : "es"), none stale"
                : "\(inputs.staleBranches) unmerged for over 90 days",
            status: branchPoints >= 10 ? .good : branchPoints >= 5 ? .warning : .bad,
            points: branchPoints, maxPoints: 15))

        // Large files — 15
        let largePoints = inputs.largeFiles == 0 ? 15 : inputs.largeFiles <= 2 ? 8 : 0
        items.append(Item(
            title: inputs.largeFiles == 0 ? "No large files" : "Some large files",
            detail: inputs.largeFiles == 0 ? "Nothing over 10 MB tracked" : "\(inputs.largeFiles) file\(inputs.largeFiles == 1 ? "" : "s") over 10 MB",
            status: largePoints == 15 ? .good : largePoints > 0 ? .warning : .bad,
            points: largePoints, maxPoints: 15))

        // Complex code under change — 25 (GitView's own signal)
        let complexPoints: Int
        let complexDetail: String
        if let share = inputs.complexChangedShare {
            switch share {
            case ..<0.02: complexPoints = 25
            case ..<0.05: complexPoints = 18
            case ..<0.10: complexPoints = 10
            default: complexPoints = 4
            }
            let percent = Int((share * 100).rounded())
            complexDetail = inputs.complexChangedCount == 0
                ? "No very complex function changed recently"
                : "\(inputs.complexChangedCount) very complex function\(inputs.complexChangedCount == 1 ? "" : "s") changed recently (\(percent)%)"
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
