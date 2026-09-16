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
    let commits: [Commit]
    let allUnits: [CodeUnit]
    let filesParsed: Int
    let filesFailed: [String]
    let historyDuration: TimeInterval
    let parseDuration: TimeInterval
    let attribution: AttributionStats

    var authorCount: Int { Set(commits.map(\.author)).count }
    var dateRange: ClosedRange<Date>? {
        guard let low = commits.map(\.date).min(), let high = commits.map(\.date).max(),
              low <= high else { return nil }
        return low...high
    }
}

enum AnalysisService {
    /// Reads history and parses sources. Both stages run off the main actor — `loadHistory`
    /// blocks for seconds on a large repository and would freeze the window.
    static func load(root: URL) async throws -> RepositoryAnalysis {
        let validated = try await Task.detached(priority: .userInitiated) {
            try GitRepository(url: root).validate()
        }.value

        let historyStart = Date()
        let commits = try await Task.detached(priority: .userInitiated) {
            try GitRepository(url: validated).loadHistory()
        }.value
        let historyDuration = Date().timeIntervalSince(historyStart)

        // Parsing and repository facts are independent; run them together.
        let parseStart = Date()
        async let scan = SourceScanner().scan(root: validated)
        let facts = Task.detached(priority: .userInitiated) { () throws -> (RepositoryInfo, [BranchInfo]) in
            let repository = GitRepository(url: validated)
            let info = try repository.info()
            let branches = try repository.branches(defaultBranch: info.defaultBranch, currentBranch: info.currentBranch)
            return (info, branches)
        }
        let report = try await scan
        let (info, branches) = try await facts.value
        let parseDuration = Date().timeIntervalSince(parseStart)

        // Join once over the unfiltered unit set purely for the diagnostic.
        let fullJoin = ChurnJoiner.join(units: report.units, commits: commits)

        return RepositoryAnalysis(
            root: validated,
            info: info,
            branches: branches,
            commits: commits,
            allUnits: report.units,
            filesParsed: report.filesParsed,
            filesFailed: report.filesFailed,
            historyDuration: historyDuration,
            parseDuration: parseDuration,
            attribution: AttributionStats(matchedHunks: fullJoin.matchedHunks,
                                          unmatchedHunks: fullJoin.unmatchedHunks,
                                          unresolvedHunks: fullJoin.unresolvedPaths)
        )
    }
}
