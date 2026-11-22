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
    var fullChurn: ChurnIndex? = nil
    var precomputedOwnership: OwnershipIndex? = nil
    var precomputedContributors: [Contributor]? = nil

    init(
        root: URL,
        info: RepositoryInfo,
        branches: [BranchInfo],
        tags: [TagInfo],
        commits: [Commit],
        allUnits: [CodeUnit],
        filesParsed: Int,
        filesFailed: [String],
        generatedFiles: Set<String>,
        historyDuration: TimeInterval,
        parseDuration: TimeInterval,
        factsDuration: TimeInterval,
        attribution: AttributionStats,
        source: AnalysisSource,
        workingState: WorkingState,
        fullChurn: ChurnIndex? = nil,
        precomputedOwnership: OwnershipIndex? = nil,
        precomputedContributors: [Contributor]? = nil
    ) {
        self.root = root
        self.info = info
        self.branches = branches
        self.tags = tags
        self.commits = commits
        self.allUnits = allUnits
        self.filesParsed = filesParsed
        self.filesFailed = filesFailed
        self.generatedFiles = generatedFiles
        self.historyDuration = historyDuration
        self.parseDuration = parseDuration
        self.factsDuration = factsDuration
        self.attribution = attribution
        self.source = source
        self.workingState = workingState
        self.fullChurn = fullChurn
        self.precomputedOwnership = precomputedOwnership
        self.precomputedContributors = precomputedContributors
    }

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

/// Which parts of an analysis have arrived.
///
/// The three stages cost wildly different amounts: branches, tags and the working copy are
/// a handful of quick git calls, history is a full `git log -p`, and parsing is every
/// source file through tree-sitter. Holding the whole app hostage to the slowest of them
/// meant staring at a spinner while the answer to "what have I got uncommitted" had been
/// sitting in memory for twenty seconds.
struct Readiness: Equatable, Sendable {
    var hasHistory: Bool
    var hasUnits: Bool

    static let factsOnly = Readiness(hasHistory: false, hasUnits: false)
    static let withHistory = Readiness(hasHistory: true, hasUnits: false)
    static let complete = Readiness(hasHistory: true, hasUnits: true)
}

/// What the loading screen has to say. Every field is something the analysis genuinely
/// knows at that moment — there is no synthetic percentage that creeps forward on a timer.
struct LoadingProgress: Equatable, Sendable {
    var stage: String
    var detail: String?
    /// Set only while parsing, which is the one stage whose total is known in advance.
    var fraction: Double?
}

enum AnalysisService {
    /// Reads history and parses sources, reusing a cache where it is safe to.
    ///
    /// Everything heavy runs off the main actor — `loadHistory` blocks for seconds, or a
    /// minute on a repository whose history carries large generated files.
    /// - Parameter partial: handed a usable analysis at each milestone, so the app can put
    ///   the parts it already has on screen instead of waiting for all of them.
    static func load(root: URL, useCache: Bool = true,
                     progress: @escaping @Sendable (LoadingProgress) -> Void = { _ in },
                     partial: @escaping @Sendable (RepositoryAnalysis, Readiness) -> Void = { _, _ in }
    ) async throws -> RepositoryAnalysis {
        progress(LoadingProgress(stage: "Checking the repository"))
        let validated = try await Task.detached(priority: .userInitiated) {
            try GitRepository(url: root).validate()
        }.value
        let repository = GitRepository(url: validated)
        let head = (try? repository.headSHA()) ?? ""
        let cached = useCache ? AnalysisCache.load(root: validated, matchingHead: head.isEmpty ? nil : head)
            ?? AnalysisCache.load(root: validated) : nil
        let cachedFileUnits = useCache ? AnalysisCache.loadFileUnits(root: validated) : [:]
        let cachedDivergence = useCache ? AnalysisCache.loadBranchDivergence(root: validated) : [:]

        // Facts are cheap and always current; run independent git reads in parallel.
        let factsStart = Date()
        progress(LoadingProgress(stage: "Reading branches and tags"))
        async let infoTask = Task.detached(priority: .userInitiated) { try repository.info() }.value
        async let tagsTask = Task.detached(priority: .userInitiated) { (try? repository.tags()) ?? [] }.value
        async let workingTask = Task.detached(priority: .userInitiated) {
            (try? repository.workingState()) ?? .clean
        }.value

        let info = try await infoTask
        let branchScan = try await Task.detached(priority: .userInitiated) {
            try repository.branches(
                defaultBranch: info.defaultBranch,
                currentBranch: info.currentBranch,
                cachedDivergence: cachedDivergence
            )
        }.value
        let branches = branchScan.branches
        let computedDivergence = branchScan.computedDivergence
        let tags = await tagsTask
        let workingState = await workingTask
        let factsDuration = Date().timeIntervalSince(factsStart)

        // History: reuse, extend, or read in full.
        // Everything the quick git calls answered is already worth showing: the working
        // copy, the branches, the tags, the file tree.
        partial(RepositoryAnalysis(
            root: validated, info: info, branches: branches, tags: tags,
            commits: [], allUnits: [], filesParsed: 0, filesFailed: [], generatedFiles: [],
            historyDuration: 0, parseDuration: 0, factsDuration: factsDuration,
            attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
            source: .fresh, workingState: workingState), .factsOnly)

        progress(LoadingProgress(stage: "Reading history",
                                 detail: cached == nil ? "every commit, first time for this project"
                                                       : "only what is new since last time"))
        let historyStart = Date()
        var source = AnalysisSource.fresh
        var commits: [Commit]
        if let cached, cached.headSHA == head {
            commits = cached.commits
            source = .cached
        } else if useCache, !head.isEmpty,
                  let headSHAs = repository.revListSHAs(),
                  let poolCommits = AnalysisCache.loadCommits(orderedSHAs: headSHAs, root: validated) {
            commits = poolCommits
            source = .cached
        } else if let cached, !cached.headSHA.isEmpty, repository.isAncestor(cached.headSHA, of: head) {
            let since = cached.headSHA
            let newCommits = try await repository.loadHistoryAsync(since: since)
            commits = newCommits + cached.commits
            source = .incremental(newCommits: newCommits.count)
        } else {
            commits = try await repository.loadHistoryAsync()
        }
        let historyDuration = Date().timeIntervalSince(historyStart)
        let currentPaths = Set(info.inventory.files.map(\.path))
        let precomputedContributors = await Task.detached(priority: .userInitiated) {
            ContributorStats.compute(commits: commits)
        }.value
        let precomputedOwnership = await Task.detached(priority: .userInitiated) {
            OwnershipBuilder.build(commits: commits, currentPaths: currentPaths)
        }.value

        partial(RepositoryAnalysis(
            root: validated, info: info, branches: branches, tags: tags,
            commits: commits, allUnits: [], filesParsed: 0, filesFailed: [], generatedFiles: [],
            historyDuration: historyDuration, parseDuration: 0, factsDuration: factsDuration,
            attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
            source: source, workingState: workingState,
            fullChurn: nil,
            precomputedOwnership: precomputedOwnership,
            precomputedContributors: precomputedContributors), .withHistory)

        // Reuse cached per-file units wherever byte size and modification timestamp still match;
        // scan only dirty or newly added files, dropping deleted files from the result.
        let parseStart = Date()
        let parsableTracked = info.inventory.files.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            return LanguageRegistry.shared.language(forExtension: ext) != nil
        }

