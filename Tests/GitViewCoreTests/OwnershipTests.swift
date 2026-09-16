import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func commit(_ sha: String, _ author: String, daysAgo: Double,
                    files: [String], renames: [String: String] = [:]) -> Commit {
    Commit(sha: sha, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), subject: sha,
           fileChanges: files.map {
               FileChange(path: $0, oldPath: renames[$0], hunks: [Hunk(newStart: 1, newLineCount: 1)])
           })
}

/// Newest first, as git log returns them.
private let history = [
    commit("h", "Ann", daysAgo: 1, files: ["core.swift"]),
    commit("g", "Bob", daysAgo: 5, files: ["core.swift", "net.swift"]),
    commit("f", "Ann", daysAgo: 20, files: ["core.swift"]),
    commit("e", "Ann", daysAgo: 30, files: ["core.swift"]),
    commit("d", "Gone", daysAgo: 400, files: ["legacy.swift"]),
    commit("c", "Gone", daysAgo: 420, files: ["legacy.swift"]),
    commit("b", "Bob", daysAgo: 500, files: ["net.swift"]),
    commit("a", "Ann", daysAgo: 600, files: ["core.swift"]),
]

final class OwnershipBuilderTests: XCTestCase {
    private var index: OwnershipIndex { OwnershipBuilder.build(commits: history) }

    func testSharesAreCountedAndOrdered() throws {
        let core = try XCTUnwrap(index.ownership(of: "core.swift"))
        XCTAssertEqual(core.totalCommits, 5)
        XCTAssertEqual(core.authors.map(\.name), ["Ann", "Bob"])
        XCTAssertEqual(core.authors[0].commits, 4)
        XCTAssertEqual(core.authors[0].share, 0.8, accuracy: 1e-9)
        XCTAssertEqual(core.primary?.name, "Ann")
        XCTAssertFalse(core.isSoleAuthor)
    }

    func testLastAndFirstChangeUseTheRightEnds() throws {
        let core = try XCTUnwrap(index.ownership(of: "core.swift"))
        XCTAssertEqual(core.lastAuthor, "Ann", "history arrives newest first")
        XCTAssertEqual(core.lastChange, now.addingTimeInterval(-1 * 86_400))
        XCTAssertEqual(core.firstChange, now.addingTimeInterval(-600 * 86_400))
    }

    func testSoleAuthorIsDetected() throws {
        let legacy = try XCTUnwrap(index.ownership(of: "legacy.swift"))
        XCTAssertTrue(legacy.isSoleAuthor)
        XCTAssertEqual(legacy.authors.map(\.name), ["Gone"])
        // net.swift is Bob's alone too — both of its commits are his.
        XCTAssertEqual(index.soleAuthorFileCount, 2)
        XCTAssertTrue(try XCTUnwrap(index.ownership(of: "net.swift")).isSoleAuthor)
    }

    /// The actionable half of the bus-factor question: a file only one person knows matters
    /// once that person has stopped contributing.
    func testKnowledgeRiskNeedsBothSoleAuthorshipAndAbsence() {
        let risks = index.knowledgeRisks(inactiveFor: 180, now: now)
        XCTAssertEqual(risks.map(\.path), ["legacy.swift"], "Gone last committed 400 days ago")

        // With a generous window nobody counts as absent, so nothing is at risk.
        XCTAssertTrue(index.knowledgeRisks(inactiveFor: 1000, now: now).isEmpty)
    }

    func testRecommendationReadsAsAnInstruction() throws {
        let core = try XCTUnwrap(index.ownership(of: "core.swift"))
        XCTAssertEqual(core.recommendation(now: now), "Ask Ann — 4 of 5 changes, last yesterday.")

        let legacy = try XCTUnwrap(index.ownership(of: "legacy.swift"))
        XCTAssertEqual(legacy.recommendation(now: now),
                       "Only Gone has ever changed this — 2 changes, last over a year ago.")
    }

