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
    private func write(_ arguments: [String], stdin: Data? = nil) throws -> String {
        let root = try validate()
        do {
            return try GitProcess.capture(arguments: arguments, stdin: stdin, in: root)
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
    public func stashPush(message: String, includeUntracked: Bool, paths: [String] = []) throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-m", trimmed] }
        if !paths.isEmpty { arguments += ["--"] + paths }
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
        let root = try validate()
        let state = try workingState()
        guard let branch = state.branch else { return nil }

        let remotesOutput = (try? GitProcess.capture(arguments: ["remote"], in: root)) ?? ""
        let remotes = remotesOutput.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !remotes.isEmpty else { return nil }

        let remote = Self.resolvePushRemote(branch: branch, upstream: state.upstream,
                                              remotes: remotes, in: root)
        let rangeArgs: [String]
        if let upstream = state.upstream {
            rangeArgs = ["\(upstream)..HEAD"]
        } else if Self.hasRemoteTrackingRefs(prefix: "refs/remotes/\(remote)", in: root) {
            rangeArgs = ["HEAD", "--not", "--remotes=\(remote)"]
        } else if Self.hasRemoteTrackingRefs(prefix: "refs/remotes", in: root) {
            rangeArgs = ["HEAD", "--not", "--remotes"]
        } else {
            rangeArgs = ["HEAD"]
        }

        let output = (try? GitProcess.capture(
            arguments: ["log", "--max-count=\(limit)", "--pretty=format:%H%x1f%aN%x1f%aI%x1f%s"] + rangeArgs,
            in: root)) ?? ""
        return PushPlan(remote: remote, branch: branch,
                        commits: CodeSearchParser.parseCommitHeaders(output),
                        hasUpstream: state.upstream != nil)
    }

    private static func resolvePushRemote(branch: String, upstream: String?,
                                          remotes: [String], in root: URL) -> String {
        if let upstream, let slash = upstream.firstIndex(of: "/") {
            let prefix = String(upstream[..<slash])
            if remotes.contains(prefix) { return prefix }
        }
        for key in ["branch.\(branch).pushRemote", "remote.pushDefault", "branch.\(branch).remote"] {
            if let value = try? GitProcess.capture(arguments: ["config", "--get", key], in: root) {
                let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if remotes.contains(candidate) { return candidate }
            }
        }
        if remotes.contains("origin") { return "origin" }
        return remotes[0]
    }

    private static func hasRemoteTrackingRefs(prefix: String, in root: URL) -> Bool {
        let output = (try? GitProcess.capture(
            arguments: ["for-each-ref", "--count=1", prefix], in: root)) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Publishes commits. Never forced: a rejected push means the remote has work this
    /// checkout has not seen, and the answer to that is to pull, not to overwrite it.
    public func push(remote: String, branch: String, setUpstream: Bool) throws {
        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        arguments += [remote, branch]
        try write(arguments)
    }

    // MARK: - Sync & Branches

    /// Fetches all remotes (and prunes deleted remote-tracking refs by default).
    public func fetch(prune: Bool = true) throws {
        var arguments = ["fetch", "--all"]
        if prune { arguments.append("--prune") }
        try write(arguments)
    }

    /// Fast-forwards the current branch from its configured upstream. Never auto-merges or rebases.
    public func pullFastForwardOnly() throws {
        try write(["pull", "--ff-only"])
    }

    /// Switches to a local branch, or creates a tracking branch when `isRemote` is true.
    public func checkoutBranch(_ name: String, isRemote: Bool = false) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "switch", message: "Branch name cannot be empty.")
        }
        if isRemote {
            try write(["switch", "--track", trimmed])
        } else {
            try write(["switch", trimmed])
        }
    }

    /// Creates a branch, optionally from a start point, and switches to it by default.
    public func createBranch(name: String, startPoint: String? = nil, checkout: Bool = true) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "switch", message: "Branch name cannot be empty.")
        }
        var arguments = checkout ? ["switch", "-c", trimmed] : ["branch", trimmed]
        if let start = startPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !start.isEmpty {
            arguments.append(start)
        }
        try write(arguments)
    }

    /// Deletes a merged local branch (`-d`). Unmerged branches are refused by git itself.
    public func deleteMergedBranch(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "branch", message: "Branch name cannot be empty.")
        }
        try write(["branch", "-d", trimmed])
    }

    // MARK: - Per-hunk patching

    /// Applies a unified diff patch to the index (`cached: true`) or working tree (`cached: false`).
    public func applyPatch(_ patch: String, cached: Bool, reverse: Bool = false, unidiffZero: Bool = false) throws {
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var arguments = ["apply", "--recount"]
        if unidiffZero { arguments.append("--unidiff-zero") }
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        let normalized = patch.hasSuffix("\n") ? patch : patch + "\n"
        try write(arguments, stdin: Data(normalized.utf8))
    }

    // MARK: - Conflict Inspection & Safe Operation Abort

    /// Index stage contents and working-tree conflict line for a conflicted path.
    public struct ConflictFileVersions: Sendable, Hashable {
        public let path: String
        public let base: String?
        public let ours: String?
        public let theirs: String?
        public let firstConflictLine: Int?

        public init(path: String, base: String?, ours: String?, theirs: String?, firstConflictLine: Int?) {
            self.path = path
            self.base = base
            self.ours = ours
            self.theirs = theirs
            self.firstConflictLine = firstConflictLine
        }
    }

    /// Reads `:1:` (base), `:2:` (ours), and `:3:` (theirs) stages for `path`, plus the first `<<<<<<<` line.
    public func conflictVersions(path: String) throws -> ConflictFileVersions {
        let root = try validate()
        let base = try? GitProcess.capture(arguments: ["show", ":1:\(path)"], in: root)
        let ours = try? GitProcess.capture(arguments: ["show", ":2:\(path)"], in: root)
        let theirs = try? GitProcess.capture(arguments: ["show", ":3:\(path)"], in: root)

        var conflictLine: Int?
        let fileURL = root.appendingPathComponent(path)
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let idx = lines.firstIndex(where: { $0.hasPrefix("<<<<<<<") }) {
                conflictLine = idx + 1
            }
        }
        return ConflictFileVersions(
            path: path,
            base: base,
            ours: ours,
            theirs: theirs,
            firstConflictLine: conflictLine
        )
    }

    /// Safely aborts an interrupted merge, rebase, cherry-pick, revert, or bisect session.
    public func abortOperation(_ operation: WorkingState.Operation) throws {
        switch operation {
        case .merge:      try write(["merge", "--abort"])
        case .rebase:     try write(["rebase", "--abort"])
        case .cherryPick: try write(["cherry-pick", "--abort"])
        case .revert:     try write(["revert", "--abort"])
        case .bisect:     try write(["bisect", "reset"])
        }
    }

    /// Resolves a conflicted path by accepting either ours (`:2:`) or theirs (`:3:`) and updating the index.
    public func resolveConflictUsingSide(path: String, acceptOurs: Bool) throws {
        let root = try validate()
        let indexStage = acceptOurs ? 2 : 3
        let hasStage = (try? GitProcess.capture(
            arguments: ["cat-file", "-e", ":\(indexStage):\(path)"], in: root
        )) != nil

        if hasStage {
            try write(["checkout", acceptOurs ? "--ours" : "--theirs", "--", path])
            try stage(paths: [path])
        } else {
            try write(["rm", "-f", "--", path])
        }
    }

    // MARK: - Tags

    /// Creates a lightweight or annotated tag (annotated when `message` is non-empty).
    public func createTag(name: String, target: String = "HEAD", message: String? = nil) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw GitWriteError(command: "tag", message: "Tag name cannot be empty.")
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let refTarget = trimmedTarget.isEmpty ? "HEAD" : trimmedTarget
        if let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            try write(["tag", "-a", trimmedName, "-m", msg, refTarget])
        } else {
            try write(["tag", trimmedName, refTarget])
        }
    }

    /// Deletes a local tag (`git tag -d`). Does not delete remote tags.
    public func deleteTag(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "tag", message: "Tag name cannot be empty.")
        }
        try write(["tag", "-d", trimmed])
    }

    /// Pushes an existing local tag ref to `remote`.
    public func pushTag(remote: String = "origin", name: String) throws {
        let trimmedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemote.isEmpty, !trimmedName.isEmpty else {
            throw GitWriteError(command: "push", message: "Remote and tag name cannot be empty.")
        }
        try write(["push", trimmedRemote, "refs/tags/\(trimmedName)"])
    }
}
