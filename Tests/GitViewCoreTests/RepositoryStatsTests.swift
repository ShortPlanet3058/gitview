import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func commit(_ sha: String, _ author: String, daysAgo: Double, files: [String] = []) -> Commit {
    Commit(sha: sha, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), subject: "s",
           fileChanges: files.map { FileChange(path: $0, oldPath: nil, hunks: [Hunk(newStart: 1, newLineCount: 1)]) })
}

final class BotDetectionTests: XCTestCase {
    func testRecognisesBots() {
        for name in ["dependabot[bot]", "github-actions[bot]", "Dependabot", "renovate", "CODECOV"] {
            XCTAssertTrue(ContributorStats.isBotName(name), name)
        }
    }

    func testDoesNotFlagPeople() {
        for name in ["Cory Benfield", "Robot Wrangler", "botto", "Abbot Smith"] {
            XCTAssertFalse(ContributorStats.isBotName(name), name)
        }
    }

    func testActiveAuthorsCanExcludeBots() {
        let commits = [commit("1", "Ann", daysAgo: 1), commit("2", "dependabot[bot]", daysAgo: 2)]
        XCTAssertEqual(ContributorStats.activeAuthors(commits: commits, since: now.addingTimeInterval(-90 * 86_400)), 2)
        XCTAssertEqual(ContributorStats.activeAuthors(commits: commits, since: now.addingTimeInterval(-90 * 86_400),
                                                      excludingBots: true), 1)
    }

    func testContributorCarriesBotFlag() {
        let people = ContributorStats.compute(commits: [commit("1", "Ann", daysAgo: 1),
                                                        commit("2", "dependabot[bot]", daysAgo: 1)])
        XCTAssertEqual(people.first { $0.name == "Ann" }?.isBot, false)
        XCTAssertEqual(people.first { $0.name == "dependabot[bot]" }?.isBot, true)
    }
}

final class ContributorStatsTests: XCTestCase {
    func testCountsSharesAndDates() {
        let commits = [commit("1", "Ann", daysAgo: 1), commit("2", "Bob", daysAgo: 2), commit("3", "Ann", daysAgo: 30)]
        let contributors = ContributorStats.compute(commits: commits)
        XCTAssertEqual(contributors.map(\.name), ["Ann", "Bob"])
        XCTAssertEqual(contributors[0].commits, 2)
        XCTAssertEqual(contributors[0].share, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(contributors[0].firstCommit, now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(contributors[0].lastCommit, now.addingTimeInterval(-1 * 86_400))
        XCTAssertEqual(contributors[0].initials, "A")
        XCTAssertEqual(Contributor(name: "Alex Martin", commits: 1, share: 1, firstCommit: now,
                                   lastCommit: now, isBot: false).initials, "AM")
    }

    func testActiveAuthorsWindow() {
        let commits = [commit("1", "Ann", daysAgo: 10), commit("2", "Bob", daysAgo: 100), commit("3", "Cy", daysAgo: 80)]
        XCTAssertEqual(ContributorStats.activeAuthors(commits: commits, since: now.addingTimeInterval(-90 * 86_400)), 2)
    }

    func testEmpty() { XCTAssertTrue(ContributorStats.compute(commits: []).isEmpty) }
}

final class ActivitySeriesTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testMonthlyBucketsIncludeEmptyMonthsAndCountAuthors() {
        let old = now.addingTimeInterval(-70 * 86_400)
        let commits = [commit("1", "Ann", daysAgo: 0), commit("2", "Bob", daysAgo: 1), commit("3", "Ann", daysAgo: 70)]
        let from = now.addingTimeInterval(-80 * 86_400)
        let buckets = ActivitySeries.buckets(commits: commits, granularity: .month, from: from, to: now, calendar: calendar)

        // One bucket per calendar month touched by the range, derived from the calendar
        // rather than assumed, so the test does not depend on where `now` falls in a month.
        let firstMonth = calendar.dateInterval(of: .month, for: from)!.start
        let lastMonth = calendar.dateInterval(of: .month, for: now)!.start
        let expectedCount = calendar.dateComponents([.month], from: firstMonth, to: lastMonth).month! + 1
        XCTAssertEqual(buckets.count, expectedCount)
        XCTAssertEqual(buckets.first?.start, firstMonth)
        XCTAssertEqual(buckets.last?.start, lastMonth)

        XCTAssertEqual(buckets.last?.commits, 2)
        XCTAssertEqual(buckets.last?.authors, 2)
        let oldMonth = calendar.dateInterval(of: .month, for: old)!.start
        XCTAssertEqual(buckets.first { $0.start == oldMonth }?.commits, 1)
        XCTAssertEqual(buckets.first { $0.start == oldMonth }?.authors, 1)
        let untouched = buckets.filter { $0.start != oldMonth && $0.start != lastMonth }
        XCTAssertFalse(untouched.isEmpty, "the range must contain at least one empty month")
        XCTAssertTrue(untouched.allSatisfy { $0.commits == 0 }, "empty months are present with zero commits")
    }

    func testWeeklyBucketsAreContiguousAndCoverTheRange() {
        let from = now.addingTimeInterval(-27 * 86_400)
        let buckets = ActivitySeries.buckets(commits: [], granularity: .week, from: from, to: now, calendar: calendar)
        XCTAssertTrue((4...5).contains(buckets.count), "27 days touch four or five calendar weeks, got \(buckets.count)")
        XCTAssertLessThanOrEqual(buckets.first!.start, from)
        XCTAssertLessThanOrEqual(buckets.last!.start, now)
        XCTAssertGreaterThan(buckets.last!.start.addingTimeInterval(7 * 86_400), now)
        for (a, b) in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(b.start.timeIntervalSince(a.start), 7 * 86_400, accuracy: 1)
        }
    }
}

