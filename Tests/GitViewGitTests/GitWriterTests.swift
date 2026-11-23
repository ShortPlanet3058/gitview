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

    func testStashCanTargetSinglePath() throws {
        try write("tracked.txt", "stashed edit\n")
        try write("other.txt", "keep this edit\n")
        try repository.stashPush(message: "single", includeUntracked: false, paths: ["tracked.txt"])
        XCTAssertEqual(read("tracked.txt"), "original\n")
        XCTAssertEqual(read("other.txt"), "keep this edit\n", "unrelated edits must stay in working tree")
    }

    func testPushPlanReturnsNilWithoutRemotes() throws {
        XCTAssertNil(try repository.pushPlan())
    }

    func testPushPlanPrefersOriginAndExcludesRemoteCommitsOnNewBranch() throws {
        let backup = root.appendingPathComponent("../backup-\(UUID().uuidString).git").standardized
        let origin = root.appendingPathComponent("../origin-\(UUID().uuidString).git").standardized
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", backup.path], in: root)
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", origin.path], in: root)
        defer {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: origin)
        }
        // Alphabetically "backup" precedes "origin", which previously fooled pushPlan.
        try run(["remote", "add", "backup", backup.path])
        try run(["remote", "add", "origin", origin.path])
        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        try run(["checkout", "-q", "-b", "feature"])
        try write("tracked.txt", "feature work\n")
        try repository.stage(paths: ["tracked.txt"])
        _ = try repository.commit(subject: "Feature commit")

        let plan = try XCTUnwrap(repository.pushPlan())
        XCTAssertEqual(plan.remote, "origin")
        XCTAssertEqual(plan.branch, "feature")
        XCTAssertFalse(plan.hasUpstream)
        XCTAssertEqual(plan.commits.map(\.subject), ["Feature commit"])
    }

    func testFailuresCarryGitsOwnMessage() throws {
        XCTAssertThrowsError(try repository.stashApply("stash@{99}", removing: false)) { error in
            let text = "\(error)"
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.lowercased().contains("stash") || text.lowercased().contains("log"),
                          "got: \(text)")
        }
    }

    func testCreateSwitchAndDeleteMergedBranch() throws {
        try repository.createBranch(name: "topic", checkout: true)
        XCTAssertEqual(try state().branch, "topic")

        try repository.checkoutBranch("main", isRemote: false)
        XCTAssertEqual(try state().branch, "main")

        try repository.deleteMergedBranch(name: "topic")
        let branchList = try GitProcess.capture(arguments: ["branch", "--list", "topic"], in: root)
        XCTAssertTrue(branchList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testFetchAndPullFastForwardOnly() throws {
        let remote = root.appendingPathComponent("../remote-sync-\(UUID().uuidString).git").standardized
        let peer = root.appendingPathComponent("../peer-sync-\(UUID().uuidString)").standardized
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", remote.path], in: root)
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: peer)
        }
        try run(["remote", "add", "origin", remote.path])
        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        _ = try GitProcess.capture(arguments: ["clone", "-q", "-b", "main", remote.path, peer.path], in: root)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Peer"], in: peer)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "peer@example.com"], in: peer)
        try "from peer\n".write(to: peer.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "tracked.txt"], in: peer)
        _ = try GitProcess.capture(arguments: ["commit", "-q", "-m", "Peer commit"], in: peer)
        _ = try GitProcess.capture(arguments: ["push", "-q", "origin", "HEAD:main"], in: peer)

        try repository.fetch(prune: true)
        XCTAssertEqual(try state().behind, 1)

        try repository.pullFastForwardOnly()
        XCTAssertEqual(try state().behind, 0)
        XCTAssertEqual(read("tracked.txt"), "from peer\n")
    }

    func testApplyPatchSingleHunkStageUnstageAndDiscard() throws {
        let original = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write("multi.txt", original)
        try repository.stage(paths: ["multi.txt"])
        _ = try repository.commit(subject: "Add 30 lines")

        var editedLines = (1...30).map { "line \($0)" }
        editedLines[1] = "line 2 EDITED"
        editedLines[27] = "line 28 EDITED"
        try write("multi.txt", editedLines.joined(separator: "\n") + "\n")

        let initialDiff = try repository.diff(.workingTree(staged: false), path: "multi.txt", context: 3)
        XCTAssertEqual(initialDiff.hunks.count, 2)

        // Stage only the first hunk.
        let firstPatch = initialDiff.hunks[0].patch(oldPath: initialDiff.oldPath, newPath: initialDiff.path)
        try repository.applyPatch(firstPatch, cached: true, reverse: false)

        let stagedDiff = try repository.diff(.workingTree(staged: true), path: "multi.txt", context: 3)
        let unstagedAfterStage = try repository.diff(.workingTree(staged: false), path: "multi.txt", context: 3)
        XCTAssertEqual(stagedDiff.hunks.count, 1)
        XCTAssertEqual(unstagedAfterStage.hunks.count, 1)

        // Unstage the staged hunk back to working tree.
        let stagedPatch = stagedDiff.hunks[0].patch(oldPath: stagedDiff.oldPath, newPath: stagedDiff.path)
        try repository.applyPatch(stagedPatch, cached: true, reverse: true)
        XCTAssertTrue(try repository.diff(.workingTree(staged: true), path: "multi.txt", context: 3).isEmpty)

        // Discard only the first hunk from working tree; keep the second hunk edit intact.
        let unstagedBeforeDiscard = try repository.diff(.workingTree(staged: false), path: "multi.txt", context: 3)
        XCTAssertEqual(unstagedBeforeDiscard.hunks.count, 2)
        let discardPatch = unstagedBeforeDiscard.hunks[0].patch(oldPath: unstagedBeforeDiscard.oldPath, newPath: unstagedBeforeDiscard.path)
        try repository.applyPatch(discardPatch, cached: false, reverse: true)

        let contents = try XCTUnwrap(read("multi.txt"))
        XCTAssertTrue(contents.contains("line 2\n"))
        XCTAssertTrue(contents.contains("line 28 EDITED\n"))
    }

    func testPartialLineStageUnstageAndDiscard() throws {
        let original = "top\nkeep\nbottom\n"
        try write("partial.txt", original)
        try repository.stage(paths: ["partial.txt"])
        _ = try repository.commit(subject: "Base partial file")

        try write("partial.txt", "top\nalpha\nbeta\ngamma\nkeep\nbottom\n")
        let unstagedDiff = try repository.diff(.workingTree(staged: false), path: "partial.txt", context: 3)
        let hunk = try XCTUnwrap(unstagedDiff.hunks.first)
        let addedAlpha = try XCTUnwrap(hunk.lines.first { $0.kind == .addition && $0.text == "alpha" })

        // Stage only "alpha" (1 of 3 added lines).
        let stagePatch = try XCTUnwrap(hunk.partialPatch(
            selectedLineIDs: [addedAlpha.id], reverseSelection: false,
            oldPath: unstagedDiff.oldPath, newPath: unstagedDiff.path))
        try repository.applyPatch(stagePatch.patch, cached: true, reverse: false, unidiffZero: !stagePatch.hasContext)
        XCTAssertEqual(try run(["show", ":partial.txt"]), "top\nalpha\nkeep\nbottom\n")

        // Stage "gamma" too, then unstage only "alpha" from the index.
        let remainingDiff = try repository.diff(.workingTree(staged: false), path: "partial.txt", context: 3)
        let remainingHunk = try XCTUnwrap(remainingDiff.hunks.first)
        let remainingGamma = try XCTUnwrap(remainingHunk.lines.first { $0.kind == .addition && $0.text == "gamma" })
        let stageGamma = try XCTUnwrap(remainingHunk.partialPatch(
            selectedLineIDs: [remainingGamma.id], reverseSelection: false,
            oldPath: remainingDiff.oldPath, newPath: remainingDiff.path))
        try repository.applyPatch(stageGamma.patch, cached: true, reverse: false, unidiffZero: !stageGamma.hasContext)
        XCTAssertEqual(try run(["show", ":partial.txt"]), "top\nalpha\ngamma\nkeep\nbottom\n")

        let stagedDiff = try repository.diff(.workingTree(staged: true), path: "partial.txt", context: 3)
        let stagedHunk = try XCTUnwrap(stagedDiff.hunks.first)
        let stagedAlpha = try XCTUnwrap(stagedHunk.lines.first { $0.kind == .addition && $0.text == "alpha" })
        let unstageAlpha = try XCTUnwrap(stagedHunk.partialPatch(
            selectedLineIDs: [stagedAlpha.id], reverseSelection: true,
            oldPath: stagedDiff.oldPath, newPath: stagedDiff.path))
        try repository.applyPatch(unstageAlpha.patch, cached: true, reverse: true, unidiffZero: !unstageAlpha.hasContext)
        XCTAssertEqual(try run(["show", ":partial.txt"]), "top\ngamma\nkeep\nbottom\n")

        // Discard only "alpha" from the working tree; leave "beta" untouched.
        let workDiff = try repository.diff(.workingTree(staged: false), path: "partial.txt", context: 3)
        let workHunk = try XCTUnwrap(workDiff.hunks.first)
        let workAlpha = try XCTUnwrap(workHunk.lines.first { $0.kind == .addition && $0.text == "alpha" })
        let discardAlpha = try XCTUnwrap(workHunk.partialPatch(
            selectedLineIDs: [workAlpha.id], reverseSelection: true,
            oldPath: workDiff.oldPath, newPath: workDiff.path))
        try repository.applyPatch(discardAlpha.patch, cached: false, reverse: true, unidiffZero: !discardAlpha.hasContext)
        XCTAssertEqual(read("partial.txt"), "top\nbeta\ngamma\nkeep\nbottom\n")

        // Stage only the addition of a replacement (leaving the deleted line staged as context until deleted too).
        try write("partial.txt", "top\nbeta\ngamma\nreplaced\nbottom\n")
        let replaceDiff = try repository.diff(.workingTree(staged: false), path: "partial.txt", context: 3)
        let replaceHunk = try XCTUnwrap(replaceDiff.hunks.first)
        let replacedAdd = try XCTUnwrap(replaceHunk.lines.first { $0.kind == .addition && $0.text == "replaced" })
        let addOnlyPatch = try XCTUnwrap(replaceHunk.partialPatch(
            selectedLineIDs: [replacedAdd.id], reverseSelection: false,
            oldPath: replaceDiff.oldPath, newPath: replaceDiff.path))
        try repository.applyPatch(addOnlyPatch.patch, cached: true, reverse: false, unidiffZero: !addOnlyPatch.hasContext)
        XCTAssertEqual(try run(["show", ":partial.txt"]), "top\ngamma\nkeep\nreplaced\nbottom\n")
    }

    func testConflictVersionsAcceptSideAndAbortMerge() throws {
        try write("shared.txt", "line1\nbase\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Base shared")

        try repository.createBranch(name: "incoming", checkout: true)
        try write("shared.txt", "line1\ntheir change\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Incoming edit")

        try repository.checkoutBranch("main", isRemote: false)
        try write("shared.txt", "line1\nour change\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Main edit")

        // Trigger a real merge conflict.
        XCTAssertThrowsError(try run(["merge", "incoming"]))
        let conflictedState = try state()
        XCTAssertEqual(conflictedState.operation, .merge)
        XCTAssertEqual(conflictedState.conflicted.map(\.path), ["shared.txt"])

        let versions = try repository.conflictVersions(path: "shared.txt")
        XCTAssertEqual(versions.base, "line1\nbase\nline3\n")
        XCTAssertEqual(versions.ours, "line1\nour change\nline3\n")
        XCTAssertEqual(versions.theirs, "line1\ntheir change\nline3\n")
        XCTAssertNotNil(versions.firstConflictLine)

        // Resolve accepting theirs, verify index & working copy match, then abort the merge cleanly.
        try repository.resolveConflictUsingSide(path: "shared.txt", acceptOurs: false)
        XCTAssertEqual(read("shared.txt"), "line1\ntheir change\nline3\n")
        XCTAssertTrue(try state().conflicted.isEmpty)

        try repository.abortOperation(.merge)
        let abortedState = try state()
        XCTAssertNil(abortedState.operation)
        XCTAssertEqual(read("shared.txt"), "line1\nour change\nline3\n")
    }

    func testCreatePushAndDeleteTags() throws {
        let remote = root.appendingPathComponent("../remote-tags-\(UUID().uuidString).git").standardized
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", remote.path], in: root)
        defer { try? FileManager.default.removeItem(at: remote) }
        try run(["remote", "add", "origin", remote.path])
        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        try repository.createTag(name: "v0.1.0")
        try repository.createTag(name: "v0.2.0", message: "Annotated release")
        let tags = try repository.tags()
        XCTAssertTrue(tags.contains(where: { $0.name == "v0.1.0" && !$0.isAnnotated }))
        XCTAssertTrue(tags.contains(where: { $0.name == "v0.2.0" && $0.isAnnotated && $0.subject == "Annotated release" }))

        try repository.pushTag(remote: "origin", name: "v0.2.0")
        let remoteTags = try run(["ls-remote", "--tags", "origin"])
        XCTAssertTrue(remoteTags.contains("refs/tags/v0.2.0"))

        try repository.deleteTag(name: "v0.1.0")
        let afterDelete = try repository.tags()
        XCTAssertFalse(afterDelete.contains(where: { $0.name == "v0.1.0" }))
        XCTAssertTrue(afterDelete.contains(where: { $0.name == "v0.2.0" }))
    }

    func testUndoLastCommitSoftAndAmendCommitRespectPushSafety() throws {
        let remote = root.appendingPathComponent("../remote-safety-\(UUID().uuidString).git").standardized
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", remote.path], in: root)
        defer { try? FileManager.default.removeItem(at: remote) }
        try run(["remote", "add", "origin", remote.path])
        try repository.push(remote: "origin", branch: "main", setUpstream: true)

        // Cannot undo or unguarded-amend a pushed commit.
        let pushedInfo = try XCTUnwrap(repository.headCommitInfo())
        XCTAssertTrue(pushedInfo.isPushedToUpstream)
        XCTAssertFalse(pushedInfo.hasParent)
        XCTAssertThrowsError(try repository.undoLastCommitSoft())
        XCTAssertThrowsError(try repository.amendCommit(subject: "Should refuse", allowPublished: false))

        // Make a local unpushed commit.
        try write("tracked.txt", "second version\n")
        try repository.stage(paths: ["tracked.txt"])
        _ = try repository.commit(subject: "Draft commit", body: "Initial notes")

        let localInfo = try XCTUnwrap(repository.headCommitInfo())
        XCTAssertFalse(localInfo.isPushedToUpstream)
        XCTAssertTrue(localInfo.hasParent)
        XCTAssertEqual(localInfo.subject, "Draft commit")
        XCTAssertEqual(localInfo.body, "Initial notes")

        // Amend updates subject & body without requiring new staged files.
        _ = try repository.amendCommit(subject: "Polished commit", body: "Updated notes")
        let amended = try XCTUnwrap(repository.headCommitInfo())
        XCTAssertEqual(amended.subject, "Polished commit")
        XCTAssertEqual(amended.body, "Updated notes")

        // Soft undo returns HEAD to initial while keeping tracked.txt staged.
        try repository.undoLastCommitSoft()
        let undoneState = try state()
        XCTAssertEqual(undoneState.staged.map(\.path), ["tracked.txt"])
        XCTAssertEqual(try repository.headCommitInfo()?.subject, "initial")
    }

    func testMergeRebaseRenameForceDeleteCherryPickAndRevert() throws {
        // Rename branch & force delete unmerged branch.
        try repository.createBranch(name: "feat-temp", checkout: true)
        try write("feat.txt", "feature work\n")
        try repository.stage(paths: ["feat.txt"])
        let featSHA = try repository.commit(subject: "Add feature file")

        try repository.renameBranch(from: "feat-temp", to: "feat-renamed")
        XCTAssertEqual(try state().branch, "feat-renamed")

        try repository.checkoutBranch("main", isRemote: false)
        // Cherry-pick featSHA onto main and revert it.
        try repository.cherryPick(sha: featSHA)
        XCTAssertEqual(read("feat.txt"), "feature work\n")
        let pickedSHA = try repository.headSHA()

        try repository.revertCommit(sha: pickedSHA)
        XCTAssertNil(read("feat.txt"))

        // Rebase feat-renamed onto main (or merge another branch).
        try repository.createBranch(name: "side", checkout: true)
        try write("side.txt", "side edit\n")
        try repository.stage(paths: ["side.txt"])
        _ = try repository.commit(subject: "Side work")

        try repository.checkoutBranch("main", isRemote: false)
        try write("main.txt", "main edit\n")
        try repository.stage(paths: ["main.txt"])
        _ = try repository.commit(subject: "Main work")

        try repository.checkoutBranch("side", isRemote: false)
        try repository.rebaseOnto("main")
        XCTAssertEqual(read("main.txt"), "main edit\n")
        XCTAssertEqual(read("side.txt"), "side edit\n")

        try repository.checkoutBranch("main", isRemote: false)
        try repository.mergeBranch("side")
        XCTAssertEqual(read("side.txt"), "side edit\n")

        // Force delete unmerged branch feat-renamed.
        try repository.deleteBranchForce(name: "feat-renamed")
        let remaining = try GitProcess.capture(arguments: ["branch", "--list", "feat-renamed"], in: root)
        XCTAssertTrue(remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testConflictMarkerResolverAndContinueMergeOperation() throws {
        let diff3Text = """
        top
        <<<<<<< HEAD
        ours line
        ||||||| base
        base line
        =======
        theirs line
        >>>>>>> topic
        bottom
        """
        let parsed = ConflictMarkerResolver.parseBlocks(in: diff3Text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].oursText, "ours line")
        XCTAssertEqual(parsed[0].theirsText, "theirs line")
        XCTAssertEqual(
            ConflictMarkerResolver.resolving(text: diff3Text, blockIndex: 0, choice: .both),
            "top\nours line\ntheirs line\nbottom"
        )
        XCTAssertEqual(
            ConflictMarkerResolver.resolving(text: diff3Text + "\n", blockIndex: 0, choice: .both),
            "top\nours line\ntheirs line\nbottom\n"
        )

        // End-to-end merge conflict -> resolveConflictBlock -> continueOperation(.merge).
        try write("shared.txt", "line1\nbase\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Base file")

        try repository.createBranch(name: "topic", checkout: true)
        try write("shared.txt", "line1\ntheirs\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Topic change")

        try repository.checkoutBranch("main", isRemote: false)
        try write("shared.txt", "line1\nours\nline3\n")
        try repository.stage(paths: ["shared.txt"])
        _ = try repository.commit(subject: "Main change")

        XCTAssertThrowsError(try repository.mergeBranch("topic"))
        XCTAssertEqual(try state().operation, .merge)

        let blocks = try repository.conflictBlocks(path: "shared.txt")
        XCTAssertEqual(blocks.count, 1)
        let remaining = try repository.resolveConflictBlock(path: "shared.txt", blockIndex: 0, choice: .ours)
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(try state().conflicted.isEmpty)

        try repository.continueOperation(.merge)
        XCTAssertNil(try state().operation)
        XCTAssertEqual(read("shared.txt"), "line1\nours\nline3\n")
    }

    func testInitRepositoryAndCloneLocalRemote() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-initclone-\(UUID().uuidString)")
        let newRepoURL = base.appendingPathComponent("created")
        let bareRemoteURL = base.appendingPathComponent("remote.git")
        let clonedURL = base.appendingPathComponent("cloned")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let validatedInit = try GitRepository.initRepository(at: newRepoURL, initialBranch: "trunk")
        XCTAssertEqual(validatedInit.standardizedFileURL, newRepoURL.standardizedFileURL)
        try "hello\n".write(to: newRepoURL.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let repo = GitRepository(url: validatedInit)
        try repo.stageAll()
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Init User"], in: validatedInit)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "init@example.com"], in: validatedInit)
        _ = try repo.commit(subject: "Init commit")

        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", "-b", "trunk", bareRemoteURL.path], in: base)
        _ = try GitProcess.capture(arguments: ["remote", "add", "origin", bareRemoteURL.path], in: validatedInit)
        try repo.push(remote: "origin", branch: "trunk", setUpstream: true)

        let validatedClone = try await GitRepository.clone(remoteURL: bareRemoteURL.path, into: clonedURL)
        XCTAssertEqual(validatedClone.standardizedFileURL, clonedURL.standardizedFileURL)
        let clonedFile = try String(contentsOf: clonedURL.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(clonedFile, "hello\n")
    }

    func testAppendToGitignoreCreatesAndDeduplicatesAndDiscardAllChanges() throws {
        try repository.appendToGitignore(patterns: ["*.log", ".DS_Store"])
        try repository.appendToGitignore(patterns: ["*.log", "build/"])

        let contents = try XCTUnwrap(read(".gitignore"))
        XCTAssertEqual(contents, "*.log\n.DS_Store\nbuild/\n")

        try write("tracked.txt", "modified tracked\n")
        try write("other.txt", "modified other\n")
        try write("untracked-keep.txt", "keep\n")
        try repository.discardAllChanges()

        XCTAssertEqual(read("tracked.txt"), "original\n")
        XCTAssertEqual(read("other.txt"), "other\n")
        XCTAssertEqual(read("untracked-keep.txt"), "keep\n")
    }

    func testRemoteAndWorktreeLifecycleAndSoftReset() throws {
        let remote1 = root.appendingPathComponent("../wt-remote1-\(UUID().uuidString).git").standardized
        let remote2 = root.appendingPathComponent("../wt-remote2-\(UUID().uuidString).git").standardized
        let wtDir = root.appendingPathComponent("../wt-linked-\(UUID().uuidString)").standardized
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", remote1.path], in: root)
        _ = try GitProcess.capture(arguments: ["init", "--bare", "-q", remote2.path], in: root)
        defer {
            try? FileManager.default.removeItem(at: remote1)
            try? FileManager.default.removeItem(at: remote2)
            try? FileManager.default.removeItem(at: wtDir)
        }

        // Remotes: add, set-url, rename, remove.
        try repository.addRemote(name: "upstream", url: remote1.path)
        XCTAssertEqual(try repository.info().remotes["upstream"], remote1.path)

        try repository.setRemoteURL(name: "upstream", url: remote2.path)
        XCTAssertEqual(try repository.info().remotes["upstream"], remote2.path)

        try repository.renameRemote(from: "upstream", to: "backup")
        let renamedRemotes = try repository.info().remotes
        XCTAssertNil(renamedRemotes["upstream"])
        XCTAssertEqual(renamedRemotes["backup"], remote2.path)

        try repository.removeRemote(name: "backup")
        XCTAssertNil(try repository.info().remotes["backup"])

        // Worktrees: add, verify in info, remove, prune.
        try repository.addWorktree(path: wtDir, branch: "wt-feature", createBranch: true, startPoint: "main")
        let worktrees = try repository.info().worktrees
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertTrue(worktrees.contains(where: { $0.branch == "wt-feature" }))

        try repository.removeWorktree(path: wtDir.path)
        try repository.pruneWorktrees()
        XCTAssertEqual(try repository.info().worktrees.count, 1)

        // Soft reset keeps working edits staged.
        let initialSHA = try repository.headSHA()
        try write("tracked.txt", "before soft reset\n")
        try repository.stage(paths: ["tracked.txt"])
        _ = try repository.commit(subject: "Temporary commit")
        try repository.resetSoft(to: initialSHA)
        XCTAssertEqual(try repository.headSHA(), initialSHA)
        XCTAssertEqual(try state().staged.map(\.path), ["tracked.txt"])
    }
}
