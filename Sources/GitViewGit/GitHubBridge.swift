import Foundation

/// Summary of an open pull request retrieved optionally via the local `gh` CLI.
public struct PullRequestSummary: Identifiable, Hashable, Sendable {
    public enum CheckStatus: String, Hashable, Sendable {
        case passing, failing, pending, none
    }

    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: URL
    public let headRefName: String
    public let baseRefName: String
    public let isDraft: Bool
    public let reviewDecision: String?
    public let checkStatus: CheckStatus
    public let authorLogin: String?
    public let updatedAt: Date?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?

    public init(
        number: Int,
        title: String,
        url: URL,
        headRefName: String,
        baseRefName: String,
        isDraft: Bool,
        reviewDecision: String?,
        checkStatus: CheckStatus,
        authorLogin: String? = nil,
        updatedAt: Date? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        changedFiles: Int? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checkStatus = checkStatus
        self.authorLogin = authorLogin
        self.updatedAt = updatedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }
}

public enum GitHubBridge {
    private static let candidateGHPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    public static func ghExecutablePath() -> String? {
        candidateGHPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func parsePullRequests(json: Data) -> [PullRequestSummary] {
        guard let decoded = try? JSONDecoder().decode([RawPullRequest].self, from: json) else {
            return []
        }
        return decoded.compactMap { raw in
            guard let url = URL(string: raw.url), !raw.headRefName.isEmpty else { return nil }
            let trimmedLogin = raw.author?.login?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PullRequestSummary(
                number: raw.number,
                title: raw.title,
                url: url,
                headRefName: raw.headRefName,
                baseRefName: raw.baseRefName,
                isDraft: raw.isDraft ?? false,
                reviewDecision: raw.reviewDecision,
                checkStatus: rollupStatus(from: raw.statusCheckRollup ?? []),
                authorLogin: trimmedLogin?.isEmpty == false ? trimmedLogin : nil,
                updatedAt: raw.updatedAt.flatMap(ISO8601.parse),
                additions: raw.additions,
                deletions: raw.deletions,
                changedFiles: raw.changedFiles
            )
        }
    }

    public static func createPRURL(remoteWebURL: URL, branch: String, defaultBranch: String) -> URL? {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefault = defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty,
              trimmedBranch != "HEAD",
              trimmedBranch != trimmedDefault else {
            return nil
        }

        let host = remoteWebURL.host?.lowercased() ?? ""
        if host.contains("gitlab") {
            let base = remoteWebURL
                .appendingPathComponent("-")
                .appendingPathComponent("merge_requests")
                .appendingPathComponent("new")
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "merge_request[source_branch]", value: trimmedBranch),
                URLQueryItem(name: "merge_request[target_branch]", value: trimmedDefault.isEmpty ? "main" : trimmedDefault),
            ]
            return components?.url
        }

