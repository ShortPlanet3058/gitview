import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func commit(_ sha: String, _ author: String, daysAgo: Double, files: [String] = ["a.swift"]) -> Commit {
    Commit(sha: sha, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), subject: "s \(sha)",
           fileChanges: files.map { FileChange(path: $0, oldPath: nil, hunks: [Hunk(newStart: 1, newLineCount: 1)]) })
}

/// Newest first, as git log returns them.
private let history = [
    commit("f", "Ann", daysAgo: 0.5, files: ["app.swift"]),
    commit("e", "Bob", daysAgo: 1, files: ["mine.swift"]),
    commit("d", "Finn", daysAgo: 2, files: ["mine.swift", "app.swift"]),
    commit("c", "Ann", daysAgo: 9, files: ["other.swift"]),
    commit("b", "Finn", daysAgo: 20, files: ["mine.swift"]),
    commit("a", "Ann", daysAgo: 40, files: ["app.swift"]),
]
private let me = Identity(names: ["Finn"])

final class CatchUpBuilderTests: XCTestCase {

    func testCommitsSinceTheRememberedTip() {
        let visit = VisitLog.Visit(headSHA: "d", date: now.addingTimeInterval(-2 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertEqual(catchUp.commits.map(\.sha), ["f", "e"], "everything newer than the tip we saw")
        XCTAssertFalse(catchUp.isFirstVisit)
        XCTAssertEqual(catchUp.authorCount, 2)
        XCTAssertEqual(catchUp.fileCount, 2)
    }

    func testNothingNewWhenTheTipIsUnchanged() {
        let visit = VisitLog.Visit(headSHA: "f", date: now)
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertTrue(catchUp.isEmpty)
        XCTAssertEqual(catchUp.headline(now: now), "Nothing new since you were last here")
    }

    /// After a rebase or force-push the remembered commit no longer exists. Falling back to
    /// the date is approximate, but it must never re-show commits already seen.
    func testFallsBackToDateWhenTheRememberedTipIsGone() {
        let visit = VisitLog.Visit(headSHA: "rewritten-away", date: now.addingTimeInterval(-1.5 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertEqual(catchUp.commits.map(\.sha), ["f", "e"])
    }

    func testFirstVisitShowsARecentWindow() {
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: nil, identity: me, now: now)
        XCTAssertTrue(catchUp.isFirstVisit)
        XCTAssertEqual(catchUp.commits.map(\.sha), ["f", "e", "d"], "the last 7 days")
        XCTAssertEqual(catchUp.headline(now: now), "3 new commits in the last 7 days")
        XCTAssertNil(catchUp.since)
    }

    func testYourOwnCommitsAreSeparated() {
        let visit = VisitLog.Visit(headSHA: "c", date: now.addingTimeInterval(-9 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertEqual(catchUp.commits.map(\.sha), ["f", "e", "d"])
        XCTAssertEqual(catchUp.yours.map(\.sha), ["d"])
    }

    /// The point of knowing who you are: other people's work landing in files you maintain.
    func testCommitsTouchingYourCode() {
        let visit = VisitLog.Visit(headSHA: "d", date: now.addingTimeInterval(-2 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        // Bob's "e" touched mine.swift, which Finn has worked on. Ann's "f" touched app.swift,
        // which Finn also touched in "d" — so both qualify, and neither is Finn's own.
        XCTAssertEqual(Set(catchUp.touchingYourCode.map(\.sha)), ["e", "f"])
        XCTAssertFalse(catchUp.touchingYourCode.contains { $0.author == "Finn" })
    }

    func testWithoutAnIdentityThePersonalPartsAreEmptyRatherThanWrong() {
        let visit = VisitLog.Visit(headSHA: "c", date: now.addingTimeInterval(-9 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit,
                                           identity: Identity(names: []), now: now)
        XCTAssertFalse(catchUp.commits.isEmpty)
        XCTAssertTrue(catchUp.yours.isEmpty)
        XCTAssertTrue(catchUp.touchingYourCode.isEmpty)
    }

    func testBusiestPaths() {
        let visit = VisitLog.Visit(headSHA: "c", date: now.addingTimeInterval(-9 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertEqual(catchUp.busiestPaths.first?.path, "app.swift")
        XCTAssertEqual(catchUp.busiestPaths.first?.changes, 2)
    }

    func testHeadlineNamesHowLongItHasBeen() {
        let visit = VisitLog.Visit(headSHA: "d", date: now.addingTimeInterval(-2 * 86_400))
        let catchUp = CatchUpBuilder.build(commits: history, lastVisit: visit, identity: me, now: now)
        XCTAssertEqual(catchUp.headline(now: now), "2 new commits since you were last here, 2 days ago")
    }

    /// Coming back after a long absence must not try to render the whole history.
    func testLimitProtectsAgainstAYearAway() {
        let many = (0..<2000).map { commit("c\($0)", "Ann", daysAgo: Double($0) / 24) }
        // The remembered tip is the oldest commit, so all 1999 newer ones are unseen.
        let visit = VisitLog.Visit(headSHA: "c1999", date: now.addingTimeInterval(-90 * 86_400))
        let unlimited = CatchUpBuilder.build(commits: many, lastVisit: visit, identity: me, now: now, limit: 5000)
        XCTAssertEqual(unlimited.commits.count, 1999)

        let capped = CatchUpBuilder.build(commits: many, lastVisit: visit, identity: me, now: now, limit: 500)
        XCTAssertEqual(capped.commits.count, 500)
        XCTAssertEqual(capped.commits.first?.sha, "c0", "keeps the newest, not an arbitrary slice")
    }

    func testEmptyHistory() {
        let catchUp = CatchUpBuilder.build(commits: [], lastVisit: nil, identity: me, now: now)
        XCTAssertTrue(catchUp.isEmpty)
        XCTAssertEqual(catchUp.headline(now: now), "Nothing in the last 7 days")
    }
}

final class VisitLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-visit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        VisitLog.forget(root: root)
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundTrip() {
        XCTAssertNil(VisitLog.lastVisit(to: root))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(VisitLog.record(headSHA: "abc", to: root, at: when))
        let visit = VisitLog.lastVisit(to: root)
        XCTAssertEqual(visit?.headSHA, "abc")
        XCTAssertEqual(visit?.date, when)
    }

    func testRecordingAgainReplaces() {
        VisitLog.record(headSHA: "one", to: root)
        VisitLog.record(headSHA: "two", to: root)
        XCTAssertEqual(VisitLog.lastVisit(to: root)?.headSHA, "two")
    }

    func testSeparatePerRepository() {
        XCTAssertNotEqual(VisitLog.url(for: root), VisitLog.url(for: root.appendingPathComponent("other")))
    }

    func testForget() {
        VisitLog.record(headSHA: "abc", to: root)
        VisitLog.forget(root: root)
        XCTAssertNil(VisitLog.lastVisit(to: root))
    }
}

final class IdentityTests: XCTestCase {
    func testMatchesAnyOfSeveralNames() {
        let identity = Identity(names: ["Finn Vignon", "finn"])
        XCTAssertTrue(identity.wrote(commit("x", "Finn Vignon", daysAgo: 1)))
        XCTAssertTrue(identity.wrote(commit("y", "finn", daysAgo: 1)))
        XCTAssertFalse(identity.wrote(commit("z", "Someone Else", daysAgo: 1)))
    }
}
