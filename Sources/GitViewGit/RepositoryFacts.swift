import Foundation
import GitViewCore

public struct BranchInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let sha: String
    public let date: Date
    public let author: String
    public let subject: String
    public let isDefault: Bool
    public let isCurrent: Bool
    /// True for a remote-tracking branch with no local counterpart (`origin/feature` or `upstream/main`).
    public let isRemote: Bool
    /// Remote name for remote-tracking branches (for example `origin` or `upstream`).
    public let remoteName: String?
    /// Commits on this branch that the default branch does not have. Nil when not computed.
    public let ahead: Int?
    /// Commits on the default branch that this branch does not have. Nil when not computed.
    public let behind: Int?
    public let isMerged: Bool

    public init(name: String, sha: String, date: Date, author: String, subject: String,
                isDefault: Bool, isCurrent: Bool, isRemote: Bool, remoteName: String? = nil,
                ahead: Int?, behind: Int?, isMerged: Bool) {
        self.name = name
        self.sha = sha
        self.date = date
        self.author = author
        self.subject = subject
        self.isDefault = isDefault
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.ahead = ahead
        self.behind = behind
        self.isMerged = isMerged
    }

    /// Full target ref accepted by `git switch --track` (for remote branches) or `git switch`.
    public var checkoutTarget: String {
        guard isRemote else { return name }
        if let remoteName, !remoteName.isEmpty {
            return name.hasPrefix("\(remoteName)/") ? name : "\(remoteName)/\(name)"
        }
        return name.contains("/") ? name : "origin/\(name)"
    }
}

public struct WorktreeInfo: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let headSHA: String
    public let branch: String?
    public let isCurrent: Bool

    public init(path: String, headSHA: String, branch: String?, isCurrent: Bool) {
        self.path = path
        self.headSHA = headSHA
        self.branch = branch
        self.isCurrent = isCurrent
    }
}

/// What is in the working tree, counted over *tracked* files only so build products and
/// dependencies do not inflate the numbers.
/// One language's share of the tracked files.
public struct LanguageShare: Hashable, Sendable, Identifiable {
    public var id: String { language.name }
    public let language: KnownLanguage
    public let bytes: Int64
    public let files: Int
}

public struct FileInventory: Hashable, Sendable {
    public struct LargeFile: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let bytes: Int64
    }
    public static let largeFileThreshold: Int64 = 10 * 1024 * 1024

    public struct TrackedFile: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let bytes: Int64
        public let modified: Date?
    }

    public let fileCount: Int
    public let totalBytes: Int64
    /// Every tracked file, in `git ls-files` order.
    public let files: [TrackedFile]
    /// "Source code", "Assets", "Documents", "Other" — by extension.
    public let bytesByCategory: [String: Int64]
    /// Bytes and file counts per recognised language, the way GitHub's language bar works.
    public let bytesByLanguage: [String: Int64]
    public let filesByLanguage: [String: Int]
    /// Languages present, largest first, with their Linguist colour.
    public let languages: [LanguageShare]
    public let largeFiles: [LargeFile]
    public let lastModified: Date?

    public static let categories = ["Source code", "Assets", "Documents", "Other"]

    static func category(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "cxx", "py", "js", "ts", "tsx", "jsx", "java",
             "kt", "kts", "rb", "go", "rs", "sh", "zsh", "bash", "php", "cs", "scala", "sql", "pl", "lua", "dart",
             "r", "metal", "s", "asm", "cmake", "gradle", "make", "mk", "gyp", "gn":
            return "Source code"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf", "ico", "icns", "heic", "webp", "mp3", "mp4", "mov",
             "wav", "aiff", "ttf", "otf", "woff", "woff2", "zip", "gz", "tar", "jar", "bin", "car", "sketch",
             "fig", "psd", "ai":
            return "Assets"
        case "md", "markdown", "txt", "rst", "adoc", "html", "htm", "json", "yaml", "yml", "toml", "xml",
             "plist", "csv", "tsv", "strings", "stringsdict", "xcstrings", "rtf", "tex":
            return "Documents"
        default:
            return "Other"
        }
    }
}

public struct RepositoryInfo: Hashable, Sendable {
    public let root: URL
    public let currentBranch: String
    public let defaultBranch: String
    public let remoteURL: String?
    /// Browser URL derived from the remote, when the remote looks like a hosted repository.
    public let remoteWebURL: URL?
    /// Size of the object store (loose + packed), i.e. the "git history" weight.
    public let packedBytes: Int64?
    /// First paragraph of the README, when there is one.
    public let readmeSummary: String?
    /// `user.name` from git config, used to recognise "your" commits. Empty when unset.
    public let configuredUserNames: Set<String>
    /// `user.email` from git config (lowercased), used alongside names for identity matching.
    public let configuredUserEmails: Set<String>
    public let remotes: [String: String]
    public let worktrees: [WorktreeInfo]
    public let unreleased: UnreleasedSummary?
    public let inventory: FileInventory

