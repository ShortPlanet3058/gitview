import XCTest
@testable import GitViewGit

final class ReflogTests: XCTestCase {
    func testReflogParserSplitsActionMessageAndTimestamp() {
        let output = [
            "1111111111111111111111111111111111111111\u{1F}HEAD@{0}\u{1F}commit: Fix sidebar alignment\u{1F}2026-11-23T10:15:00+01:00",
            "2222222222222222222222222222222222222222\u{1F}HEAD@{1}\u{1F}checkout: moving from main to feat/ui\u{1F}2026-11-23T09:00:00Z",
            "3333333333333333333333333333333333333333\u{1F}HEAD@{2}\u{1F}reset: moving to HEAD~1\u{1F}2026-11-23T08:30:00Z",
        ].joined(separator: "\n")

        let entries = ReflogParser.parse(output)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].selector, "HEAD@{0}")
        XCTAssertEqual(entries[0].shortSHA, "1111111")
        XCTAssertEqual(entries[0].action, "commit")
        XCTAssertEqual(entries[0].message, "Fix sidebar alignment")
        XCTAssertEqual(entries[1].action, "checkout")
        XCTAssertEqual(entries[2].action, "reset")
    }

    func testRepositoryReflogReadsCommitsFromTempRepo() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-reflog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRoot)

        let repo = GitRepository(url: tempRoot)
        try "one\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        let firstSHA = try repo.commit(subject: "First")

        try "two\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        let secondSHA = try repo.commit(subject: "Second")

        try repo.resetSoft(to: firstSHA)
        XCTAssertEqual(try repo.headSHA(), firstSHA)

        let entries = try repo.reflog(limit: 20)
        XCTAssertGreaterThanOrEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.action, "reset")
        XCTAssertTrue(entries.contains(where: { $0.sha == secondSHA && $0.action == "commit" }))
    }
}
