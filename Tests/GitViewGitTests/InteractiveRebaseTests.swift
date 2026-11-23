import XCTest
@testable import GitViewGit

final class InteractiveRebaseTests: XCTestCase {
    func testValidationAndSequenceSerialization() {
        XCTAssertNotNil(InteractiveRebaseBuilder.validate(items: []))

        let c1 = RebaseTodoItem(sha: "1111111", shortSHA: "1111111", subject: "First", author: "Alice", action: .pick)
        let c2 = RebaseTodoItem(sha: "2222222", shortSHA: "2222222", subject: "Second", author: "Alice", action: .squash)
        XCTAssertNil(InteractiveRebaseBuilder.validate(items: [c1, c2]))

        var droppedFirst = c1
        droppedFirst.action = .drop
        XCTAssertNotNil(InteractiveRebaseBuilder.validate(items: [droppedFirst, c2]))

        var droppedSecond = c2
        droppedSecond.action = .drop
        XCTAssertNotNil(InteractiveRebaseBuilder.validate(items: [droppedFirst, droppedSecond]))

        var blankReword = c1
        blankReword.action = .reword
        blankReword.newMessage = "   "
        XCTAssertNotNil(InteractiveRebaseBuilder.validate(items: [blankReword]))

        let todo = InteractiveRebaseBuilder.sequenceTodo(from: [c1, c2])
        XCTAssertEqual(todo, "pick 1111111 First\nsquash 2222222 Second\n")
    }

    func testInteractiveRebaseRewordReorderSquashAndDropInTempRepo() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: root)
        try GitProcess.capture(arguments: ["config", "user.name", "Tester"], in: root)
        try GitProcess.capture(arguments: ["config", "user.email", "tester@example.com"], in: root)

        let repo = GitRepository(url: root)

        try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        let baseSHA = try repo.commit(subject: "Base commit")

        try "one\n".write(to: root.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        _ = try repo.commit(subject: "Commit one")

        try "two\n".write(to: root.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        _ = try repo.commit(subject: "Commit two")

        try "three\n".write(to: root.appendingPathComponent("f3.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        _ = try repo.commit(subject: "Commit three")

        try "drop\n".write(to: root.appendingPathComponent("f4.txt"), atomically: true, encoding: .utf8)
        try repo.stageAll()
        _ = try repo.commit(subject: "Commit four")

        var plan = try repo.commitsForInteractiveRebase(onto: baseSHA)
        XCTAssertEqual(plan.map(\.subject), ["Commit one", "Commit two", "Commit three", "Commit four"])

        plan[0].action = .reword
        plan[0].newMessage = "Reworded first commit"
        plan[2].action = .squash
        plan[3].action = .drop

        try repo.interactiveRebase(onto: baseSHA, items: plan)

        let subjectsOutput = try GitProcess.capture(
            arguments: ["log", "--reverse", "--format=%s", "\(baseSHA)..HEAD"],
            in: root
        )
        let resultingSubjects = subjectsOutput
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(resultingSubjects, ["Reworded first commit", "Commit two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("f4.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("f3.txt").path))
    }
}