        var reusedUnits: [CodeUnit] = []
        var reusedGenerated: Set<String> = []
        var reusedFilesCount = 0
        var dirtyPaths: [String] = []
        dirtyPaths.reserveCapacity(parsableTracked.count)

        for file in parsableTracked {
            if useCache,
               let entry = cachedFileUnits[file.path],
               let modDate = file.modified,
               entry.bytes == file.bytes,
               abs(entry.modified - modDate.timeIntervalSince1970) < 0.001 {
                reusedUnits.append(contentsOf: entry.units)
                if entry.isGenerated { reusedGenerated.insert(file.path) }
                reusedFilesCount += 1
            } else {
                dirtyPaths.append(file.path)
            }
        }

        let report: SourceScanner.Report
        if dirtyPaths.isEmpty {
            report = SourceScanner.Report(
                units: reusedUnits,
                filesParsed: reusedFilesCount,
                filesFailed: [],
                generatedFiles: reusedGenerated
            )
        } else {
            progress(LoadingProgress(stage: "Parsing source files"))
            let scanned = try await SourceScanner().scan(root: validated, trackedPaths: dirtyPaths) { parsed, total in
                guard total > 0 else { return }
                progress(LoadingProgress(
                    stage: "Parsing source files",
                    detail: "\(parsed.formatted()) of \(total.formatted()) files",
                    fraction: Double(parsed) / Double(total)))
            }
            report = SourceScanner.Report(
                units: reusedUnits + scanned.units,
                filesParsed: reusedFilesCount + scanned.filesParsed,
                filesFailed: scanned.filesFailed,
                generatedFiles: reusedGenerated.union(scanned.generatedFiles)
            )
            if reusedFilesCount == 0, case .cached = source { source = .fresh }
        }
        let parseDuration = Date().timeIntervalSince(parseStart)

        progress(LoadingProgress(stage: "Working out what it all means",
                                 detail: "\(commits.count.formatted()) commits, \(report.units.count.formatted()) functions"))
        let unitsByPath = Dictionary(grouping: report.units, by: \.filePath)
        let failedSet = Set(report.filesFailed)
        let fileEntries = parsableTracked.compactMap { file -> AnalysisCache.CachedFileUnits? in
            guard !failedSet.contains(file.path), let modified = file.modified else { return nil }
            return AnalysisCache.CachedFileUnits(
                path: file.path,
                bytes: file.bytes,
                modified: modified.timeIntervalSince1970,
                isGenerated: report.generatedFiles.contains(file.path),
                units: unitsByPath[file.path] ?? []
            )
        }
        if useCache {
            AnalysisCache.save(
                headSHA: head,
                commits: commits,
                fileEntries: fileEntries,
                root: validated
            )
            if !computedDivergence.isEmpty {
                AnalysisCache.saveBranchDivergence(computedDivergence, root: validated)
            }
        }

        // Join once over all parsed units off the main actor; RiskStore reuses this index.
        let fullJoin = await Task.detached(priority: .userInitiated) {
            ChurnJoiner.join(units: report.units, commits: commits)
        }.value

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
            workingState: workingState,
            fullChurn: fullJoin,
            precomputedOwnership: precomputedOwnership,
            precomputedContributors: precomputedContributors
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
