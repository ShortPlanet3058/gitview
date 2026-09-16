import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func makeUnit(complexity: Int, lines: ClosedRange<Int> = 1...10) -> CodeUnit {
    CodeUnit(filePath: "A.swift", name: "f", kind: .function, lineRange: lines,
             complexity: complexity, nestingDepth: 0, lineCount: lines.count)
}

private func commit(daysAgo: Double, author: String = "dev") -> Commit {
    Commit(sha: UUID().uuidString, author: author,
           date: now.addingTimeInterval(-daysAgo * 86_400), fileChanges: [])
}

final class RiskModelTests: XCTestCase {
    let model = RiskModel(halfLife: 90 * 86_400)

    // MARK: - Recency decay

    func testCommitMadeNowContributesFullWeight() {
        XCTAssertEqual(model.recency(commits: [commit(daysAgo: 0)], now: now), 1.0, accuracy: 1e-9)
    }

    func testCommitOneHalfLifeOldContributesHalf() {
        XCTAssertEqual(model.recency(commits: [commit(daysAgo: 90)], now: now), 0.5, accuracy: 1e-9)
    }

    func testDecayIsExponential() {
        XCTAssertEqual(model.recency(commits: [commit(daysAgo: 180)], now: now), 0.25, accuracy: 1e-9)
        XCTAssertEqual(model.recency(commits: [commit(daysAgo: 270)], now: now), 0.125, accuracy: 1e-9)
    }

    func testRecencyAccumulatesAcrossCommits() {
        let commits = [commit(daysAgo: 0), commit(daysAgo: 90), commit(daysAgo: 180)]
        XCTAssertEqual(model.recency(commits: commits, now: now), 1.75, accuracy: 1e-9)
    }

    func testLongerHalfLifeGivesOldCommitsMoreWeight() {
        let old = [commit(daysAgo: 730)]
        let short = RiskModel(halfLife: 90 * 86_400).recency(commits: old, now: now)
        let long = RiskModel(halfLife: 730 * 86_400).recency(commits: old, now: now)
        XCTAssertLessThan(short, long)
        XCTAssertEqual(long, 0.5, accuracy: 1e-9)
    }

    // MARK: - Score behaviour

    func testNoCommitsScoresZero() {
        XCTAssertEqual(model.score(unit: makeUnit(complexity: 50), commits: [], now: now), 0)
    }

    func testScoreRisesWithComplexity() {
        let commits = [commit(daysAgo: 10)]
        let low = model.score(unit: makeUnit(complexity: 2), commits: commits, now: now)
        let high = model.score(unit: makeUnit(complexity: 40), commits: commits, now: now)
        XCTAssertGreaterThan(high, low)
    }

    func testScoreRisesWithChurn() {
        let unit = makeUnit(complexity: 10)
        let few = model.score(unit: unit, commits: [commit(daysAgo: 5)], now: now)
        let many = model.score(unit: unit,
                               commits: (0..<10).map { commit(daysAgo: Double($0)) }, now: now)
        XCTAssertGreaterThan(many, few)
    }

    func testRecentChurnOutranksIdenticalOldChurn() {
        let unit = makeUnit(complexity: 10)
        let recent = model.score(unit: unit, commits: (0..<5).map { commit(daysAgo: Double($0)) }, now: now)
        let stale = model.score(unit: unit, commits: (0..<5).map { commit(daysAgo: 900 + Double($0)) }, now: now)
        XCTAssertGreaterThan(recent, stale)
    }

    func testLogDampingStopsOneHugeFunctionDominating() {
        // The reason for log1p on complexity: a 40x more complex function must not be
        // 40x riskier, or a single generated switch statement flattens the distribution.
        let commits = [commit(daysAgo: 10)]
        let small = model.score(unit: makeUnit(complexity: 3), commits: commits, now: now)
        let huge = model.score(unit: makeUnit(complexity: 120), commits: commits, now: now)
        XCTAssertLessThan(huge / small, 4.0, "complexity must be heavily damped")
        XCTAssertGreaterThan(huge / small, 1.0)
    }

    func testLogDampingAppliesToChurnToo() {
        let unit = makeUnit(complexity: 10)
        let few = model.score(unit: unit, commits: (0..<2).map { commit(daysAgo: Double($0)) }, now: now)
        let many = model.score(unit: unit, commits: (0..<60).map { commit(daysAgo: Double($0) / 10) }, now: now)
        XCTAssertLessThan(many / few, 4.0)
    }

    // MARK: - Ranking

    func testRankOrdersByScoreAndSkipsUnitsWithoutHistory() {
        let hot = makeUnit(complexity: 20, lines: 1...10)
        let cold = makeUnit(complexity: 20, lines: 20...30)
        let untouched = makeUnit(complexity: 90, lines: 40...50)

        let commits = [
            Commit(sha: "a", author: "ann", date: now.addingTimeInterval(-86_400), fileChanges: [
                FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])
            ]),
            Commit(sha: "b", author: "bob", date: now.addingTimeInterval(-900 * 86_400), fileChanges: [
                FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 25, newLineCount: 1)])
            ]),
        ]
        let churn = ChurnJoiner.join(units: [hot, cold, untouched], commits: commits)
        let ranked = model.rank(units: [hot, cold, untouched], churn: churn, now: now)

        XCTAssertEqual(ranked.count, 2, "a unit with no history is not ranked")
        XCTAssertEqual(ranked[0].unit.id, hot.id)
        XCTAssertEqual(ranked[0].authorCount, 1)
    }

    func testRankExcludesTypeDeclarations() {
        // Complexity pruning leaves types at ~1 by design, so they carry no signal.
        let type = CodeUnit(filePath: "A.swift", name: "T", kind: .class, lineRange: 1...50,
                            complexity: 1, nestingDepth: 0, lineCount: 50)
        let method = makeUnit(complexity: 10, lines: 10...20)
        let commits = [Commit(sha: "a", author: "ann", date: now, fileChanges: [
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 15, newLineCount: 1)])
        ])]
        let churn = ChurnJoiner.join(units: [type, method], commits: commits)
        let ranked = model.rank(units: [type, method], churn: churn, now: now)
        XCTAssertEqual(ranked.map(\.unit.id), [method.id])
    }

    func testDistinctAuthorsAreCounted() {
        let unit = makeUnit(complexity: 5)
        let commits = [
            Commit(sha: "a", author: "ann", date: now, fileChanges: [
                FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            Commit(sha: "b", author: "ann", date: now, fileChanges: [
                FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 6, newLineCount: 1)])]),
            Commit(sha: "c", author: "bob", date: now, fileChanges: [
                FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 7, newLineCount: 1)])]),
        ]
        let churn = ChurnJoiner.join(units: [unit], commits: commits)
        let ranked = model.rank(units: [unit], churn: churn, now: now)
        XCTAssertEqual(ranked[0].authorCount, 2)
        XCTAssertEqual(ranked[0].commitCount, 3)
    }
}
