import XCTest
@testable import GitViewGit
import GitViewCore

/// Exercised against a real repository in a temporary directory. Write operations cannot be
/// honestly tested against captured fixtures: the thing worth checking is that the
/// repository afterwards is in the state we claimed it would be.
final class GitWriterTests: XCTestCase {
    private var root: URL!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = GitRepository(url: root)

        try run(["init", "-q", "-b", "main"])
        try run(["config", "user.name", "Test User"])
        try run(["config", "user.email", "test@example.com"])
        try write("tracked.txt", "original\n")
        try write("other.txt", "other\n")
        try run(["add", "--all"])
        try run(["commit", "-qm", "initial"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        try GitProcess.capture(arguments: arguments, in: root)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func state() throws -> WorkingState { try repository.workingState() }

    // MARK: - Reversible

    func testStageAndUnstageAreInverses() throws {
        try write("tracked.txt", "changed\n")
        XCTAssertEqual(try state().unstaged.map(\.path), ["tracked.txt"])

        try repository.stage(paths: ["tracked.txt"])
        var now = try state()
        XCTAssertEqual(now.staged.map(\.path), ["tracked.txt"])
        XCTAssertTrue(now.unstaged.isEmpty)

        try repository.unstage(paths: ["tracked.txt"])
        now = try state()
        XCTAssertTrue(now.staged.isEmpty)
        XCTAssertEqual(now.unstaged.map(\.path), ["tracked.txt"])
        XCTAssertEqual(read("tracked.txt"), "changed\n", "unstaging must not touch the file")
    }

    func testStageAllIncludesUntracked() throws {
        try write("brand-new.txt", "new\n")
        try repository.stageAll()
        XCTAssertEqual(try state().staged.map(\.path), ["brand-new.txt"])
    }

    func testCommitCreatesACommitAndClearsTheIndex() throws {
        try write("tracked.txt", "committed\n")
        try repository.stage(paths: ["tracked.txt"])
        let before = try repository.headSHA()

        let sha = try repository.commit(subject: "Change the file", body: "With a longer explanation.")
        XCTAssertNotEqual(sha, before)
        XCTAssertTrue(try state().isClean)

        let subject = try run(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try run(["log", "-1", "--format=%b"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(subject, "Change the file")
        XCTAssertEqual(body, "With a longer explanation.")
    }

    func testCommitRefusesAnEmptyMessage() throws {
        try write("tracked.txt", "x\n")
        try repository.stage(paths: ["tracked.txt"])
        XCTAssertThrowsError(try repository.commit(subject: "   ")) { error in
            XCTAssertTrue("\(error)".contains("needs a message"))
        }
    }

    func testCommitWithNothingStagedFailsRatherThanCreatingAnEmptyCommit() throws {
        let before = try repository.headSHA()
        XCTAssertThrowsError(try repository.commit(subject: "Nothing here"))
        XCTAssertEqual(try repository.headSHA(), before)
    }

    func testStashRoundTrip() throws {
        try write("tracked.txt", "stashed content\n")
        try repository.stashPush(message: "wip", includeUntracked: false)

        XCTAssertTrue(try state().isClean, "the change is set aside")
        XCTAssertEqual(read("tracked.txt"), "original\n")
        XCTAssertEqual(try state().stashes.count, 1)
        XCTAssertTrue(try XCTUnwrap(state().stashes.first).message.contains("wip"))

        try repository.stashApply("stash@{0}", removing: true)
        XCTAssertEqual(read("tracked.txt"), "stashed content\n", "the work comes back")
        XCTAssertTrue(try state().stashes.isEmpty, "pop removes the entry")
    }

    func testStashApplyKeepsTheEntry() throws {
        try write("tracked.txt", "x\n")
        try repository.stashPush(message: "keep me", includeUntracked: false)
        try repository.stashApply("stash@{0}", removing: false)
        XCTAssertEqual(try state().stashes.count, 1, "apply is non-destructive")
    }

    func testStashCanIncludeUntrackedFiles() throws {
        try write("untracked.txt", "new\n")
        try repository.stashPush(message: "with untracked", includeUntracked: true)
        XCTAssertNil(read("untracked.txt"), "it was taken with the stash")
        try repository.stashApply("stash@{0}", removing: true)
        XCTAssertEqual(read("untracked.txt"), "new\n", "and comes back")
    }

    // MARK: - Destructive

    func testDiscardRestoresTheCommittedContents() throws {
        try write("tracked.txt", "unwanted\n")
        try repository.discardChanges(paths: ["tracked.txt"])
        XCTAssertEqual(read("tracked.txt"), "original\n")
        XCTAssertTrue(try state().isClean)
    }

    func testDiscardLeavesOtherFilesAlone() throws {
        try write("tracked.txt", "a\n")
        try write("other.txt", "b\n")
        try repository.discardChanges(paths: ["tracked.txt"])
        XCTAssertEqual(read("tracked.txt"), "original\n")
        XCTAssertEqual(read("other.txt"), "b\n", "only the named path is touched")
    }

    func testDeleteUntrackedRemovesOnlyWhatWasNamed() throws {
        try write("junk.txt", "junk\n")
        try write("keep.txt", "keep\n")
        try repository.deleteUntracked(paths: ["junk.txt"])
        XCTAssertNil(read("junk.txt"))
        XCTAssertEqual(read("keep.txt"), "keep\n")
        XCTAssertEqual(read("tracked.txt"), "original\n", "tracked files are never touched by this")
    }

    func testStashDrop() throws {
        try write("tracked.txt", "x\n")
        try repository.stashPush(message: "doomed", includeUntracked: false)
        try repository.stashDrop("stash@{0}")
        XCTAssertTrue(try state().stashes.isEmpty)
    }

    func testEmptyPathListsAreNoOps() throws {
        try write("tracked.txt", "changed\n")
        XCTAssertNoThrow(try repository.stage(paths: []))
        XCTAssertNoThrow(try repository.discardChanges(paths: []))
        XCTAssertNoThrow(try repository.deleteUntracked(paths: []))
        XCTAssertEqual(read("tracked.txt"), "changed\n", "nothing happened")
    }

    // MARK: - Push, against a local bare remote

    func testPushPlanAndPush() throws {
        let remote = root.appendingPathComponent("../remote-\(UUID().uuidString).git").standardized
        try GitProcess.capture(arguments: ["init", "--bare", "-q", remote.path], in: root)
        defer { try? FileManager.default.removeItem(at: remote) }
        try run(["remote", "add", "origin", remote.path])

        let plan = try XCTUnwrap(repository.pushPlan())
        XCTAssertEqual(plan.branch, "main")
        XCTAssertEqual(plan.remote, "origin")
        XCTAssertFalse(plan.hasUpstream, "nothing tracked yet")
        XCTAssertEqual(plan.commits.count, 1, "the initial commit is unpushed")

        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        let after = try XCTUnwrap(repository.pushPlan())
        XCTAssertTrue(after.hasUpstream)
        XCTAssertTrue(after.isEmpty, "nothing left to push")
        XCTAssertEqual(try state().ahead, 0)
    }

    func testPushPlanCountsOnlyUnpushedCommits() throws {
        let remote = root.appendingPathComponent("../remote-\(UUID().uuidString).git").standardized
        try GitProcess.capture(arguments: ["init", "--bare", "-q", remote.path], in: root)
        defer { try? FileManager.default.removeItem(at: remote) }
        try run(["remote", "add", "origin", remote.path])
        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        try write("tracked.txt", "more\n")
        try repository.stage(paths: ["tracked.txt"])
        _ = try repository.commit(subject: "Second")

        let plan = try XCTUnwrap(repository.pushPlan())
        XCTAssertEqual(plan.commits.map(\.subject), ["Second"])
    }

    func testFailuresCarryGitsOwnMessage() throws {
        XCTAssertThrowsError(try repository.stashApply("stash@{99}", removing: false)) { error in
            let text = "\(error)"
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.lowercased().contains("stash") || text.lowercased().contains("log"),
                          "got: \(text)")
        }
    }
}
