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

    /// Metadata about HEAD used to safely gate Undo Last Commit and Amend actions.
    public struct HeadCommitInfo: Sendable, Hashable {
        public let sha: String
        public let subject: String
        public let body: String
        public let hasParent: Bool
        public let isPushedToUpstream: Bool
    }

    public func headCommitInfo() throws -> HeadCommitInfo? {
        let root = try validate()
        guard let output = try? GitProcess.capture(
            arguments: ["log", "-1", "--format=%H%x1f%P%x1f%s%x1f%b", "HEAD"],
            in: root
        ) else {
            return nil
        }
        let parts = output.components(separatedBy: "\u{1f}")
        guard parts.count >= 4 else { return nil }
        let sha = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { return nil }
        let parents = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
        let subject = parts[2].trimmingCharacters(in: .newlines)
        let body = parts[3...].joined(separator: "\u{1f}").trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamSHA = (try? GitProcess.capture(
            arguments: ["rev-parse", "--verify", "--quiet", "@{upstream}"],
            in: root
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPushed: Bool
        if let upstreamSHA, !upstreamSHA.isEmpty {
            isPushed = isAncestor(sha, of: upstreamSHA)
        } else {
            isPushed = false
        }
        return HeadCommitInfo(
            sha: sha,
            subject: subject,
            body: body,
            hasParent: !parents.isEmpty,
            isPushedToUpstream: isPushed
        )
    }

    /// Moves HEAD back one commit while keeping staged changes intact (`git reset --soft HEAD~1`).
    public func undoLastCommitSoft() throws {
        guard let info = try headCommitInfo() else {
            throw GitWriteError(command: "reset", message: "Repository has no commits yet.")
        }
        guard info.hasParent else {
            throw GitWriteError(command: "reset", message: "Cannot undo the initial commit.")
        }
        guard !info.isPushedToUpstream else {
            throw GitWriteError(command: "reset", message: "The latest commit is already pushed to its remote branch.")
        }
        try write(["reset", "--soft", "HEAD~1"])
    }

    /// Amends HEAD with staged changes and an updated commit message.
    public func amendCommit(subject: String, body: String = "", allowPublished: Bool = false) throws -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "commit --amend", message: "A commit needs a message.")
        }
        guard let info = try headCommitInfo() else {
            throw GitWriteError(command: "commit --amend", message: "Repository has no commits to amend.")
        }
        if info.isPushedToUpstream && !allowPublished {
            throw GitWriteError(
                command: "commit --amend",
                message: "The latest commit is already pushed to its upstream branch."
            )
        }
        var arguments = ["commit", "--amend", "-m", trimmed]
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

    /// Discards all unstaged edits across tracked working-tree files (`git restore --worktree -- .`).
    public func discardAllChanges() throws {
        try write(["restore", "--worktree", "--", "."])
    }

    /// Appends unique patterns to the repository's `.gitignore` file.
    public func appendToGitignore(patterns: [String]) throws {
        let root = try validate()
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let gitignoreURL = root.appendingPathComponent(".gitignore")
        let existingText = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        var existingLines = Set(
            existingText
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
        )
        var additions: [String] = []
        for pattern in cleaned where !existingLines.contains(pattern) {
            existingLines.insert(pattern)
            additions.append(pattern)
        }
        guard !additions.isEmpty else { return }

        var updated = existingText
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += additions.joined(separator: "\n") + "\n"
        try updated.write(to: gitignoreURL, atomically: true, encoding: .utf8)
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

    public func pullRebase() throws {
        try write(["-c", "core.editor=true", "pull", "--rebase"])
    }

    public func pullMerge() throws {
        try write(["-c", "core.editor=true", "pull", "--no-rebase", "--no-edit"])
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

    /// Renames a local branch (`git branch -m <old> <new>`).
    public func renameBranch(from oldName: String, to newName: String) throws {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else {
            throw GitWriteError(command: "branch", message: "Branch names cannot be empty.")
        }
        try write(["branch", "-m", oldTrimmed, newTrimmed])
    }

    /// Deletes a merged local branch (`-d`). Unmerged branches are refused by git itself.
    public func deleteMergedBranch(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "branch", message: "Branch name cannot be empty.")
        }
        try write(["branch", "-d", trimmed])
    }

    /// Force-deletes a local branch (`-D`).
    public func deleteBranchForce(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "branch", message: "Branch name cannot be empty.")
        }
        try write(["branch", "-D", trimmed])
    }

    /// Merges `name` into the currently checked out branch.
    public func mergeBranch(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "merge", message: "Branch name cannot be empty.")
        }
        try write(["-c", "core.editor=true", "merge", "--no-edit", trimmed])
    }

    /// Rebases the currently checked out branch onto `target`.
    public func rebaseOnto(_ target: String) throws {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "rebase", message: "Target branch cannot be empty.")
        }
        try write(["-c", "core.editor=true", "rebase", trimmed])
    }

    /// Applies a single commit onto HEAD (`git cherry-pick <sha>`).
    public func cherryPick(sha: String) throws {
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "cherry-pick", message: "Commit hash cannot be empty.")
        }
        try write(["cherry-pick", trimmed])
    }

    /// Creates a new commit that reverses the edits introduced by `sha`.
    public func revertCommit(sha: String) throws {
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "revert", message: "Commit hash cannot be empty.")
        }
        try write(["-c", "core.editor=true", "revert", "--no-edit", trimmed])
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

    /// Continues a merge, rebase, cherry-pick, or revert once conflicts have been staged.
    public func continueOperation(_ operation: WorkingState.Operation) throws {
        switch operation {
        case .merge:      try write(["-c", "core.editor=true", "merge", "--continue"])
        case .rebase:     try write(["-c", "core.editor=true", "rebase", "--continue"])
        case .cherryPick: try write(["-c", "core.editor=true", "cherry-pick", "--continue"])
        case .revert:     try write(["-c", "core.editor=true", "revert", "--continue"])
        case .bisect:
            throw GitWriteError(command: "bisect", message: "Continue is not applicable to bisect.")
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

    /// Parses conflict marker blocks in `path`.
    public func conflictBlocks(path: String) throws -> [ConflictBlock] {
        let root = try validate()
        let fileURL = root.appendingPathComponent(path)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return ConflictMarkerResolver.parseBlocks(in: text)
    }

    /// Resolves a single conflict block in `path`, automatically staging the file when zero blocks remain.
    @discardableResult
    public func resolveConflictBlock(path: String, blockIndex: Int, choice: ConflictBlockChoice) throws -> Int {
        let root = try validate()
        let fileURL = root.appendingPathComponent(path)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let resolved = ConflictMarkerResolver.resolving(text: text, blockIndex: blockIndex, choice: choice) else {
            throw GitWriteError(command: "resolve conflict", message: "Conflict block \(blockIndex + 1) was not found.")
        }
        try resolved.write(to: fileURL, atomically: true, encoding: .utf8)
        let remaining = ConflictMarkerResolver.parseBlocks(in: resolved).count
        if remaining == 0 {
            try stage(paths: [path])
        }
        return remaining
    }

    // MARK: - Creating Repositories

    /// Initializes a new git repository at `directory` and returns its validated root URL.
    public static func initRepository(at directory: URL, initialBranch: String = "main") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let branch = initialBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["init", "-q"]
        if !branch.isEmpty {
            arguments += ["-b", branch]
        }
        do {
            try GitProcess.capture(arguments: arguments, in: directory)
        } catch let GitError.failed(command, _, stderr) {
            throw GitWriteError(command: command,
                                message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try GitRepository(url: directory).validate()
    }

    /// Clones `remoteURL` into `destination` and returns its validated repository root URL.
    public static func clone(remoteURL: String, into destination: URL) async throws -> URL {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "clone", message: "Repository URL cannot be empty.")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try await GitProcess.captureAsync(arguments: ["clone", trimmed, destination.path], in: parent)
        } catch let GitError.failed(command, _, stderr) {
            throw GitWriteError(command: command,
                                message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try GitRepository(url: destination).validate()
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

    // MARK: - Recovery, Worktrees & Remotes

    /// Moves HEAD softly to `rev` (`git reset --soft`), keeping index and working tree intact.
    public func resetSoft(to rev: String) throws {
        let trimmed = rev.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "reset --soft", message: "Target revision cannot be empty.")
        }
        try write(["reset", "--soft", trimmed])
    }

    /// Creates a new linked worktree at `path`.
    public func addWorktree(path: URL, branch: String, createBranch: Bool, startPoint: String? = nil) throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw GitWriteError(command: "worktree add", message: "Branch name cannot be empty.")
        }
        var args = ["worktree", "add"]
        if createBranch {
            args += ["-b", trimmedBranch, path.path]
            if let startPoint {
                let trimmedStart = startPoint.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedStart.isEmpty { args.append(trimmedStart) }
            }
        } else {
            args += [path.path, trimmedBranch]
        }
        try write(args)
    }

    /// Removes a linked worktree (`git worktree remove`).
    public func removeWorktree(path: String, force: Bool = false) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitWriteError(command: "worktree remove", message: "Worktree path cannot be empty.")
        }
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(trimmed)
        try write(args)
    }

    /// Cleans stale administrative files for deleted worktrees (`git worktree prune`).
    public func pruneWorktrees() throws {
        try write(["worktree", "prune"])
    }

    public func addRemote(name: String, url: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            throw GitWriteError(command: "remote add", message: "Remote name and URL cannot be empty.")
        }
        try write(["remote", "add", trimmedName, trimmedURL])
    }

    public func setRemoteURL(name: String, url: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            throw GitWriteError(command: "remote set-url", message: "Remote name and URL cannot be empty.")
        }
        try write(["remote", "set-url", trimmedName, trimmedURL])
    }

    public func renameRemote(from oldName: String, to newName: String) throws {
        let trimmedOld = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOld.isEmpty, !trimmedNew.isEmpty else {
            throw GitWriteError(command: "remote rename", message: "Remote names cannot be empty.")
        }
        try write(["remote", "rename", trimmedOld, trimmedNew])
    }

    public func removeRemote(name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw GitWriteError(command: "remote remove", message: "Remote name cannot be empty.")
        }
        try write(["remote", "remove", trimmedName])
    }
}

