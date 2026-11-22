import Foundation
import Observation
import GitViewCore
import GitViewGit
import GitViewParse

/// Request to load a diff for one file.
public struct DiffRequest: Hashable, Sendable {
    public let source: DiffSource
    public let path: String
    /// What this diff belongs to — a commit subject, "Uncommitted changes", a comparison.
    public let title: String

    public init(source: DiffSource, path: String, title: String) {
        self.source = source
        self.path = path
        self.title = title
    }
}

/// Manages on-demand drilldown data: file history, file diffs, blame, and unit complexity history.
@MainActor
@Observable
public final class InspectorStore {
    public static let fileHistoryLimit = 400

    public var fileHistoryPath: String? {
        didSet { loadFileHistory() }
    }
    public private(set) var fileHistory: [FileHistoryEntry] = []
    public private(set) var fileHistoryInFlight = false
    public var fileHistoryTruncated: Bool { fileHistory.count >= Self.fileHistoryLimit }

    public var diffRequest: DiffRequest? {
        didSet { loadDiff() }
    }
    public private(set) var loadedDiff: FileDiff?
    public private(set) var diffInFlight = false
    public var diffContext: Int = 3 {
        didSet { loadDiff() }
    }

    public private(set) var blame: [String: BlameOwnership] = [:]
    public private(set) var blameInFlight: Set<String> = []

    public private(set) var histories: [UUID: [UnitComplexityPoint]] = [:]
    public private(set) var loadingHistories: Set<UUID> = []

    @ObservationIgnored private var repositoryRoot: URL?

    public init() {}

    public func setRepositoryRoot(_ root: URL) {
        self.repositoryRoot = root
    }

    public func resetForOpen() {
        repositoryRoot = nil
        diffRequest = nil
        fileHistoryPath = nil
        loadedDiff = nil
        fileHistory = []
        blame = [:]
        blameInFlight = []
        histories = [:]
        loadingHistories = []
    }

    public func showFileHistory(_ path: String) {
        diffRequest = nil
        fileHistoryPath = path
    }

    public func closeFileHistory() {
        fileHistoryPath = nil
    }

    public func showDiff(_ source: DiffSource, path: String, title: String) {
        diffRequest = DiffRequest(source: source, path: path, title: title)
    }

    public func closeDiff() {
        diffRequest = nil
    }

    public func loadBlame(for path: String) {
        guard let root = repositoryRoot,
              blame[path] == nil,
              !blameInFlight.contains(path) else { return }
        blameInFlight.insert(path)
        Task.detached(priority: .userInitiated) {
            let result = try? GitRepository(url: root).blame(path: path)
            await MainActor.run {
                guard self.repositoryRoot == root else { return }
                if let result { self.blame[path] = result }
                self.blameInFlight.remove(path)
            }
        }
    }

    public func ensureHistory(for unit: CodeUnit, churn: ChurnIndex?) {
        guard let root = repositoryRoot,
              let churn,
              histories[unit.id] == nil,
              !loadingHistories.contains(unit.id) else { return }
        loadingHistories.insert(unit.id)
        Task {
            let reader = try? GitBatchReader(directory: root)
            defer { reader?.close() }
            let service = UnitHistoryService { sha, path in
                if let reader {
                    if let source = try reader.blob(sha: sha, path: path) {
                        return source
                    }
                    throw GitError.failed(command: "cat-file --batch \(sha):\(path)", code: 1, stderr: "missing")
                }
                return try GitProcess.capture(arguments: ["show", "\(sha):\(path)"], in: root)
            }
            let points = await service.complexityHistory(for: unit, churn: churn)
            guard self.repositoryRoot == root else { return }
            self.histories[unit.id] = points
            self.loadingHistories.remove(unit.id)
        }
    }

    private func loadFileHistory() {
        guard let root = repositoryRoot, let path = fileHistoryPath else {
            fileHistory = []
            fileHistoryInFlight = false
            return
        }
        fileHistoryInFlight = true
        fileHistory = []
        let limit = Self.fileHistoryLimit
        Task.detached(priority: .userInitiated) {
            let entries = (try? GitRepository(url: root).fileHistory(path: path, limit: limit)) ?? []
            await MainActor.run {
                guard self.repositoryRoot == root, self.fileHistoryPath == path else { return }
                self.fileHistory = entries
                self.fileHistoryInFlight = false
            }
        }
    }

    private func loadDiff() {
        guard let root = repositoryRoot, let request = diffRequest else {
            loadedDiff = nil
            diffInFlight = false
            return
        }
        diffInFlight = true
        let context = diffContext
        Task.detached(priority: .userInitiated) {
            let diff = try? GitRepository(url: root).diff(request.source, path: request.path, context: context)
            await MainActor.run {
                guard self.repositoryRoot == root, self.diffRequest == request else { return }
                self.loadedDiff = diff
                self.diffInFlight = false
            }
        }
    }
}