    /// When the person who knows a file best is not the person who touched it last, both
    /// names matter: one to ask, one to tell you what just changed.
    func testRecommendationNamesTheLastTouchWhenItWasSomeoneElse() throws {
        let commits = [
            commit("last", "Bob", daysAgo: 2, files: ["shared.swift"]),
            commit("m3", "Ann", daysAgo: 10, files: ["shared.swift"]),
            commit("m2", "Ann", daysAgo: 11, files: ["shared.swift"]),
            commit("m1", "Ann", daysAgo: 12, files: ["shared.swift"]),
        ]
        let shared = try XCTUnwrap(OwnershipBuilder.build(commits: commits).ownership(of: "shared.swift"))
        XCTAssertEqual(shared.primary?.name, "Ann")
        XCTAssertEqual(shared.lastAuthor, "Bob")
        XCTAssertEqual(shared.recommendation(now: now),
                       "Ask Ann — 3 of 4 changes, last touched by Bob 2 days ago.")
    }

    func testSoleAuthorFileIsStillFineWhileThatPersonIsAround() {
        // Bob owns net.swift alone but committed five days ago, so it is not a risk.
        let risks = index.knowledgeRisks(inactiveFor: 180, now: now).map(\.path)
        XCTAssertFalse(risks.contains("net.swift"))
    }

    func testFilesOwnedByAuthor() {
        XCTAssertEqual(index.filesOwned(by: "Ann").map(\.path), ["core.swift"])
        XCTAssertEqual(index.filesOwned(by: "Gone").map(\.path), ["legacy.swift"])
        XCTAssertTrue(index.filesOwned(by: "Nobody").isEmpty)
    }

    func testDirectoryRollUp() {
        let commits = [
            commit("x", "Ann", daysAgo: 1, files: ["Sources/App/a.swift"]),
            commit("y", "Bob", daysAgo: 2, files: ["Sources/App/b.swift", "Sources/Net/c.swift"]),
            commit("z", "Ann", daysAgo: 3, files: ["Sources/App/b.swift"]),
        ]
        let index = OwnershipBuilder.build(commits: commits)
        let app = index.ownership(ofDirectory: "Sources/App")
        XCTAssertEqual(app.fileCount, 2)
        XCTAssertEqual(app.totalCommits, 3)
        XCTAssertEqual(app.primary?.name, "Ann")

        let everything = index.ownership(ofDirectory: "")
        XCTAssertEqual(everything.fileCount, 3)
    }

    /// A file's history must survive a move, or ownership resets every time someone
    /// reorganises the tree.
    func testRenamesKeepHistoryOnTheCurrentPath() {
        let commits = [
            commit("new", "Bob", daysAgo: 1, files: ["new/path.swift"], renames: ["new/path.swift": "old/path.swift"]),
            commit("old2", "Ann", daysAgo: 10, files: ["old/path.swift"]),
            commit("old1", "Ann", daysAgo: 20, files: ["old/path.swift"]),
        ]
        let index = OwnershipBuilder.build(commits: commits)
        let owned = index.ownership(of: "new/path.swift")
        XCTAssertEqual(owned?.totalCommits, 3)
        XCTAssertEqual(owned?.primary?.name, "Ann", "the person who wrote it, not the one who moved it")
        XCTAssertNil(index.ownership(of: "old/path.swift"), "the old name is not a separate file")
    }

    func testPathsNoLongerPresentAreDropped() {
        let index = OwnershipBuilder.build(commits: history, currentPaths: ["core.swift"])
        XCTAssertNotNil(index.ownership(of: "core.swift"))
        XCTAssertNil(index.ownership(of: "legacy.swift"), "deleted files are not worth asking about")
    }

    func testEmptyHistory() {
        let index = OwnershipBuilder.build(commits: [])
        XCTAssertTrue(index.files.isEmpty)
        XCTAssertEqual(index.soleAuthorFileCount, 0)
        XCTAssertTrue(index.knowledgeRisks(now: now).isEmpty)
    }
}