        let targetBase = trimmedDefault.isEmpty ? "main" : trimmedDefault
        let base = remoteWebURL
            .appendingPathComponent("compare")
            .appendingPathComponent("\(targetBase)...\(trimmedBranch)")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "expand", value: "1")]
        return components?.url
    }

    public static func linePermalinkURL(remoteWebURL: URL, sha: String, path: String, line: Int) -> URL? {
        let trimmedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSHA.isEmpty, !trimmedPath.isEmpty else { return nil }

        var url = remoteWebURL
            .appendingPathComponent("blob")
            .appendingPathComponent(trimmedSHA)
        for segment in trimmedPath.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "L\(max(1, line))"
        return components?.url
    }

    /// Queries open pull requests from GitHub using `gh` if available and authenticated.
    /// Never prompts for credentials and returns `[]` silently on any missing binary, network, or auth error.
    public static func fetchOpenPullRequests(
        in root: URL,
        remoteWebURL: URL?,
        timeout: TimeInterval = 10
    ) async -> [PullRequestSummary] {
        guard remoteWebURL?.host?.lowercased() == "github.com",
              let ghPath = ghExecutablePath() else {
            return []
        }

        let arguments = [
            "pr", "list",
            "--state", "open",
            "--limit", "50",
            "--json", "number,title,url,headRefName,baseRefName,isDraft,reviewDecision,statusCheckRollup,author,updatedAt,additions,deletions,changedFiles",
        ]
        guard let data = await captureProcessData(
            executablePath: ghPath,
            arguments: arguments,
            in: root,
            timeout: timeout
        ) else {
            return []
        }
        return parsePullRequests(json: data)
    }

    public static func checkoutPullRequest(number: Int, in root: URL) throws {
        _ = try runGH(arguments: ["pr", "checkout", "\(number)"], in: root, commandLabel: "gh pr checkout")
    }

    public static func createPullRequest(
        title: String,
        body: String,
        base: String,
        draft: Bool,
        in root: URL
    ) throws -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw GitWriteError(command: "gh pr create", message: "Pull request title cannot be empty.")
        }
        var arguments = [
            "pr", "create",
            "--title", trimmedTitle,
            "--body", body,
            "--base", base,
        ]
        if draft { arguments.append("--draft") }
        let stdout = try runGH(arguments: arguments, in: root, commandLabel: "gh pr create")
        let lastLine = stdout
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return lastLine.flatMap(URL.init(string:))
    }

    private static func runGH(arguments: [String], in directory: URL, commandLabel: String) throws -> String {
        guard let ghPath = ghExecutablePath() else {
            throw GitWriteError(command: commandLabel, message: "GitHub CLI (gh) is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw GitWriteError(
                command: commandLabel,
                message: stderr.isEmpty ? "gh exited with code \(process.terminationStatus)" : stderr
            )
        }
        return stdout
    }

    private static func captureProcessData(
        executablePath: String,
        arguments: [String],
        in directory: URL,
        timeout: TimeInterval
    ) async -> Data? {
        let processBox = GHProcessBox()
        let outBox = DataBox()

        return await withTaskCancellationHandler {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executablePath)
                        process.arguments = arguments
                        process.currentDirectoryURL = directory
                        var env = ProcessInfo.processInfo.environment
                        env["GH_PROMPT_DISABLED"] = "1"
                        env["NO_COLOR"] = "1"
                        process.environment = env

                        let outPipe = Pipe()
                        process.standardOutput = outPipe
                        process.standardError = FileHandle.nullDevice

                        let gate = GHResumeGate()
                        outPipe.fileHandleForReading.readabilityHandler = { handle in
                            let chunk = handle.availableData
                            if chunk.isEmpty {
                                handle.readabilityHandler = nil
                            } else {
                                outBox.append(chunk)
                            }
                        }
                        process.terminationHandler = { proc in
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            processBox.detach()
                            gate.resumeOnce {
                                if proc.terminationStatus == 0 {
                                    continuation.resume(returning: outBox.get())
                                } else {
                                    continuation.resume(returning: nil)
                                }
                            }
                        }

                        guard processBox.attachIfActive(process) else {
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            process.terminationHandler = nil
                            gate.resumeOnce { continuation.resume(returning: nil) }
                            return
                        }

                        do {
                            try process.run()
                        } catch {
                            processBox.detach()
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            process.terminationHandler = nil
                            gate.resumeOnce { continuation.resume(returning: nil) }
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.5) * 1_000_000_000))
                    processBox.cancel()
                    return nil
                }

                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private static func rollupStatus(from items: [RawStatusItem]) -> PullRequestSummary.CheckStatus {
        guard !items.isEmpty else { return .none }
        var hasPassing = false
        var hasPending = false

        for item in items {
            if let state = item.state?.uppercased() {
                switch state {
                case "FAILURE", "ERROR":
                    return .failing
                case "PENDING", "EXPECTED":
                    hasPending = true
                case "SUCCESS":
                    hasPassing = true
                default:
                    break
                }
            }
            if let conclusion = item.conclusion?.uppercased(), !conclusion.isEmpty {
                switch conclusion {
                case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED":
                    return .failing
                case "SUCCESS", "NEUTRAL", "SKIPPED":
                    hasPassing = true
                default:
                    hasPending = true
                }
            } else if let status = item.status?.uppercased() {
                switch status {
                case "IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED":
                    hasPending = true
                default:
                    break
                }
            }
        }

        if hasPending { return .pending }
        return hasPassing ? .passing : .none
    }

    private struct RawPullRequest: Decodable {
        let number: Int
        let title: String
        let url: String
        let headRefName: String
        let baseRefName: String
        let isDraft: Bool?
        let reviewDecision: String?
        let statusCheckRollup: [RawStatusItem]?
        let author: RawAuthor?
        let updatedAt: String?
        let additions: Int?
        let deletions: Int?
        let changedFiles: Int?
    }

    private struct RawAuthor: Decodable {
        let login: String?
    }

    private struct RawStatusItem: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
}

private final class GHProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attachIfActive(_ proc: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        process = proc
        return true
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}

private final class GHResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body()
    }
}
