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
            if failure == nil, reloadHistory {
                self.onHistoryMutated()
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
}