    public init(
        root: URL,
        currentBranch: String,
        defaultBranch: String,
        remoteURL: String?,
        remoteWebURL: URL?,
        packedBytes: Int64?,
        readmeSummary: String?,
        configuredUserNames: Set<String>,
        configuredUserEmails: Set<String> = [],
        remotes: [String: String] = [:],
        worktrees: [WorktreeInfo] = [],
        unreleased: UnreleasedSummary?,
        inventory: FileInventory
    ) {
        self.root = root
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.remoteURL = remoteURL
        self.remoteWebURL = remoteWebURL
        self.packedBytes = packedBytes
        self.readmeSummary = readmeSummary
        self.configuredUserNames = configuredUserNames
        self.configuredUserEmails = configuredUserEmails
        self.remotes = remotes
        self.worktrees = worktrees
        self.unreleased = unreleased
        self.inventory = inventory
    }
}

extension GitRepository {

    public func info() throws -> RepositoryInfo {
        let root = try validate()
        let box = InfoGatherBox()

        DispatchQueue.concurrentPerform(iterations: 7) { taskIndex in
            switch taskIndex {
            case 0:
                if let current = try? GitProcess.capture(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], in: root) {
                    box.setCurrent(current.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case 1:
                if let rawConfig = try? GitProcess.capture(arguments: ["config", "--list"], in: root) {
                    box.setConfig(Self.parseConfigList(rawConfig))
                }
            case 2:
                box.setDefaultBranchCandidate(Self.defaultBranchCandidate(in: root))
            case 3:
                box.setPackedBytes(Self.objectStoreBytes(in: root))
            case 4:
                box.setUnreleased(GitRepository(url: root).unreleasedSummary())
            case 5:
                box.setInventory(Self.inventory(in: root))
            case 6:
                if let rawWorktrees = try? GitProcess.capture(arguments: ["worktree", "list", "--porcelain"], in: root) {
                    box.setWorktrees(Self.parseWorktrees(rawWorktrees, currentRoot: root))
                }
            default:
                break
            }
        }

        let current = box.current ?? "HEAD"
        let defaultBranch = box.defaultBranchCandidate ?? current
        let remote = box.remotes["origin"]
            ?? box.remotes["upstream"]
            ?? box.remotes.sorted(by: { $0.key < $1.key }).first?.value

        return RepositoryInfo(
            root: root,
            currentBranch: current,
            defaultBranch: defaultBranch,
            remoteURL: remote.flatMap { $0.isEmpty ? nil : $0 },
            remoteWebURL: remote.flatMap(Self.webURL(fromRemote:)),
            packedBytes: box.packedBytes,
            readmeSummary: Self.readmeSummary(in: root),
            configuredUserNames: box.userNames,
            configuredUserEmails: box.userEmails,
            remotes: box.remotes,
            worktrees: box.worktrees,
            unreleased: box.unreleased,
            inventory: box.inventory ?? FileInventory(
                fileCount: 0, totalBytes: 0, files: [], bytesByCategory: [:],
                bytesByLanguage: [:], filesByLanguage: [:], languages: [],
                largeFiles: [], lastModified: nil
            )
        )
    }

    public func branches(defaultBranch: String, currentBranch: String, detailLimit: Int = 60) throws -> [BranchInfo] {
        try branches(
            defaultBranch: defaultBranch,
            currentBranch: currentBranch,
            detailLimit: detailLimit,
            cachedDivergence: [:]
        ).branches
    }

    /// Local branches plus remote-tracking branches across all configured remotes (`origin` and others
    /// such as `upstream`), newest commit first, reusing cached `(baseSHA, tipSHA)` ahead/behind counts.
    public func branches(
        defaultBranch: String,
        currentBranch: String,
        detailLimit: Int = 60,
        cachedDivergence: [AnalysisCache.DivergencePair: (behind: Int, ahead: Int)]
    ) throws -> (branches: [BranchInfo], computedDivergence: [AnalysisCache.DivergencePair: (behind: Int, ahead: Int)]) {
        let root = try validate()
        let format = "%(refname)%1f%(objectname)%1f%(committerdate:iso-strict)%1f%(authorname:mailmap)%1f%(subject)"
        let output = try GitProcess.capture(
            arguments: ["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"],
            in: root)
        let merged = Set((try? GitProcess.capture(
            arguments: ["branch", "-a", "--merged", defaultBranch, "--format=%(refname:short)"], in: root))?
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) } ?? [])

