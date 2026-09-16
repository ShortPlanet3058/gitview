import Foundation

/// What is going on in the checkout right now — the `git status` question, which is the
/// one a developer asks many times a day and which committed history cannot answer.
public struct WorkingState: Hashable, Sendable {
    public enum Change: String, Hashable, Sendable {
        case unchanged, added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted
    }

    public struct FileStatus: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let path: String
        /// Set when git detected a rename.
        public let originalPath: String?
        /// What is different between HEAD and the index.
        public let staged: Change
        /// What is different between the index and the working tree.
        public let unstaged: Change

        public var isUntracked: Bool { unstaged == .untracked }
        public var isConflicted: Bool { staged == .conflicted || unstaged == .conflicted }
    }

    public struct Stash: Identifiable, Hashable, Sendable {
        public var id: String { ref }
        public let ref: String
        public let message: String
        public let date: Date
    }

    /// Something half-finished that git is waiting on. Worth surfacing loudly: it is easy
    /// to walk away from a conflicted merge and forget.
    public enum Operation: String, Hashable, Sendable {
        case merge, rebase, cherryPick, revert, bisect

        public var label: String {
            switch self {
            case .merge: return "Merge in progress"
            case .rebase: return "Rebase in progress"
            case .cherryPick: return "Cherry-pick in progress"
            case .revert: return "Revert in progress"
            case .bisect: return "Bisect in progress"
            }
        }
    }

    public let branch: String?
    public let headSHA: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [FileStatus]
    public let stashes: [Stash]
    public let operation: Operation?

    public var isDetached: Bool { branch == nil }
    public var staged: [FileStatus] { files.filter { $0.staged != .unchanged && !$0.isUntracked && !$0.isConflicted } }
    public var unstaged: [FileStatus] { files.filter { $0.unstaged != .unchanged && !$0.isUntracked && !$0.isConflicted } }
    public var untracked: [FileStatus] { files.filter(\.isUntracked) }
    public var conflicted: [FileStatus] { files.filter(\.isConflicted) }
    public var isClean: Bool { files.isEmpty && operation == nil }
    /// Work that exists only on this machine — the thing people most often forget.
    public var hasUnpushedCommits: Bool { ahead > 0 }
    public var hasLocalWork: Bool { !isClean || hasUnpushedCommits || !stashes.isEmpty }

    public static let clean = WorkingState(branch: nil, headSHA: nil, upstream: nil, ahead: 0, behind: 0,
                                           files: [], stashes: [], operation: nil)
}

/// Parses `git status --porcelain=v2 --branch -z`.
///
/// Version 2 of the format, not v1: it reports the branch, its upstream and the
/// ahead/behind counts in the same call, and separates staged from unstaged state
/// unambiguously. `-z` is what makes paths with spaces or newlines safe — the fixtures in
/// the tests are real output, not hand-written.
public enum WorkingStateParser {
    public static func parse(porcelain: String, stashList: String, operation: WorkingState.Operation?) -> WorkingState {
        var branch: String?
        var head: String?
        var upstream: String?
        var ahead = 0, behind = 0
        var files: [WorkingState.FileStatus] = []

        // Records are NUL-terminated; a rename record is followed by a second NUL-terminated
        // field holding the original path.
        var records = porcelain.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let marker = record.first else { continue }

            switch marker {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { continue }
                switch parts[1] {
                case "branch.oid": head = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": upstream = parts[2]
                case "branch.ab":
                    // "+3 -1"
                    for token in parts[2].split(separator: " ") {
                        let value = Int(token.dropFirst()) ?? 0
                        if token.hasPrefix("+") { ahead = value } else if token.hasPrefix("-") { behind = value }
                    }
                default: break
                }

            case "1":
                let parts = record.split(separator: " ", maxSplits: 8).map(String.init)
                guard parts.count == 9 else { continue }
                let (staged, unstaged) = changes(from: parts[1])
                files.append(.init(path: parts[8], originalPath: nil, staged: staged, unstaged: unstaged))

            case "2":
                let parts = record.split(separator: " ", maxSplits: 9).map(String.init)
                guard parts.count == 10 else { continue }
                // The original path is the next record, not a field of this one.
                let original = index < records.count ? records[index] : nil
                if original != nil { index += 1 }
                let (staged, unstaged) = changes(from: parts[1])
                files.append(.init(path: parts[9], originalPath: original, staged: staged, unstaged: unstaged))

            case "u":
                let parts = record.split(separator: " ", maxSplits: 10).map(String.init)
                guard parts.count == 11 else { continue }
                files.append(.init(path: parts[10], originalPath: nil, staged: .conflicted, unstaged: .conflicted))

            case "?":
                files.append(.init(path: String(record.dropFirst(2)), originalPath: nil,
                                   staged: .unchanged, unstaged: .untracked))

            default:
                break   // "!" ignored entries; we do not ask for them
            }
        }

        return WorkingState(branch: branch, headSHA: head, upstream: upstream,
                            ahead: ahead, behind: behind,
                            files: files.sorted { $0.path < $1.path },
                            stashes: parseStashes(stashList), operation: operation)
    }

    /// `XY`: X is the staged change, Y the unstaged one, `.` meaning unchanged.
    private static func changes(from code: String) -> (WorkingState.Change, WorkingState.Change) {
        let characters = Array(code)
        guard characters.count == 2 else { return (.unchanged, .unchanged) }
        return (change(characters[0]), change(characters[1]))
    }

    private static func change(_ character: Character) -> WorkingState.Change {
        switch character {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return .unchanged
        }
    }

    /// `%gd%x1f%gs%x1f%ct` per line.
    static func parseStashes(_ list: String) -> [WorkingState.Stash] {
        list.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let seconds = TimeInterval(fields[2]) else { return nil }
            return WorkingState.Stash(ref: fields[0], message: fields[1],
                                      date: Date(timeIntervalSince1970: seconds))
        }
    }
}

extension GitRepository {
    /// Reads the current checkout state. Cheap — a handful of instant commands — so it is
    /// refreshed on every look rather than cached.
    public func workingState() throws -> WorkingState {
        let root = try validate()
        let porcelain = try GitProcess.capture(
            arguments: ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"], in: root)
        let stashes = (try? GitProcess.capture(
            arguments: ["stash", "list", "--format=%gd%x1f%gs%x1f%ct"], in: root)) ?? ""
        return WorkingStateParser.parse(porcelain: porcelain, stashList: stashes,
                                        operation: Self.operation(in: root))
    }

    /// Detects a half-finished operation from the marker files git leaves in `.git`.
    static func operation(in root: URL) -> WorkingState.Operation? {
        let gitDir = (try? GitProcess.capture(arguments: ["rev-parse", "--absolute-git-dir"], in: root))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gitDir, !gitDir.isEmpty else { return nil }
        let base = URL(fileURLWithPath: gitDir)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("MERGE_HEAD") { return .merge }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }
}
