import Foundation
import GitViewCore
import GitViewGit
import GitViewParse

/// Everything an analysis produces that is expensive to recompute.
///
/// Held separately from the derived ranking so that moving the half-life slider or
/// toggling a filter re-ranks in milliseconds instead of re-reading git history.
struct RepositoryAnalysis: Sendable {
    let root: URL
    let commits: [Commit]
    let allUnits: [CodeUnit]
    let filesParsed: Int
    let filesFailed: [String]
    let historyDuration: TimeInterval
    let parseDuration: TimeInterval

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

        let parseStart = Date()
        let report = try await SourceScanner().scan(root: validated)
        let parseDuration = Date().timeIntervalSince(parseStart)

        return RepositoryAnalysis(
            root: validated,
            commits: commits,
            allUnits: report.units,
            filesParsed: report.filesParsed,
            filesFailed: report.filesFailed,
            historyDuration: historyDuration,
            parseDuration: parseDuration
        )
    }
}