public enum ConflictBlockChoice: Sendable, Hashable {
    case ours, theirs, both
}

public struct ConflictBlock: Identifiable, Hashable, Sendable {
    public let id: Int
    public let startLine: Int
    public let oursLabel: String
    public let theirsLabel: String
    public let oursText: String
    public let theirsText: String
}

/// Pure parser & resolver for standard and diff3 (`|||||||`) git conflict markers.
public enum ConflictMarkerResolver {
    private struct ParsedBlock {
        let startIndex: Int
        let endIndex: Int
        let oursLabel: String
        let theirsLabel: String
        let oursLines: [String]
        let theirsLines: [String]
    }

    public static func parseBlocks(in text: String) -> [ConflictBlock] {
        let lines = splitLines(text)
        return parse(lines: lines).enumerated().map { idx, block in
            ConflictBlock(
                id: idx,
                startLine: block.startIndex + 1,
                oursLabel: block.oursLabel,
                theirsLabel: block.theirsLabel,
                oursText: block.oursLines.joined(separator: "\n"),
                theirsText: block.theirsLines.joined(separator: "\n")
            )
        }
    }

    public static func resolving(text: String, blockIndex: Int, choice: ConflictBlockChoice) -> String? {
        var lines = splitLines(text)
        let blocks = parse(lines: lines)
        guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
        let block = blocks[blockIndex]

        let replacement: [String]
        switch choice {
        case .ours:   replacement = block.oursLines
        case .theirs: replacement = block.theirsLines
        case .both:   replacement = block.oursLines + block.theirsLines
        }
        lines.replaceSubrange(block.startIndex...block.endIndex, with: replacement)
        return lines.joined(separator: "\n")
    }

