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
    /// True for a remote-tracking branch with no local counterpart (`origin/feature`).
    public let isRemote: Bool
    /// Commits on this branch that the default branch does not have. Nil when not computed.
    public let ahead: Int?
    /// Commits on the default branch that this branch does not have. Nil when not computed.
    public let behind: Int?
    public let isMerged: Bool
}

/// What is in the working tree, counted over *tracked* files only so build products and
/// dependencies do not inflate the numbers.
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
    public let inventory: FileInventory
}

extension GitRepository {

    public func info() throws -> RepositoryInfo {
        let root = try validate()
        let current = try GitProcess.capture(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = (try? GitProcess.capture(arguments: ["remote", "get-url", "origin"], in: root))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryInfo(
            root: root,
            currentBranch: current,
            defaultBranch: Self.defaultBranch(in: root, fallback: current),
            remoteURL: remote.flatMap { $0.isEmpty ? nil : $0 },
            remoteWebURL: remote.flatMap(Self.webURL(fromRemote:)),
            packedBytes: Self.objectStoreBytes(in: root),
            readmeSummary: Self.readmeSummary(in: root),
            inventory: Self.inventory(in: root)
        )
    }

    /// Local branches plus remote-tracking branches from `origin` that have no local
    /// counterpart (a fresh clone has only the default branch locally), newest commit
    /// first. Ahead/behind is computed for the first `detailLimit` branches only — it is
    /// one `rev-list` per branch.
    public func branches(defaultBranch: String, currentBranch: String, detailLimit: Int = 60) throws -> [BranchInfo] {
        let root = try validate()
        // `authorname:mailmap` for the same reason the log format uses %aN.
        let format = "%(refname)%1f%(objectname)%1f%(committerdate:iso-strict)%1f%(authorname:mailmap)%1f%(subject)"
        let output = try GitProcess.capture(
            arguments: ["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes/origin"],
            in: root)
        let merged = Set((try? GitProcess.capture(
            arguments: ["branch", "-a", "--merged", defaultBranch, "--format=%(refname:short)"], in: root))?
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) } ?? [])

        var seen = Set<String>()
        var branches: [BranchInfo] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            let ref = fields[0]
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name = isRemote ? String(ref.dropFirst("refs/remotes/origin/".count)) : String(ref.dropFirst("refs/heads/".count))
            guard name != "HEAD", !seen.contains(name) else { continue }   // local wins over its remote twin
            seen.insert(name)
            let fullName = isRemote ? "origin/\(name)" : name

            var ahead: Int?, behind: Int?
            if name != defaultBranch, branches.count < detailLimit,
               let counts = try? GitProcess.capture(
                   arguments: ["rev-list", "--left-right", "--count", "\(defaultBranch)...\(fullName)"], in: root) {
                let parts = counts.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
                if parts.count == 2 { behind = parts[0]; ahead = parts[1] }
            }
            branches.append(BranchInfo(
                name: name, sha: fields[1],
                date: ISO8601DateFormatter().date(from: fields[2]) ?? .distantPast,
                author: fields[3], subject: fields[4],
                isDefault: name == defaultBranch, isCurrent: !isRemote && name == currentBranch,
                isRemote: isRemote,
                ahead: ahead, behind: behind,
                isMerged: name != defaultBranch && (merged.contains(name) || merged.contains(fullName))))
        }
        return branches
    }

    // MARK: - Pieces

    static func defaultBranch(in root: URL, fallback: String) -> String {
        if let ref = try? GitProcess.capture(arguments: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root) {
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = trimmed.firstIndex(of: "/") { return String(trimmed[trimmed.index(after: slash)...]) }
            if !trimmed.isEmpty { return trimmed }
        }
        for candidate in ["main", "master", "develop"] {
            if (try? GitProcess.capture(arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: root)) != nil {
                return candidate
            }
        }
        return fallback
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
            return FileInventory(fileCount: 0, totalBytes: 0, files: [], bytesByCategory: [:], largeFiles: [], lastModified: nil)
        }
        var count = 0
        var total: Int64 = 0
        var byCategory: [String: Int64] = [:]
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
            files.append(.init(path: path, bytes: bytes, modified: values.contentModificationDate))
            if bytes >= FileInventory.largeFileThreshold { large.append(.init(path: path, bytes: bytes)) }
            if let modified = values.contentModificationDate, newest.map({ modified > $0 }) ?? true { newest = modified }
        }
        return FileInventory(fileCount: count, totalBytes: total, files: files, bytesByCategory: byCategory,
                             largeFiles: large.sorted { $0.bytes > $1.bytes }, lastModified: newest)
    }
}
