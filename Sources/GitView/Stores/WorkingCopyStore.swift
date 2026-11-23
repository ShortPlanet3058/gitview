import Foundation
import Observation
import GitViewCore
import GitViewGit

/// A change that cannot be undone, described in the terms the user needs to decide.
public struct DestructiveConfirmation: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let confirmLabel: String
    /// A safer alternative that keeps the work, offered where one exists.
    public let alternativeLabel: String?
    public let perform: () -> Void
    public let alternative: (() -> Void)?
}

/// Manages `git status` state, staging/unstaging, commits, stashes, and pushes.
@MainActor
@Observable
public final class WorkingCopyStore {
    public var commitSubject = ""
    public var commitBody = ""
    public var stashMessage = ""
    public var amendLastCommit = false
    public private(set) var writeInFlight = false
    public var writeError: String?
    public var confirmation: DestructiveConfirmation?
    public private(set) var pushPlan: GitRepository.PushPlan?
    public private(set) var headCommitInfo: GitRepository.HeadCommitInfo?
    public var divergedPullPrompt = false

    @ObservationIgnored var rootProvider: () -> URL? = { nil }
    @ObservationIgnored var onWorkingStateRefreshed: (URL, WorkingState) -> Void = { _, _ in }
    @ObservationIgnored var onHistoryMutated: () -> Void = {}

    public init() {}

    public func clear() {
        writeError = nil
        confirmation = nil
        pushPlan = nil
        headCommitInfo = nil
        amendLastCommit = false
        divergedPullPrompt = false
    }

    public func refreshWorkingState() {
        guard let root = rootProvider() else { return }
        Task.detached(priority: .utility) {
            let fresh = (try? GitRepository(url: root).workingState()) ?? .clean
            await MainActor.run {
                self.onWorkingStateRefreshed(root, fresh)
            }
        }
    }

    public func refreshPushPlan() {
        guard let root = rootProvider() else { return }
        Task.detached(priority: .utility) {
            let plan = try? GitRepository(url: root).pushPlan()
            await MainActor.run {
                guard self.rootProvider() == root else { return }
                self.pushPlan = plan
            }
        }
    }

    public func refreshHeadCommitInfo() {
        guard let root = rootProvider() else { return }
        Task.detached(priority: .utility) {
            let info = try? GitRepository(url: root).headCommitInfo()
            await MainActor.run {
                guard self.rootProvider() == root else { return }
                self.headCommitInfo = info
            }
        }
    }