    private static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            raw.last == "\r" ? String(raw.dropLast()) : String(raw)
        }
    }

    private static func parse(lines: [String]) -> [ParsedBlock] {
        var blocks: [ParsedBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix("<<<<<<<") else {
                i += 1
                continue
            }
            let startIndex = i
            let oursLabel = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            var oursLines: [String] = []
            var theirsLines: [String] = []
            var inBase = false
            var inTheirs = false
            var endIndex: Int?
            var theirsLabel = ""

            var j = i + 1
            while j < lines.count {
                let current = lines[j]
                if !inTheirs && current.hasPrefix("|||||||") {
                    inBase = true
                } else if !inTheirs && current.hasPrefix("=======") {
                    inBase = false
                    inTheirs = true
                } else if inTheirs && current.hasPrefix(">>>>>>>") {
                    theirsLabel = current.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    endIndex = j
                    break
                } else if inTheirs {
                    theirsLines.append(current)
                } else if !inBase {
                    oursLines.append(current)
                }
                j += 1
            }

            if let endIndex {
                blocks.append(ParsedBlock(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    oursLabel: oursLabel,
                    theirsLabel: theirsLabel,
                    oursLines: oursLines,
                    theirsLines: theirsLines
                ))
                i = endIndex + 1
            } else {
                i += 1
            }
        }
        return blocks
    }
}
