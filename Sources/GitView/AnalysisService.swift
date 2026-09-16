import Foundation
import GitViewCore
import GitViewGit
import GitViewParse

/// Everything an analysis produces that is expensive to recompute.
///
/// Held separately from the derived ranking so that moving the half-life slider or
/// toggling a filter re-ranks in milliseconds instead of re-reading git history.
/// How well commit hunks line up with parsed functions, measured over **every** parsed
/// unit. A diagnostic of the analysis itself, so it must not move when the user excludes
/// tests or raises the minimum-commits filter.
struct AttributionStats: Sendable {
    let matchedHunks: Int
    let unmatchedHunks: Int
    /// Hunks in files with no parsed units (non-Swift, or deleted since).
    let unresolvedHunks: Int

    var hunksInParsedFiles: Int { matchedHunks + unmatchedHunks }
    var matchRate: Double {
        hunksInParsedFiles > 0 ? Double(matchedHunks) / Double(hunksInParsedFiles) : 0
    }
}

struct RepositoryAnalysis: Sendable {
    let root: URL
    let info: RepositoryInfo
    let branches: [BranchInfo]
    let tags: [TagInfo]
    let commits: [Commit]
    let allUnits: [CodeUnit]
    let filesParsed: Int
    let filesFailed: [String]
    /// Paths recognised as vendored or machine-generated.
    let generatedFiles: Set<String>
    let historyDuration: TimeInterval
    /// Time spent parsing source files. Zero when cached units were reused.
    let parseDuration: TimeInterval
    /// Branches, file inventory and README — always recomputed, never cached.
    let factsDuration: TimeInterval
    let attribution: AttributionStats
    let source: AnalysisSource
    /// Read fresh on every load and refreshable on its own; never cached.
    var workingState: WorkingState

    var authorCount: Int { Set(commits.map(\.author)).count }
    var dateRange: ClosedRange<Date>? {
        guard let low = commits.map(\.date).min(), let high = commits.map(\.date).max(),
              low <= high else { return nil }
        return low...high
    }
}

/// Where this analysis came from, so the UI can say why it was quick.
enum AnalysisSource: Sendable {
    case fresh
    case cached
    case incremental(newCommits: Int)

    var isCached: Bool {
        if case .fresh = self { return false }
        return true
    }

    var summary: String {
        switch self {
        case .fresh: return "Analysed from scratch"
        case .cached: return "Loaded from cache"
        case .incremental(let count): return "Cached, plus \(count) new commit\(count == 1 ? "" : "s")"
        }
    }
}

enum AnalysisService {
    /// Reads history and parses sources, reusing a cache where it is safe to.
    ///
    /// Everything heavy runs off the main actor — `loadHistory` blocks for seconds, or a
    /// minute on a repository whose history carries large generated files.
    static func load(root: URL, useCache: Bool = true) async throws -> RepositoryAnalysis {
        let validated = try await Task.detached(priority: .userInitiated) {
            try GitRepository(url: root).validate()
        }.value
        let repository = GitRepository(url: validated)
        let head = (try? repository.headSHA()) ?? ""
        let cached = useCache ? AnalysisCache.load(root: validated) : nil

        // Facts are cheap and always current; they also tell us when the working tree last
        // changed, which decides whether cached units are still valid.
        let factsStart = Date()
        let facts = Task.detached(priority: .userInitiated) {
            () throws -> (RepositoryInfo, [BranchInfo], [TagInfo], WorkingState) in
            let info = try repository.info()
            let branches = try repository.branches(defaultBranch: info.defaultBranch, currentBranch: info.currentBranch)
            let tags = (try? repository.tags()) ?? []
            let working = (try? repository.workingState()) ?? .clean
            return (info, branches, tags, working)
        }
        let (info, branches, tags, workingState) = try await facts.value
        let factsDuration = Date().timeIntervalSince(factsStart)

        // History: reuse, extend, or read in full.
        let historyStart = Date()
        var source = AnalysisSource.fresh
        var commits: [Commit]
        if let cached, cached.headSHA == head {
            commits = cached.commits
            source = .cached
        } else if let cached, !cached.headSHA.isEmpty, repository.isAncestor(cached.headSHA, of: head) {
            let since = cached.headSHA
            let newCommits = try await Task.detached(priority: .userInitiated) {
                try GitRepository(url: validated).loadHistory(since: since)
            }.value
            commits = newCommits + cached.commits
            source = .incremental(newCommits: newCommits.count)
        } else {
            commits = try await Task.detached(priority: .userInitiated) {
                try GitRepository(url: validated).loadHistory()
            }.value
        }
        let historyDuration = Date().timeIntervalSince(historyStart)

        // Units come from the working tree, so they are only reusable if nothing has been
        // edited since the cache was written.
        let parseStart = Date()
        let report: SourceScanner.Report
        if let cached, let modified = info.inventory.lastModified, modified <= cached.createdAt,
           !cached.units.isEmpty {
            report = SourceScanner.Report(units: cached.units,
                                          filesParsed: Set(cached.units.map(\.filePath)).count,
                                          filesFailed: [],
                                          generatedFiles: Set(cached.generatedFiles))
        } else {
            report = try await SourceScanner().scan(root: validated)
            if case .cached = source { source = .fresh }
        }
        let parseDuration = Date().timeIntervalSince(parseStart)

        AnalysisCache.save(.init(headSHA: head, commits: commits, units: report.units,
                                 generatedFiles: Array(report.generatedFiles)), root: validated)

        // Join once over the unfiltered unit set purely for the diagnostic.
        let fullJoin = ChurnJoiner.join(units: report.units, commits: commits)

        return RepositoryAnalysis(
            root: validated,
            info: info,
            branches: branches,
            tags: tags,
            commits: commits,
            allUnits: report.units,
            filesParsed: report.filesParsed,
            filesFailed: report.filesFailed,
            generatedFiles: report.generatedFiles,
            historyDuration: historyDuration,
            parseDuration: parseDuration,
            factsDuration: factsDuration,
            attribution: AttributionStats(matchedHunks: fullJoin.matchedHunks,
                                          unmatchedHunks: fullJoin.unmatchedHunks,
                                          unresolvedHunks: fullJoin.unresolvedPaths),
            source: source,
            workingState: workingState
        )
    }
}

/// What changed between two points in history.
struct ComparisonResult: Sendable {
    let from: String
    let to: String
    let commits: [Commit]
    let deltas: [FileDelta]

    var stat: DiffStat {
        DiffStat(filesChanged: deltas.count,
                 insertions: deltas.reduce(0) { $0 + $1.insertions },
                 deletions: deltas.reduce(0) { $0 + $1.deletions })
    }

    /// People who committed in this range, most commits first.
    var contributors: [(name: String, commits: Int)] {
        Dictionary(grouping: commits, by: \.author)
            .map { (name: $0.key, commits: $0.value.count) }
            .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
    }

    var isEmpty: Bool { commits.isEmpty && deltas.isEmpty }
}