    private static func isDivergedPullFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not possible to fast-forward")
            || lower.contains("divergent branches")
            || lower.contains("can't be fast-forwarded")
    }

    private func perform(_ label: String, reloadHistory: Bool = false,
                         detectDivergence: Bool = false,
                         onSuccess: (@MainActor () -> Void)? = nil,
                         _ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let root = rootProvider(), !writeInFlight else { return }
        writeInFlight = true
        writeError = nil
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try work(GitRepository(url: root)); return nil } catch { return "\(error)" }
            }.value
            if let failure, detectDivergence, Self.isDivergedPullFailure(failure) {
                self.writeError = nil
                self.divergedPullPrompt = true
            } else {
                self.writeError = failure
            }
            self.writeInFlight = false
            if failure == nil {
                if reloadHistory {
                    self.onHistoryMutated()
                } else {
                    self.refreshWorkingState()
                    self.refreshPushPlan()
                    self.refreshHeadCommitInfo()
                }
                onSuccess?()
            } else {
                self.refreshWorkingState()
                self.refreshPushPlan()
                self.refreshHeadCommitInfo()
            }
        }
    }

    public func stage(_ paths: [String]) { perform("stage") { try $0.stage(paths: paths) } }
    public func stageAll() { perform("stage all") { try $0.stageAll() } }
    public func unstage(_ paths: [String]) { perform("unstage") { try $0.unstage(paths: paths) } }

    public func toggleAmend() {
        amendLastCommit.toggle()
        if amendLastCommit,
           commitSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let info = headCommitInfo {
            commitSubject = info.subject
            commitBody = info.body
        }
    }

    public func commitStaged(allowPublishedAmend: Bool = false) {
        let subject = commitSubject
        let body = commitBody
        let amending = amendLastCommit
        perform(amending ? "amend commit" : "commit", reloadHistory: true, onSuccess: { [weak self] in
            self?.commitSubject = ""
            self?.commitBody = ""
            self?.amendLastCommit = false
        }) { repository in
            if amending {
                _ = try repository.amendCommit(subject: subject, body: body, allowPublished: allowPublishedAmend)
            } else {
                _ = try repository.commit(subject: subject, body: body)
            }
        }
    }

    public func commitAndPush(allowPublishedAmend: Bool = false) {
        let subject = commitSubject
        let body = commitBody
        let amending = amendLastCommit
        guard let root = rootProvider(), !writeInFlight else { return }
        writeInFlight = true
        writeError = nil
        Task {
            let outcome: (committed: Bool, failure: String?) = await Task.detached(priority: .userInitiated) {
                let repository = GitRepository(url: root)
                do {
                    if amending {
                        _ = try repository.amendCommit(subject: subject, body: body, allowPublished: allowPublishedAmend)
                    } else {
                        _ = try repository.commit(subject: subject, body: body)
                    }
                } catch {
                    return (false, "\(error)")
                }
                do {
                    if let plan = try repository.pushPlan() {
                        try repository.push(remote: plan.remote, branch: plan.branch, setUpstream: !plan.hasUpstream)
                    }
                    return (true, nil)
                } catch {
                    return (true, "\(error)")
                }
            }.value
            self.writeError = outcome.failure
            self.writeInFlight = false
            if outcome.committed {
                self.commitSubject = ""
                self.commitBody = ""
                self.amendLastCommit = false
                self.onHistoryMutated()
            } else {
                self.refreshWorkingState()
                self.refreshPushPlan()
                self.refreshHeadCommitInfo()
            }
        }
    }

    public func sync() {
        perform("sync", reloadHistory: true, detectDivergence: true) { repository in
            try repository.fetch(prune: true)
            let fresh = try repository.workingState()
            if fresh.behind > 0 {
                try repository.pullFastForwardOnly()
            }
            if let plan = try repository.pushPlan(), !plan.isEmpty {
                try repository.push(remote: plan.remote, branch: plan.branch, setUpstream: !plan.hasUpstream)
            }
        }
    }

    public func stashEverything(includeUntracked: Bool) {
        let message = stashMessage
        perform("stash", onSuccess: { [weak self] in
            self?.stashMessage = ""
        }) {
            try $0.stashPush(message: message, includeUntracked: includeUntracked)
        }
    }

    public func applyStash(_ ref: String, removing: Bool) {
        perform("stash apply") { try $0.stashApply(ref, removing: removing) }
    }

    public func push() {
        guard let plan = pushPlan else { return }
        perform("push", reloadHistory: true) {
            try $0.push(remote: plan.remote, branch: plan.branch, setUpstream: !plan.hasUpstream)
        }
    }

    public func fetch() {
        perform("fetch", reloadHistory: true) { try $0.fetch() }
    }

    public func pull() {
        perform("pull", reloadHistory: true, detectDivergence: true) { try $0.pullFastForwardOnly() }
    }

    public func pullRebase() {
        perform("pull --rebase", reloadHistory: true) { try $0.pullRebase() }
    }

    public func pullMerge() {
        perform("pull merge", reloadHistory: true) { try $0.pullMerge() }
    }

    public func confirmUndoLastCommit() {
        guard let info = headCommitInfo, info.hasParent, !info.isPushedToUpstream else { return }
        confirmation = DestructiveConfirmation(
            title: "Undo last commit?",
            message: "“\(info.subject)” (\(String(info.sha.prefix(7)))) will be undone, keeping its changes staged in your working copy.",
            confirmLabel: "Undo Commit",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("undo commit", reloadHistory: true) {
                    try $0.undoLastCommitSoft()
                }
            },
            alternative: nil
        )
    }

    public func confirmMergeBranch(_ branch: BranchInfo, into currentBranch: String?) {
        confirmation = DestructiveConfirmation(
            title: "Merge “\(branch.name)” into “\(currentBranch ?? "current branch")”?",
            message: "Changes from \(branch.name) will be merged into your checked out branch.",
            confirmLabel: "Merge Branch",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("merge", reloadHistory: true) {
                    try $0.mergeBranch(branch.name)
                }
            },
            alternative: nil
        )
    }

    public func confirmRebaseOnto(_ branch: BranchInfo, currentBranch: String?) {
        confirmation = DestructiveConfirmation(
            title: "Rebase “\(currentBranch ?? "current branch")” onto “\(branch.name)”?",
            message: "Your local commits will be replayed on top of \(branch.name). Any conflicts can be resolved in Changes.",
            confirmLabel: "Rebase",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("rebase", reloadHistory: true) {
                    try $0.rebaseOnto(branch.name)
                }
            },
            alternative: nil
        )
    }

    public func renameBranch(from oldName: String, to newName: String) {
        perform("rename branch", reloadHistory: true) {
            try $0.renameBranch(from: oldName, to: newName)
        }
    }

    public func confirmForceDeleteBranch(_ branch: BranchInfo) {
        confirmation = DestructiveConfirmation(
            title: "Force delete “\(branch.name)”?",
            message: "This branch is not marked as merged. Deleting with git branch -D removes the branch ref even if its commits are not on the default branch.",
            confirmLabel: "Force Delete",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("force delete branch", reloadHistory: true) {
                    try $0.deleteBranchForce(name: branch.name)
                }
            },
            alternative: nil
        )
    }

    public func cherryPick(commit: Commit) {
        perform("cherry-pick", reloadHistory: true) {
            try $0.cherryPick(sha: commit.sha)
        }
    }

    public func confirmRevertCommit(_ commit: Commit) {
        let summary = commit.subject.isEmpty ? String(commit.sha.prefix(7)) : commit.subject
        confirmation = DestructiveConfirmation(
            title: "Revert “\(summary)”?",
            message: "Creates a new commit that reverses the changes from \(String(commit.sha.prefix(7))).",
            confirmLabel: "Revert Commit",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("revert commit", reloadHistory: true) {
                    try $0.revertCommit(sha: commit.sha)
                }
            },
            alternative: nil
        )
    }

    public func continueOperation(_ operation: WorkingState.Operation) {
        perform("continue operation", reloadHistory: true) {
            try $0.continueOperation(operation)
        }
    }

    public func resolveConflictBlock(path: String, blockIndex: Int, choice: ConflictBlockChoice,
                                     onComplete: @escaping @MainActor () -> Void = {}) {
        perform("resolve conflict block", onSuccess: onComplete) {
            _ = try $0.resolveConflictBlock(path: path, blockIndex: blockIndex, choice: choice)
        }
    }

    public func switchBranch(_ name: String, isRemote: Bool = false) {
        perform("switch branch", reloadHistory: true) {
            try $0.checkoutBranch(name, isRemote: isRemote)
        }
    }

    public func createBranch(name: String, startPoint: String? = nil) {
        perform("create branch", reloadHistory: true) {
            try $0.createBranch(name: name, startPoint: startPoint, checkout: true)
        }
    }

    public func confirmDeleteBranch(_ branch: BranchInfo) {
        confirmation = DestructiveConfirmation(
            title: "Delete branch “\(branch.name)”?",
            message: "Only already-merged local branches are deleted with git branch -d. "
                   + "Its last commit stays at \(String(branch.sha.prefix(7))).",
            confirmLabel: "Delete branch",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("delete branch", reloadHistory: true) {
                    try $0.deleteMergedBranch(name: branch.name)
                }
            },
            alternative: nil)
    }

    public func applyHunk(_ hunk: DiffHunk, diff: FileDiff, staged: Bool, discard: Bool = false,
                          onComplete: @escaping @MainActor () -> Void = {}) {
        let patch = hunk.patch(oldPath: diff.oldPath, newPath: diff.path,
                               isNewFile: diff.isNew, isDeletedFile: diff.isDeleted)
        let needsUnidiffZero = !hunk.lines.contains(where: { $0.kind == .context })
        if discard {
            confirmation = DestructiveConfirmation(
                title: "Discard hunk in \((diff.path as NSString).lastPathComponent)?",
                message: "The edits in hunk @@ −\(hunk.oldStart) +\(hunk.newStart) @@ will be reverted in your working copy. This cannot be undone.",
                confirmLabel: "Discard Hunk",
                alternativeLabel: nil,
                perform: { [weak self] in
                    self?.perform("discard hunk", onSuccess: onComplete) {
                        try $0.applyPatch(patch, cached: false, reverse: true, unidiffZero: needsUnidiffZero)
                    }
                },
                alternative: nil)
        } else {
            let reverse = staged
            perform(staged ? "unstage hunk" : "stage hunk", onSuccess: onComplete) {
                try $0.applyPatch(patch, cached: true, reverse: reverse, unidiffZero: needsUnidiffZero)
            }
        }
    }

    public func applySelectedLines(_ lineIDs: Set<Int>, in hunk: DiffHunk, diff: FileDiff,
                                   staged: Bool, discard: Bool = false,
                                   onComplete: @escaping @MainActor () -> Void = {}) {
        guard let built = hunk.partialPatch(
            selectedLineIDs: lineIDs,
            reverseSelection: staged || discard,
            oldPath: diff.oldPath,
            newPath: diff.path,
            isNewFile: diff.isNew,
            isDeletedFile: diff.isDeleted
        ) else { return }
        let needsUnidiffZero = !built.hasContext
        let count = hunk.lines.count(where: { $0.kind != .context && lineIDs.contains($0.id) })
        let noun = "\(count) line\(count == 1 ? "" : "s")"
        if discard {
            confirmation = DestructiveConfirmation(
                title: "Discard \(noun) in \((diff.path as NSString).lastPathComponent)?",
                message: "The selected edits in hunk @@ −\(hunk.oldStart) +\(hunk.newStart) @@ will be reverted in your working copy. This cannot be undone.",
                confirmLabel: "Discard \(noun)",
                alternativeLabel: nil,
                perform: { [weak self] in
                    self?.perform("discard lines", onSuccess: onComplete) {
                        try $0.applyPatch(built.patch, cached: false, reverse: true, unidiffZero: needsUnidiffZero)
                    }
                },
                alternative: nil)
        } else {
            perform(staged ? "unstage lines" : "stage lines", onSuccess: onComplete) {
                try $0.applyPatch(built.patch, cached: true, reverse: staged, unidiffZero: needsUnidiffZero)
            }
        }
    }

    public func confirmDiscard(_ file: WorkingState.FileStatus) {
        confirmation = DestructiveConfirmation(
            title: "Discard changes to \((file.path as NSString).lastPathComponent)?",
            message: "The edits in your working copy will be gone. Nothing in git has a copy of them, "
                   + "so this cannot be undone. Stashing keeps them and you can bring them back later.",
            confirmLabel: "Discard",
            alternativeLabel: "Stash instead",
            perform: { [weak self] in
                self?.perform("discard") { try $0.discardChanges(paths: [file.path]) }
            },
            alternative: { [weak self] in
                self?.perform("stash") {
                    try $0.stashPush(message: "Set aside \(file.path)", includeUntracked: false, paths: [file.path])
                }
            })
    }

    public func confirmDelete(_ file: WorkingState.FileStatus) {
        confirmation = DestructiveConfirmation(
            title: "Delete \((file.path as NSString).lastPathComponent)?",
            message: "This file has never been committed, so git has no copy of it. Deleting it removes "
                   + "it from disk permanently.",
            confirmLabel: "Delete",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("delete") { try $0.deleteUntracked(paths: [file.path]) }
            },
            alternative: nil)
    }

    public func confirmDropStash(_ stash: WorkingState.Stash) {
        confirmation = DestructiveConfirmation(
            title: "Drop \(stash.ref)?",
            message: "“\(stash.message)” will be discarded. A dropped stash is very hard to recover.",
            confirmLabel: "Drop",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("stash drop") { try $0.stashDrop(stash.ref) }
            },
            alternative: nil)
    }

    public func confirmAbortOperation(_ operation: WorkingState.Operation) {
        confirmation = DestructiveConfirmation(
            title: "Abort \(operation.label.lowercased())?",
            message: "Git will abort the interrupted operation and restore your branch to the state before it started. Uncommitted conflict edits will be discarded.",
            confirmLabel: "Abort",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("abort operation", reloadHistory: true) {
                    try $0.abortOperation(operation)
                }
            },
            alternative: nil)
    }

    public func confirmResolveConflict(path: String, acceptOurs: Bool) {
        let sideName = acceptOurs ? "ours (current branch)" : "theirs (incoming)"
        confirmation = DestructiveConfirmation(
            title: "Accept \(sideName) for \((path as NSString).lastPathComponent)?",
            message: "This replaces conflict markers in \(path) with the \(sideName) version and stages the resolved file.",
            confirmLabel: acceptOurs ? "Accept Ours" : "Accept Theirs",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("resolve conflict") {
                    try $0.resolveConflictUsingSide(path: path, acceptOurs: acceptOurs)
                }
            },
            alternative: nil)
    }

    public func createTag(name: String, target: String = "HEAD", message: String? = nil) {
        perform("create tag", reloadHistory: true) {
            try $0.createTag(name: name, target: target, message: message)
        }
    }

    public func pushTag(name: String, remote: String = "origin") {
        perform("push tag", reloadHistory: true) {
            try $0.pushTag(remote: remote, name: name)
        }
    }

    public func confirmDeleteTag(_ tag: TagInfo) {
        confirmation = DestructiveConfirmation(
            title: "Delete tag “\(tag.name)”?",
            message: "This deletes the local tag ref (git tag -d). Remote copies, if pushed, are left untouched.",
            confirmLabel: "Delete Tag",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("delete tag", reloadHistory: true) {
                    try $0.deleteTag(name: tag.name)
                }
            },
            alternative: nil)
    }
}
