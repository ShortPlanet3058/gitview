import Foundation
import GitViewCore

/// Flattened view of a `RiskedUnit`.
///
/// Flat because `Table` sorts through `KeyPathComparator`, and comparators over nested
/// key paths make every column declaration noisier for no benefit.
struct RiskRow: Identifiable, Hashable {
    let id: UUID
    let name: String
    let filePath: String
    let fileName: String
    let kind: CodeUnit.Kind
    let lineRange: ClosedRange<Int>
    let score: Double
    let complexity: Int
    let nestingDepth: Int
    let lineCount: Int
    let recency: Double
    let commitCount: Int
    let authorCount: Int
    let lastTouched: Date?
    /// Commits within the last year — what a reader means by "changes often".
    let recentCommits: Int
    let level: RiskLevel
    let explanation: RiskExplanation

    init(_ risked: RiskedUnit, level: RiskLevel, recentCommits: Int, complexityPercentile: Double,
         window: String, now: Date) {
        let unit = risked.unit
        self.id = unit.id
        self.name = unit.name
        self.filePath = unit.filePath
        self.fileName = String(unit.filePath.split(separator: "/").last ?? "")
        self.kind = unit.kind
        self.lineRange = unit.lineRange
        self.score = risked.score
        self.complexity = unit.complexity
        self.nestingDepth = unit.nestingDepth
        self.lineCount = unit.lineCount
        self.recency = risked.recency
        self.commitCount = risked.commitCount
        self.authorCount = risked.authorCount
        self.lastTouched = risked.lastTouched
        self.recentCommits = recentCommits
        self.level = level
        self.explanation = RiskExplanation.explain(risked, level: level,
                                                   complexityPercentile: complexityPercentile,
                                                   recentCommits: recentCommits, window: window, now: now)
    }

    var directory: String { CouplingAnalyzer.directory(of: filePath) }

    var location: String { "\(filePath):\(lineRange.lowerBound)" }
    /// Sorts undated rows last regardless of direction, rather than to 1970.
    var lastTouchedSortKey: Date { lastTouched ?? .distantPast }
}


/// Flattened `CouplingPair` with both unit names resolved.
struct CouplingRow: Identifiable, Hashable {
    let id: String
    let pair: CouplingPair
    let nameA: String
    let locationA: String
    let nameB: String
    let locationB: String
    /// Name of whichever unit changes less often — the one `strength` is relative to.
    let anchorName: String
    let anchorCommits: Int

    var sharedCommits: Int { pair.sharedCommits }
    var strength: Double { pair.strength }
    var weight: Double { pair.weight }
    var lastShared: Date { pair.lastShared }
    var crossDirectory: Bool { pair.crossDirectory }

    /// "Changed together 4 times — every time Server.run changed."
    var sentence: String {
        let times = sharedCommits == 1 ? "once" : "\(sharedCommits) times"
        let share: String
        if strength >= 0.99 { share = "every time \(anchorName) changed" }
        else { share = "\(Int((strength * 100).rounded()))% of \(anchorName)'s changes" }
        return "Changed together \(times) — \(share)."
    }
}