        let rows = Self.parseBranchRows(output)
        let baseSHA = rows.first(where: { !$0.isRemote && $0.name == defaultBranch })?.sha
            ?? rows.first(where: { $0.name == "origin/\(defaultBranch)" || ($0.isRemote && $0.name == defaultBranch) })?.sha

        let box = AheadBehindBox(count: rows.count)
        let limit = min(rows.count, detailLimit)
        var misses: [Int] = []
        misses.reserveCapacity(limit)

        for index in 0..<limit {
            let row = rows[index]
            if row.name == defaultBranch && !row.isRemote { continue }
            if let baseSHA {
                if row.sha == baseSHA {
                    box.set(index, behind: 0, ahead: 0)
                    continue
                }
                let key = AnalysisCache.DivergencePair(baseSHA: baseSHA, tipSHA: row.sha)
                if let cached = cachedDivergence[key] {
                    box.set(index, behind: cached.behind, ahead: cached.ahead)
                    continue
                }
            }
            misses.append(index)
        }

        let missSnapshot = misses
        if !missSnapshot.isEmpty {
            DispatchQueue.concurrentPerform(iterations: missSnapshot.count) { missOffset in
                let index = missSnapshot[missOffset]
                let row = rows[index]
                guard let output = try? GitProcess.capture(
                    arguments: ["rev-list", "--left-right", "--count", "\(defaultBranch)...\(row.fullName)"],
                    in: root) else { return }
                let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
                if parts.count == 2 {
                    box.set(index, behind: parts[0], ahead: parts[1], computedTipSHA: row.sha)
                }
            }
        }

