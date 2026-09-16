import Foundation
import GitViewCore

/// A failed write, with the command that failed and what git said about it.
public struct GitWriteError: Error, CustomStringConvertible {
    public let command: String
    public let message: String
    public var description: String {
        message.isEmpty ? "git \(command) failed" : message
    }
}

/// Operations that change the repository.
///
/// Deliberately absent: `push --force`, `reset --hard`, and amending a commit that has
/// already been pushed. Each of those can destroy work that exists nowhere else, and none
/// is needed often enough to be worth the footgun in a tool people reach for while tired.
extension GitRepository {

    @discardableResult
    private func write(_ arguments: [String]) throws -> String {
        let root = try validate()
        do {
            return try GitProcess.capture(arguments: arguments, in: root)
        } catch let error as GitError {
            if case .failed(let command, _, let stderr) = error {
                throw GitWriteError(command: command,
                                    message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw error
        }
    }

    // MARK: - Reversible

    /// Stages files. Undone by `unstage`.
    public func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try write(["add", "--"] + paths)
    }

    public func stageAll() throws {
        try write(["add", "--all"])
    }

    /// Unstages files, leaving the working tree untouched. Undone by `stage`.
    public func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // `restore --staged` rather than `reset`, so this can never move HEAD.
        try write(["restore", "--staged", "--"] + paths)
    }

    /// Commits what is staged. Returns the new commit's id.
    public func commit(subject: String, body: String = "") throws -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "commit", message: "A commit needs a message.")
        }
        var arguments = ["commit", "-m", trimmed]
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty { arguments += ["-m", trimmedBody] }
        try write(arguments)
        return try headSHA()
    }

    /// Saves changes aside. Recoverable from the stash list afterwards.
    public func stashPush(message: String, includeUntracked: Bool) throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-m", trimmed] }
        try write(arguments)
    }

    /// - Parameter removing: true drops the stash after applying it (`git stash pop`).
    public func stashApply(_ ref: String, removing: Bool) throws {
        try write(["stash", removing ? "pop" : "apply", ref])
    }

    // MARK: - Destructive

    /// Throws away uncommitted changes to tracked files. **There is no undo**: the previous
    /// contents exist nowhere, which is why the UI offers stashing instead.
    public func discardChanges(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try write(["restore", "--worktree", "--"] + paths)
    }

    /// Deletes untracked files from disk. Also unrecoverable — git never had them.
    public func deleteUntracked(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // `-f` is required for any removal at all; `--` guards paths that look like flags.
        try write(["clean", "-f", "--"] + paths)
    }

    /// Discards a stash entry.
    public func stashDrop(_ ref: String) throws {
        try write(["stash", "drop", ref])
    }

    // MARK: - Outward facing

    /// What a push would send, so the user can be shown it before agreeing.
    public struct PushPlan: Sendable, Hashable {
        public let remote: String
        public let branch: String
        public let commits: [Commit]
        public let hasUpstream: Bool
        public var isEmpty: Bool { commits.isEmpty }
    }

    public func pushPlan(limit: Int = 50) throws -> PushPlan? {
        let state = try workingState()
        guard let branch = state.branch else { return nil }
        let remote = (try? GitProcess.capture(arguments: ["remote"], in: validate()))?
            .split(separator: "\n").first.map(String.init) ?? "origin"
        let range = state.upstream.map { "\($0)..HEAD" } ?? "HEAD"
        let output = (try? GitProcess.capture(
            arguments: ["log", "--max-count=\(limit)", "--pretty=format:%H%x1f%aN%x1f%aI%x1f%s", range],
            in: validate())) ?? ""
        return PushPlan(remote: remote, branch: branch,
                        commits: CodeSearchParser.parseCommitHeaders(output),
                        hasUpstream: state.upstream != nil)
    }

    /// Publishes commits. Never forced: a rejected push means the remote has work this
    /// checkout has not seen, and the answer to that is to pull, not to overwrite it.
    public func push(remote: String, branch: String, setUpstream: Bool) throws {
        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        arguments += [remote, branch]
        try write(arguments)
    }
}
