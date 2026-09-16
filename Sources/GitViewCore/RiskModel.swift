import Foundation

/// Scores a unit by combining how complex it is with how recently and often it changes.
///
/// Both factors go through `log1p` so one enormous function cannot flatten the
/// distribution: without it, a 500-branch switch would outrank everything regardless of
/// whether anyone ever touches it.
public struct RiskModel: Sendable {
    /// How fast a commit's contribution decays. A commit one half-life old counts half as
    /// much as one made today.
    ///
    /// Stored rather than a constant because it becomes a UI slider.
    ///
    /// The default is 365 days, not the 90 the spec proposed. Measured on swift-nio, a
    /// 90-day window contains at most *two* commits for any single function (zero units
    /// reach five), so `recency` collapses to a three-valued tiebreaker and change
    /// frequency — the entire point of the tool — drops out: correlation between score and
    /// commit count is 0.095, and the twenty most-changed functions rank at a median
    /// position of 1782.
    ///
    /// This is the trade-off, measured rather than assumed:
    ///
    ///     half-life   attribution precision   corr(score, commit count)
    ///           90d                     82%                      0.095
    ///          180d                     85%                      0.212
    ///          365d                     78%                      0.379
    ///          730d                     64%                      0.540
    ///         1825d                     52%                      0.668
    ///
    /// Longer windows recover the frequency signal but decay into the region where line
    /// drift makes attribution unreliable (step 3). 365d keeps precision near its peak
    /// while restoring four times the frequency signal.
    public var halfLife: TimeInterval = 365 * 86_400

    public init(halfLife: TimeInterval = 365 * 86_400) {
        self.halfLife = halfLife
    }

    /// Sum of exponentially decayed commit weights. A commit made now contributes 1.0.
    public func recency(commits: [Commit], now: Date) -> Double {
        commits.reduce(0.0) { sum, commit in
            sum + pow(0.5, now.timeIntervalSince(commit.date) / halfLife)
        }
    }

    public func score(unit: CodeUnit, commits: [Commit], now: Date) -> Double {
        log1p(Double(unit.complexity)) * log1p(recency(commits: commits, now: now))
    }
}

/// A unit with its computed risk and the history behind it.
public struct RiskedUnit: Sendable {
    public let unit: CodeUnit
    public let score: Double
    public let recency: Double
    public let commitCount: Int
    public let authorCount: Int
    public let lastTouched: Date?

    public init(unit: CodeUnit, score: Double, recency: Double,
                commitCount: Int, authorCount: Int, lastTouched: Date?) {
        self.unit = unit
        self.score = score
        self.recency = recency
        self.commitCount = commitCount
        self.authorCount = authorCount
        self.lastTouched = lastTouched
    }
}

extension RiskModel {
    /// Ranks every unit that has history, most risky first.
    ///
    /// Type declarations are excluded: complexity pruning leaves them at ~1 by design, so
    /// they carry no signal, and including them would just dilute the table.
    public func rank(units: [CodeUnit], churn: ChurnIndex, now: Date) -> [RiskedUnit] {
        units.compactMap { unit -> RiskedUnit? in
            guard unit.kind != .class else { return nil }
            let commits = churn.commits(for: unit)
            guard !commits.isEmpty else { return nil }
            return RiskedUnit(
                unit: unit,
                score: score(unit: unit, commits: commits, now: now),
                recency: recency(commits: commits, now: now),
                commitCount: commits.count,
                authorCount: Set(commits.map(\.author)).count,
                lastTouched: commits.map(\.date).max()
            )
        }
        .sorted { $0.score > $1.score }
    }
}
