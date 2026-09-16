import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func risked(_ score: Double, recency: Double = 1, complexity: Int = 5,
                    commits: Int = 3, authors: Int = 2, lines: Int = 20, daysAgo: Double = 10) -> RiskedUnit {
    let unit = CodeUnit(filePath: "A.swift", name: "f", kind: .function, lineRange: 1...lines,
                        complexity: complexity, nestingDepth: 0, lineCount: lines)
    return RiskedUnit(unit: unit, score: score, recency: recency, commitCount: commits,
                      authorCount: authors, lastTouched: now.addingTimeInterval(-daysAgo * 86_400))
}

final class RiskLevelTests: XCTestCase {
    func testBandsFollowRankShares() {
        let ranked = (0..<100).map { risked(Double(100 - $0)) }
        let levels = RiskLevel.assign(to: ranked)
        let counts = Dictionary(grouping: levels.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts[.critical], 2)
        XCTAssertEqual(counts[.high], 8)
        XCTAssertEqual(counts[.elevated], 20)
        XCTAssertEqual(counts[.low], 70)
    }

    func testAtLeastOneCriticalWhenAnythingIsActive() {
        let levels = RiskLevel.assign(to: [risked(1.0), risked(0.5), risked(0.2)])
        XCTAssertEqual(levels.values.filter { $0 == .critical }.count, 1)
    }

    func testInactiveUnitsStayLowRegardlessOfRank() {
        // Highest score but essentially no recent activity: a stale hotspot is not "critical".
        let stale = risked(9.0, recency: 0.01)
        let active = risked(1.0, recency: 1.0)
        let levels = RiskLevel.assign(to: [stale, active])
        XCTAssertEqual(levels[stale.unit.id], .low)
        XCTAssertEqual(levels[active.unit.id], .critical)
    }

    func testEmptyInput() {
        XCTAssertTrue(RiskLevel.assign(to: []).isEmpty)
    }

    func testOrdering() {
        XCTAssertLessThan(RiskLevel.low, RiskLevel.critical)
        XCTAssertEqual(RiskLevel.allCases.sorted(), [.low, .elevated, .high, .critical])
    }
}

final class RiskExplanationTests: XCTestCase {
    func testCriticalComplexActiveUnit() {
        let unit = risked(4.0, complexity: 33, commits: 12, authors: 6, lines: 181, daysAgo: 45)
        let explanation = RiskExplanation.explain(unit, level: .critical, complexityPercentile: 0.99,
                                                  recentCommits: 5, now: now)
        XCTAssertTrue(explanation.headline.hasPrefix("Needs attention"))
        XCTAssertEqual(explanation.reasons, [
            "Among the most complex 5% of code here (complexity 33).",
            "Changed 5 times in the last year.",
            "6 different people have worked on it.",
            "Last changed 6 weeks ago.",
            "Long: 181 lines in one unit.",
        ])
    }

    func testQuietSimpleUnit() {
        let unit = risked(0.1, complexity: 2, commits: 1, authors: 1, lines: 9, daysAgo: 500)
        let explanation = RiskExplanation.explain(unit, level: .low, complexityPercentile: 0.2,
                                                  recentCommits: 0, now: now)
        XCTAssertEqual(explanation.headline, "Low risk right now.")
        XCTAssertEqual(explanation.reasons, [
            "Fairly simple code (complexity 2).",
            "Not changed in the last year — last touched over a year ago.",
            "Only one person has worked on it.",
        ])
    }

    func testWindowFollowsTheModel() {
        let unit = risked(2.0, complexity: 10, commits: 4, authors: 2, lines: 30, daysAgo: 400)
        let explanation = RiskExplanation.explain(unit, level: .high, complexityPercentile: 0.8,
                                                  recentCommits: 3, window: "the last 2 years", now: now)
        XCTAssertEqual(explanation.reasons[1], "Changed 3 times in the last 2 years.")
    }

    func testWindowLabels() {
        XCTAssertEqual(RiskExplanation.windowLabel(days: 30), "the last month")
        XCTAssertEqual(RiskExplanation.windowLabel(days: 180), "the last 6 months")
        XCTAssertEqual(RiskExplanation.windowLabel(days: 365), "the last year")
        XCTAssertEqual(RiskExplanation.windowLabel(days: 540), "the last 18 months")
        XCTAssertEqual(RiskExplanation.windowLabel(days: 730), "the last 2 years")
        XCTAssertEqual(RiskExplanation.windowLabel(days: 2190), "the last 6 years")
    }

    func testRelativeDates() {
        func rel(_ days: Double) -> String {
            RiskExplanation.relative(now.addingTimeInterval(-days * 86_400), now: now)
        }
        XCTAssertEqual(rel(0), "today")
        XCTAssertEqual(rel(1), "yesterday")
        XCTAssertEqual(rel(5), "5 days ago")
        XCTAssertEqual(rel(21), "3 weeks ago")
        XCTAssertEqual(rel(100), "3 months ago")
        XCTAssertEqual(rel(400), "over a year ago")
        XCTAssertEqual(rel(1100), "3 years ago")
    }
}
