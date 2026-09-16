import Foundation

/// A plain-language band for a risk score, so a reader does not need to interpret 3.53.
///
/// Bands are *relative* to the repository — the top few percent of ranked units are
/// "critical" whatever their absolute score — because scores are only comparable within
/// one codebase. To stop a small, quiet repository from always presenting a "critical"
/// unit, anything with too little recent activity is held at `low` regardless of rank.
public enum RiskLevel: Int, Comparable, CaseIterable, Hashable, Sendable {
    case low, elevated, high, critical

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .elevated: return "Elevated"
        case .low: return "Low"
        }
    }

    /// SF Symbol name; a level is always shown with its icon and label, never colour alone.
    public var symbolName: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .elevated: return "eye.fill"
        case .low: return "checkmark.circle.fill"
        }
    }

    /// Share of the ranked list (by rank, most risky first) that each band covers.
    public static let criticalShare = 0.02
    public static let highShare = 0.08
    public static let elevatedShare = 0.20
    /// Minimum recency-weighted churn to be anything other than `low`: a quarter of one
    /// present-day commit, i.e. one commit made within two half-lives.
    public static let activityFloor = 0.25

    /// Assigns a level to every ranked unit. `ranked` must be sorted most risky first.
    public static func assign(to ranked: [RiskedUnit]) -> [UUID: RiskLevel] {
        let active = ranked.filter { $0.recency >= activityFloor && $0.score > 0 }
        let count = active.count
        let criticalCutoff = max(count > 0 ? 1 : 0, Int((Double(count) * criticalShare).rounded()))
        let highCutoff = criticalCutoff + Int((Double(count) * highShare).rounded())
        let elevatedCutoff = highCutoff + Int((Double(count) * elevatedShare).rounded())

        var levels: [UUID: RiskLevel] = [:]
        levels.reserveCapacity(ranked.count)
        for unit in ranked { levels[unit.unit.id] = .low }
        for (index, unit) in active.enumerated() {
            levels[unit.unit.id] = index < criticalCutoff ? .critical
                : index < highCutoff ? .high
                : index < elevatedCutoff ? .elevated
                : .low
        }
        return levels
    }
}

/// Sentences a reader without a background in the metrics can act on.
public struct RiskExplanation: Hashable, Sendable {
    public let headline: String
    public let reasons: [String]

    public init(headline: String, reasons: [String]) {
        self.headline = headline
        self.reasons = reasons
    }

    /// - Parameters:
    ///   - complexityPercentile: fraction of ranked units with lower complexity, 0...1.
    ///   - recentCommits: commits within the recent window.
    ///   - window: the window those commits were counted in, as prose ("the last year").
    ///     It follows the model's half-life so a "Critical" unit is never described as
    ///     unchanged — the two must agree on what "recent" means.
    public static func explain(
        _ unit: RiskedUnit,
        level: RiskLevel,
        complexityPercentile: Double,
        recentCommits: Int,
        window: String = "the last year",
        now: Date
    ) -> RiskExplanation {
        var reasons: [String] = []

        let complexity = unit.unit.complexity
        if complexityPercentile >= 0.95 {
            reasons.append("Among the most complex 5% of code here (complexity \(complexity)).")
        } else if complexityPercentile >= 0.75 {
            reasons.append("More complex than three in four units (complexity \(complexity)).")
        } else if complexityPercentile >= 0.5 {
            reasons.append("Above-average complexity (\(complexity)).")
        } else {
            reasons.append("Fairly simple code (complexity \(complexity)).")
        }

        if recentCommits > 0 {
            let times = recentCommits == 1 ? "once" : "\(recentCommits) times"
            reasons.append("Changed \(times) in \(window).")
        } else if let last = unit.lastTouched {
            reasons.append("Not changed in \(window) — last touched \(relative(last, now: now)).")
        }
        reasons.append(unit.authorCount == 1
                       ? "Only one person has worked on it."
                       : "\(unit.authorCount) different people have worked on it.")
        if let last = unit.lastTouched, recentCommits > 0 {
            reasons.append("Last changed \(relative(last, now: now)).")
        }
        if unit.unit.lineCount >= 100 {
            reasons.append("Long: \(unit.unit.lineCount) lines in one unit.")
        }

        let headline: String
        switch level {
        case .critical: headline = "Needs attention — complex code that keeps changing."
        case .high: headline = "Worth a look — both complex and active."
        case .elevated: headline = "Some risk — keep an eye on it."
        case .low: headline = "Low risk right now."
        }
        return RiskExplanation(headline: headline, reasons: reasons)
    }

    /// Prose for a window of `days`: "the last month", "the last 18 months", "the last 2 years".
    public static func windowLabel(days: Double) -> String {
        switch days {
        case ..<45: return "the last month"
        case ..<330: return "the last \(Int((days / 30).rounded())) months"
        case ..<400: return "the last year"
        case ..<660: return "the last \(Int((days / 30).rounded())) months"
        default:
            let years = Int((days / 365).rounded())
            return years == 1 ? "the last year" : "the last \(years) years"
        }
    }

    /// "today", "3 days ago", "2 months ago", "over a year ago" — coarse on purpose.
    public static func relative(_ date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case ..<14: return "\(days) days ago"
        case ..<60: return "\(days / 7) weeks ago"
        case ..<365: return "\(days / 30) months ago"
        case ..<730: return "over a year ago"
        default: return "\(days / 365) years ago"
        }
    }
}