        var newlyComputed: [AnalysisCache.DivergencePair: (behind: Int, ahead: Int)] = [:]
        let result = rows.enumerated().map { index, row -> BranchInfo in
            let (behind, ahead, computedTip) = box.getWithComputed(index)
            if let baseSHA, let computedTip, let behind, let ahead {
                newlyComputed[AnalysisCache.DivergencePair(baseSHA: baseSHA, tipSHA: computedTip)] = (behind, ahead)
            }
            return BranchInfo(
                name: row.name,
                sha: row.sha,
                date: row.date,
                author: row.author,
                subject: row.subject,
                isDefault: row.name == defaultBranch && !row.isRemote,
                isCurrent: !row.isRemote && row.name == currentBranch,
                isRemote: row.isRemote,
                remoteName: row.remoteName,
                ahead: ahead,
                behind: behind,
                isMerged: !(row.name == defaultBranch && !row.isRemote)
                    && (merged.contains(row.name) || merged.contains(row.fullName))
            )
        }
        return (result, newlyComputed)
    }

    struct ParsedBranchRow {
        let name: String
        let fullName: String
        let remoteName: String?
        let sha: String
        let date: Date
        let author: String
        let subject: String
        let isRemote: Bool
    }

    static func parseBranchRows(_ output: String) -> [ParsedBranchRow] {
        var rawLocal: [ParsedBranchRow] = []
        var rawRemote: [ParsedBranchRow] = []
        var localNames = Set<String>()

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            let ref = fields[0]
            let date = ISO8601.parse(fields[2]) ?? .distantPast

            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                guard !name.isEmpty else { continue }
                localNames.insert(name)
                rawLocal.append(ParsedBranchRow(
                    name: name, fullName: name, remoteName: nil, sha: fields[1],
                    date: date, author: fields[3], subject: fields[4], isRemote: false
                ))
            } else if ref.hasPrefix("refs/remotes/") {
                let tail = ref.dropFirst("refs/remotes/".count)
                guard let slash = tail.firstIndex(of: "/") else { continue }
                let remote = String(tail[..<slash])
                let branch = String(tail[tail.index(after: slash)...])
                guard branch != "HEAD", !branch.isEmpty else { continue }
                let fullName = "\(remote)/\(branch)"
                let displayName = remote == "origin" ? branch : fullName
                rawRemote.append(ParsedBranchRow(
                    name: displayName, fullName: fullName, remoteName: remote, sha: fields[1],
                    date: date, author: fields[3], subject: fields[4], isRemote: true
                ))
            }
        }

        // Keep newest-first sort order while ensuring local branches suppress their `origin/` duplicate.
        var combined = rawLocal
        var seenRemoteDisplay = Set<String>()
        for row in rawRemote {
            if row.remoteName == "origin", localNames.contains(row.name) { continue }
            guard seenRemoteDisplay.insert(row.fullName).inserted else { continue }
            combined.append(row)
        }
        return combined.sorted { $0.date > $1.date }
    }

    // MARK: - Pieces

    static func defaultBranch(in root: URL, fallback: String) -> String {
        defaultBranchCandidate(in: root) ?? fallback
    }

    private static func defaultBranchCandidate(in root: URL) -> String? {
        if let ref = try? GitProcess.capture(arguments: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root) {
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = trimmed.firstIndex(of: "/") { return String(trimmed[trimmed.index(after: slash)...]) }
            if !trimmed.isEmpty { return trimmed }
        }
        if let refs = try? GitProcess.capture(
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads/main", "refs/heads/master", "refs/heads/develop"],
            in: root) {
            let available = Set(refs.split(separator: "\n").map(String.init))
            for candidate in ["main", "master", "develop"] where available.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// `git@github.com:owner/repo.git`, `ssh://git@host/owner/repo.git` and
    /// `https://host/owner/repo.git` all become `https://host/owner/repo`.
    public static func webURL(fromRemote remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("git@"), let colon = text.firstIndex(of: ":") {
            let host = text[text.index(text.startIndex, offsetBy: 4)..<colon]
            let path = text[text.index(after: colon)...]
            return URL(string: "https://\(host)/\(path)")
        }
        if let url = URL(string: text), let host = url.host {
            if url.scheme == "ssh" || url.scheme == "git" { return URL(string: "https://\(host)\(url.path)") }
            if url.scheme == "https" || url.scheme == "http" { return URL(string: "https://\(host)\(url.path)") }
        }
        return nil
    }

    struct ConfigSummary: Sendable {
        let remotes: [String: String]
        let userNames: Set<String>
        let userEmails: Set<String>
    }

    static func parseConfigList(_ output: String) -> ConfigSummary {
        var remotes: [String: String] = [:]
        var names = Set<String>()
        var emails = Set<String>()

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            if key == "user.name" {
                names.insert(value)
            } else if key == "user.email" {
                emails.insert(value.lowercased())
            } else if key.hasPrefix("remote.") && key.hasSuffix(".url") && key.count > 11 {
                let remoteName = String(key.dropFirst("remote.".count).dropLast(".url".count))
                remotes[remoteName] = value
            }
        }
        return ConfigSummary(remotes: remotes, userNames: names, userEmails: emails)
    }

    static func parseWorktrees(_ output: String, currentRoot: URL) -> [WorktreeInfo] {
        let standardizedCurrent = currentRoot.resolvingSymlinksInPath().standardizedFileURL.path
        var results: [WorktreeInfo] = []
        var path: String?
        var headSHA = ""
        var branch: String?
        var isBare = false

        func flush() {
            defer { path = nil; headSHA = ""; branch = nil; isBare = false }
            guard let path, !path.isEmpty, !isBare else { return }
            let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            results.append(WorktreeInfo(
                path: path,
                headSHA: headSHA,
                branch: branch,
                isCurrent: standardized == standardizedCurrent
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                headSHA = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let rawRef = String(line.dropFirst("branch ".count))
                branch = rawRef.hasPrefix("refs/heads/")
                    ? String(rawRef.dropFirst("refs/heads/".count))
                    : rawRef
            } else if line == "bare" {
                isBare = true
            }
        }
        flush()
        return results
    }

    static func configuredUserNames(in root: URL) -> Set<String> {
        guard let output = try? GitProcess.capture(arguments: ["config", "--list"], in: root) else { return [] }
        return parseConfigList(output).userNames
    }

    static func configuredUserEmails(in root: URL) -> Set<String> {
        guard let output = try? GitProcess.capture(arguments: ["config", "--list"], in: root) else { return [] }
        return parseConfigList(output).userEmails
    }

    static func objectStoreBytes(in root: URL) -> Int64? {
        guard let output = try? GitProcess.capture(arguments: ["count-objects", "-v"], in: root) else { return nil }
        var kib: Int64 = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2, let value = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            if parts[0] == "size" || parts[0] == "size-pack" { kib += value }
        }
        return kib * 1024
    }

    static func readmeSummary(in root: URL) -> String? {
        let names = ["README.md", "Readme.md", "readme.md", "README.markdown", "README", "README.txt"]
        guard let url = names.map({ root.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.firstParagraph(ofMarkdown: text)
    }

    /// First paragraph that is prose: skips headings, badges, images, HTML and blank lines.
    public static func firstParagraph(ofMarkdown text: String) -> String? {
        var paragraph: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let skip = line.hasPrefix("#") || line.hasPrefix("[![") || line.hasPrefix("![") || line.hasPrefix("<")
                || line.hasPrefix("---") || line.hasPrefix("|") || line.hasPrefix("```") || line.hasPrefix("- ") || line.hasPrefix("* ")
            if line.isEmpty || skip {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty else { return nil }
        var joined = paragraph.joined(separator: " ")
        // Strip simple markdown emphasis and links: [text](url) -> text.
        joined = joined.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        joined = joined.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        if joined.count > 280 { joined = String(joined.prefix(277)).trimmingCharacters(in: .whitespaces) + "…" }
        return joined
    }

    static func inventory(in root: URL) -> FileInventory {
        guard let listing = try? GitProcess.capture(arguments: ["ls-files", "-z"], in: root) else {
            return FileInventory(fileCount: 0, totalBytes: 0, files: [], bytesByCategory: [:],
                                 bytesByLanguage: [:], filesByLanguage: [:], languages: [],
                                 largeFiles: [], lastModified: nil)
        }
        var count = 0
        var total: Int64 = 0
        var byCategory: [String: Int64] = [:]
        var byLanguage: [String: Int64] = [:]
        var countByLanguage: [String: Int] = [:]
        var known: [String: KnownLanguage] = [:]
        var large: [FileInventory.LargeFile] = []
        var files: [FileInventory.TrackedFile] = []
        var newest: Date?
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for entry in listing.split(separator: "\0") where !entry.isEmpty {
            let path = String(entry)
            let url = root.appendingPathComponent(path)
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            count += 1
            total += bytes
            byCategory[FileInventory.category(forExtension: url.pathExtension), default: 0] += bytes
            if let language = LanguageCatalog.language(forPath: path) {
                byLanguage[language.name, default: 0] += bytes
                countByLanguage[language.name, default: 0] += 1
                known[language.name] = language
            }
            files.append(.init(path: path, bytes: bytes, modified: values.contentModificationDate))
            if bytes >= FileInventory.largeFileThreshold { large.append(.init(path: path, bytes: bytes)) }
            if let modified = values.contentModificationDate, newest.map({ modified > $0 }) ?? true { newest = modified }
        }
        let ranked = byLanguage
            .compactMap { name, bytes -> LanguageShare? in
                guard let language = known[name] else { return nil }
                return LanguageShare(language: language, bytes: bytes, files: countByLanguage[name] ?? 0)
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.language.name < $1.language.name }
        return FileInventory(fileCount: count, totalBytes: total, files: files, bytesByCategory: byCategory,
                             bytesByLanguage: byLanguage, filesByLanguage: countByLanguage, languages: ranked,
                             largeFiles: large.sorted { $0.bytes > $1.bytes }, lastModified: newest)
    }
}


/// Collects ahead/behind counts from concurrent workers.
private final class AheadBehindBox: @unchecked Sendable {
    private var values: [(Int?, Int?, String?)]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: (nil, nil, nil), count: count) }
    func set(_ index: Int, behind: Int, ahead: Int, computedTipSHA: String? = nil) {
        lock.lock(); values[index] = (behind, ahead, computedTipSHA); lock.unlock()
    }
    func getWithComputed(_ index: Int) -> (Int?, Int?, String?) {
        lock.lock(); defer { lock.unlock() }; return values[index]
    }
}

private final class InfoGatherBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var current: String?
    private(set) var remotes: [String: String] = [:]
    private(set) var userNames: Set<String> = []
    private(set) var userEmails: Set<String> = []
    private(set) var defaultBranchCandidate: String?
    private(set) var packedBytes: Int64?
    private(set) var unreleased: UnreleasedSummary?
    private(set) var inventory: FileInventory?
    private(set) var worktrees: [WorktreeInfo] = []

    func setCurrent(_ value: String) { lock.lock(); current = value; lock.unlock() }
    func setConfig(_ config: GitRepository.ConfigSummary) {
        lock.lock(); remotes = config.remotes; userNames = config.userNames; userEmails = config.userEmails; lock.unlock()
    }
    func setDefaultBranchCandidate(_ value: String?) { lock.lock(); defaultBranchCandidate = value; lock.unlock() }
    func setPackedBytes(_ value: Int64?) { lock.lock(); packedBytes = value; lock.unlock() }
    func setUnreleased(_ value: UnreleasedSummary?) { lock.lock(); unreleased = value; lock.unlock() }
    func setInventory(_ value: FileInventory) { lock.lock(); inventory = value; lock.unlock() }
    func setWorktrees(_ value: [WorktreeInfo]) { lock.lock(); worktrees = value; lock.unlock() }
}