final class ChangeFrequencyTests: XCTestCase {
    func testTopFilesRespectsWindowAndLimit() {
        let commits = [
            commit("1", "Ann", daysAgo: 1, files: ["a.swift", "b.swift"]),
            commit("2", "Ann", daysAgo: 2, files: ["a.swift"]),
            commit("3", "Ann", daysAgo: 200, files: ["c.swift", "c.swift"]),
        ]
        let top = ChangeFrequency.topFiles(commits: commits, since: now.addingTimeInterval(-90 * 86_400), limit: 5)
        XCTAssertEqual(top.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(top.first?.changes, 2)
        XCTAssertEqual(ChangeFrequency.topFiles(commits: commits, since: .distantPast, limit: 1).count, 1)
    }
}

final class RepositoryHealthTests: XCTestCase {
    func inputs(lastDays: Double? = 1, authors: Int = 6, staleLocal: Int = 0, local: Int = 4,
                staleRemote: Int = 0, large: Int = 0, share: Double? = 0.01, count: Int = 1) -> RepositoryHealth.Inputs {
        .init(lastCommit: lastDays.map { now.addingTimeInterval(-$0 * 86_400) }, activeAuthors: authors,
              staleLocalBranches: staleLocal, localBranches: local, staleRemoteBranches: staleRemote,
              largeFiles: large, complexChurnShare: share, complexFunctionsChanged: count, now: now)
    }

    func testPerfectRepositoryScoresOneHundred() {
        let health = RepositoryHealth.assess(inputs())
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.label, "Good")
        XCTAssertEqual(health.items.count, 5)
        XCTAssertTrue(health.items.allSatisfy { $0.status == .good })
        XCTAssertEqual(health.items.map(\.maxPoints).reduce(0, +), 100)
    }

    func testAbandonedRepositoryScoresLow() {
        let health = RepositoryHealth.assess(inputs(lastDays: 800, authors: 0, staleLocal: 9, large: 5, share: 0.3, count: 12))
        XCTAssertEqual(health.score, 4)
        XCTAssertEqual(health.label, "Needs attention")
        XCTAssertEqual(health.items[0].status, .bad)
        XCTAssertEqual(health.items[0].detail, "Last commit 2 years ago")
    }

    func testMiddleBandIsFair() {
        // 20 + 10 + 10 + 8 + 18 = 66
        let health = RepositoryHealth.assess(inputs(lastDays: 20, authors: 2, staleLocal: 2, large: 1, share: 0.04))
        XCTAssertEqual(health.score, 66)
        XCTAssertEqual(health.label, "Fair")
    }

    func testNoCodeAnalysedDoesNotPenalise() {
        let health = RepositoryHealth.assess(inputs(share: nil, count: 0))
        XCTAssertEqual(health.items[4].points, 25)
        XCTAssertEqual(health.items[4].detail, "No code analysed")
    }

    func testDetailsReadAsSentences() {
        let health = RepositoryHealth.assess(inputs(staleLocal: 1, local: 7, large: 3, share: 0.08, count: 4))
        XCTAssertEqual(health.items[2].title, "Stale branches")
        XCTAssertEqual(health.items[2].detail, "1 local unmerged for 90+ days")
        XCTAssertEqual(health.items[3].detail, "3 files over 10 MB")
        XCTAssertEqual(health.items[4].detail, "8% of recent changes hit complex code")
    }

    // MARK: - The two checks that were scoring the wrong thing

    func testRemoteOnlyStaleBranchesAreReportedButNotScored() {
        // A clone of a public repository has one local branch and dozens of other people's
        // pull-request branches on the remote. Those must not cost the reader points.
        let health = RepositoryHealth.assess(inputs(local: 1, staleRemote: 41))
        let branch = health.items[2]
        XCTAssertEqual(branch.points, branch.maxPoints)
        XCTAssertEqual(branch.status, .good)
        XCTAssertEqual(branch.detail, "Default branch only · 41 stale on origin")
        XCTAssertEqual(health.score, 100)
    }

    func testLocalStaleBranchesStillCost() {
        let health = RepositoryHealth.assess(inputs(staleLocal: 4, local: 9, staleRemote: 41))
        XCTAssertEqual(health.items[2].points, 5)
        XCTAssertEqual(health.items[2].detail, "4 local unmerged for 90+ days · 41 stale on origin")
    }

    func testComplexChurnCheckDiscriminates() {
        // Measured shares: swift-nio 4.4%, GitView 10.1%. The bands must separate them,
        // which the old "share of changed functions with complexity >= 20" never did —
        // every repository sat under 1% and scored full marks.
        XCTAssertEqual(RepositoryHealth.assess(inputs(share: 0.044)).items[4].points, 18)
        XCTAssertEqual(RepositoryHealth.assess(inputs(share: 0.101)).items[4].points, 10)
        XCTAssertEqual(RepositoryHealth.assess(inputs(share: 0.004)).items[4].points, 25)
        XCTAssertEqual(RepositoryHealth.assess(inputs(share: 0.20)).items[4].points, 4)
    }

    func testSmallSharesKeepAFigure() {
        XCTAssertEqual(RepositoryHealth.assess(inputs(share: 0.003, count: 6)).items[4].detail,
                       "0.3% of recent changes hit complex code")
    }
}
