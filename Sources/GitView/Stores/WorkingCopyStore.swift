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
    public private(set) var writeInFlight = false
    public var writeError: String?
    public var confirmation: DestructiveConfirmation?
    public private(set) var pushPlan: GitRepository.PushPlan?

    @ObservationIgnored var rootProvider: () -> URL? = { nil }
    @ObservationIgnored var onWorkingStateRefreshed: (URL, WorkingState) -> Void = { _, _ in }
    @ObservationIgnored var onHistoryMutated: () -> Void = {}

    public init() {}

    public func clear() {
        writeError = nil
        confirmation = nil
        pushPlan = nil
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

    private func perform(_ label: String, reloadHistory: Bool = false,
                         onSuccess: (@MainActor () -> Void)? = nil,
                         _ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let root = rootProvider(), !writeInFlight else { return }
        writeInFlight = true
        writeError = nil
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try work(GitRepository(url: root)); return nil } catch { return "\(error)" }
            }.value
            self.writeError = failure
            self.writeInFlight = false
            if failure == nil {
                if reloadHistory {
                    self.onHistoryMutated()
                } else {
                    self.refreshWorkingState()
                    self.refreshPushPlan()
                }
                onSuccess?()
            } else {
                self.refreshWorkingState()
                self.refreshPushPlan()
            }
        }
    }

    public func stage(_ paths: [String]) { perform("stage") { try $0.stage(paths: paths) } }
    public func stageAll() { perform("stage all") { try $0.stageAll() } }
    public func unstage(_ paths: [String]) { perform("unstage") { try $0.unstage(paths: paths) } }

    public func commitStaged() {
        let subject = commitSubject
        let body = commitBody
        perform("commit", reloadHistory: true) { _ = try $0.commit(subject: subject, body: body) }
        commitSubject = ""
        commitBody = ""
    }

    public func stashEverything(includeUntracked: Bool) {
        let message = stashMessage
        perform("stash") { try $0.stashPush(message: message, includeUntracked: includeUntracked) }
        stashMessage = ""
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
        perform("pull", reloadHistory: true) { try $0.pullFastForwardOnly() }
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
