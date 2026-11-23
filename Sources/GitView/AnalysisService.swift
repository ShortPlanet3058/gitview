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
    var info: RepositoryInfo
    var branches: [BranchInfo]
    var tags: [TagInfo]
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
    let hasCodeUnits: Bool

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
        precomputedContributors: [Contributor]? = nil,
        hasCodeUnits: Bool = true
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
        self.hasCodeUnits = hasCodeUnits
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
                     includeCodeAnalysis: Bool = true,
                     progress: @escaping @Sendable (LoadingProgress) -> Void = { _ in },
                     partial: @escaping @Sendable (RepositoryAnalysis, Readiness) -> Void = { _, _ in }
    ) async throws -> RepositoryAnalysis {
        progress(LoadingProgress(stage: "Checking the repository"))
        let validated = try await Task.detached(priority: .userInitiated) {
            try GitRepository(url: root).validate()
        }.value
        let repository = GitRepository(url: validated)

        // Facts are cheap and always current; run independent git reads & SQLite snapshot load in parallel.
        let factsStart = Date()
        progress(LoadingProgress(stage: "Reading branches and tags"))
        async let cacheStateTask: (head: String, snapshot: AnalysisCache.Snapshot) = Task.detached(priority: .userInitiated) {
            let head = (try? repository.headSHA()) ?? ""
            let snapshot = useCache
                ? AnalysisCache.loadSnapshot(root: validated, matchingHead: head.isEmpty ? nil : head)
                : .empty
            return (head, snapshot)
        }.value
        async let quickBranchesTask = Task.detached(priority: .userInitiated) {
            repository.quickBranchRefs(validatedRoot: validated)
        }.value
        async let tagsTask = Task.detached(priority: .userInitiated) {
            (try? repository.tags(validatedRoot: validated)) ?? []
        }.value
        async let workingTask = Task.detached(priority: .userInitiated) {
            (try? repository.workingState(validatedRoot: validated)) ?? .clean
        }.value

        let quickBranches = await quickBranchesTask
        async let infoTask = Task.detached(priority: .userInitiated) {
            try repository.info(validatedRoot: validated, quickBranches: quickBranches)
        }.value
        let (head, snapshot) = await cacheStateTask
        async let branchScanTask = Task.detached(priority: .userInitiated) {
            try repository.branches(
                validatedRoot: validated,
                defaultBranch: quickBranches.defaultBranch,
                currentBranch: quickBranches.current,
                cachedDivergence: snapshot.branchDivergence
            )
        }.value

        let info = try await infoTask
        let branchScan = try await branchScanTask
        let branches = branchScan.branches
        let computedDivergence = branchScan.computedDivergence
        let tags = await tagsTask
        let workingState = await workingTask
        let factsDuration = Date().timeIntervalSince(factsStart)

        let cached = snapshot.matchingPayload ?? snapshot.payload
        let cachedFileUnits = snapshot.fileUnits

        // Standard-mode fast path: cache hit on exact HEAD skips tree-sitter & churn join entirely.
        if !includeCodeAnalysis,
           useCache,
           let matched = snapshot.matchingPayload,
           !head.isEmpty,
           matched.headSHA == head {
            let commits = matched.commits
            let currentPaths = Set(info.inventory.files.map(\.path))
            async let contributorsTask = Task.detached(priority: .userInitiated) {
                ContributorStats.compute(commits: commits)
            }.value
            async let ownershipTask = Task.detached(priority: .userInitiated) {
                OwnershipBuilder.build(commits: commits, currentPaths: currentPaths)
            }.value

            let precomputedContributors = await contributorsTask
            let precomputedOwnership = await ownershipTask

            if !computedDivergence.isEmpty {
                Task.detached(priority: .utility) {
                    AnalysisCache.saveBranchDivergence(computedDivergence, root: validated)
                }
            }

            return RepositoryAnalysis(
                root: validated,
                info: info,
                branches: branches,
                tags: tags,
                commits: commits,
                allUnits: [],
                filesParsed: 0,
                filesFailed: [],
                generatedFiles: [],
                historyDuration: 0,
                parseDuration: 0,
                factsDuration: factsDuration,
                attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
                source: .cached,
                workingState: workingState,
                fullChurn: nil,
                precomputedOwnership: precomputedOwnership,
                precomputedContributors: precomputedContributors,
                hasCodeUnits: false
            )
        }

        var parsableTracked: [FileInventory.TrackedFile] = []
        var reusedUnits: [CodeUnit] = []
        var reusedGenerated: Set<String> = []
        var reusedFilesCount = 0
        var dirtyPaths: [String] = []

        if includeCodeAnalysis {
            // Partition tracked parsable files against cached per-file units up front (in-memory only).
            parsableTracked = info.inventory.files.filter { file in
                let ext = (file.path as NSString).pathExtension.lowercased()
                return LanguageRegistry.shared.language(forExtension: ext) != nil
            }
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

            // Fast path: full cache hit for exact HEAD with zero dirty files skips intermediate UI flickers
            // and avoids rewriting unchanged SQLite blobs.
            if useCache,
               let matched = snapshot.matchingPayload,
               !head.isEmpty,
               matched.headSHA == head,
               dirtyPaths.isEmpty {
                let commits = matched.commits
                let currentPaths = Set(info.inventory.files.map(\.path))
                let units = reusedUnits
                async let contributorsTask = Task.detached(priority: .userInitiated) {
                    ContributorStats.compute(commits: commits)
                }.value
                async let ownershipTask = Task.detached(priority: .userInitiated) {
                    OwnershipBuilder.build(commits: commits, currentPaths: currentPaths)
                }.value
                async let joinTask = Task.detached(priority: .userInitiated) {
                    ChurnJoiner.join(units: units, commits: commits)
                }.value

                let precomputedContributors = await contributorsTask
                let precomputedOwnership = await ownershipTask
                let fullJoin = await joinTask

                let unitsByPath = Dictionary(grouping: units, by: \.filePath)
                let fileEntries = parsableTracked.compactMap { file -> AnalysisCache.CachedFileUnits? in
                    guard let modified = file.modified else { return nil }
                    return AnalysisCache.CachedFileUnits(
                        path: file.path,
                        bytes: file.bytes,
                        modified: modified.timeIntervalSince1970,
                        isGenerated: reusedGenerated.contains(file.path),
                        units: unitsByPath[file.path] ?? []
                    )
                }
                let needsPruneSave = cachedFileUnits.count != fileEntries.count
                if needsPruneSave || !computedDivergence.isEmpty {
                    Task.detached(priority: .utility) {
                        if needsPruneSave {
                            AnalysisCache.save(
                                headSHA: head,
                                commits: commits,
                                fileEntries: fileEntries,
                                root: validated
                            )
                        }
                        if !computedDivergence.isEmpty {
                            AnalysisCache.saveBranchDivergence(computedDivergence, root: validated)
                        }
                    }
                }

                return RepositoryAnalysis(
                    root: validated,
                    info: info,
                    branches: branches,
                    tags: tags,
                    commits: commits,
                    allUnits: units,
                    filesParsed: reusedFilesCount,
                    filesFailed: [],
                    generatedFiles: reusedGenerated,
                    historyDuration: 0,
                    parseDuration: 0,
                    factsDuration: factsDuration,
                    attribution: AttributionStats(matchedHunks: fullJoin.matchedHunks,
                                                  unmatchedHunks: fullJoin.unmatchedHunks,
                                                  unresolvedHunks: fullJoin.unresolvedPaths),
                    source: .cached,
                    workingState: workingState,
                    fullChurn: fullJoin,
                    precomputedOwnership: precomputedOwnership,
                    precomputedContributors: precomputedContributors,
                    hasCodeUnits: true
                )
            }
        }

        // Progressive path: emit facts immediately, then history, then scanned files.
        partial(RepositoryAnalysis(
            root: validated, info: info, branches: branches, tags: tags,
            commits: [], allUnits: [], filesParsed: 0, filesFailed: [], generatedFiles: [],
            historyDuration: 0, parseDuration: 0, factsDuration: factsDuration,
            attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
            source: .fresh, workingState: workingState,
            hasCodeUnits: false), .factsOnly)

        progress(LoadingProgress(stage: "Reading history",
                                 detail: cached == nil ? "every commit, first time for this project"
                                                       : "only what is new since last time"))
        let historyStart = Date()
        var source = AnalysisSource.fresh
        let resolvedCommits: [Commit]
        if let cached, cached.headSHA == head {
            resolvedCommits = cached.commits
            source = .cached
        } else if useCache, !head.isEmpty,
                  let headSHAs = repository.revListSHAs(),
                  let poolCommits = AnalysisCache.loadCommits(orderedSHAs: headSHAs, root: validated) {
            resolvedCommits = poolCommits
            source = .cached
        } else if let cached, !cached.headSHA.isEmpty, repository.isAncestor(cached.headSHA, of: head) {
            let since = cached.headSHA
            let newCommits = try await repository.loadHistoryAsync(since: since)
            resolvedCommits = newCommits + cached.commits
            source = .incremental(newCommits: newCommits.count)
        } else {
            resolvedCommits = try await repository.loadHistoryAsync()
        }
        let commits = resolvedCommits
        let historyDuration = Date().timeIntervalSince(historyStart)
        let currentPaths = Set(info.inventory.files.map(\.path))
        async let contributorsTask = Task.detached(priority: .userInitiated) { [commits] in
            ContributorStats.compute(commits: commits)
        }.value
        async let ownershipTask = Task.detached(priority: .userInitiated) { [commits, currentPaths] in
            OwnershipBuilder.build(commits: commits, currentPaths: currentPaths)
        }.value
        let precomputedContributors = await contributorsTask
        let precomputedOwnership = await ownershipTask

        if !includeCodeAnalysis {
            if useCache {
                let needsSave = snapshot.matchingPayload?.headSHA != head
                if needsSave || !computedDivergence.isEmpty {
                    let commitsSnapshot = commits
                    Task.detached(priority: .utility) {
                        if needsSave {
                            AnalysisCache.save(
                                headSHA: head,
                                commits: commitsSnapshot,
                                fileEntries: nil,
                                root: validated
                            )
                        }
                        if !computedDivergence.isEmpty {
                            AnalysisCache.saveBranchDivergence(computedDivergence, root: validated)
                        }
                    }
                }
            }
            return RepositoryAnalysis(
                root: validated,
                info: info,
                branches: branches,
                tags: tags,
                commits: commits,
                allUnits: [],
                filesParsed: 0,
                filesFailed: [],
                generatedFiles: [],
                historyDuration: historyDuration,
                parseDuration: 0,
                factsDuration: factsDuration,
                attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
                source: source,
                workingState: workingState,
                fullChurn: nil,
                precomputedOwnership: precomputedOwnership,
                precomputedContributors: precomputedContributors,
                hasCodeUnits: false
            )
        }

        partial(RepositoryAnalysis(
            root: validated, info: info, branches: branches, tags: tags,
            commits: commits, allUnits: [], filesParsed: 0, filesFailed: [], generatedFiles: [],
            historyDuration: historyDuration, parseDuration: 0, factsDuration: factsDuration,
            attribution: AttributionStats(matchedHunks: 0, unmatchedHunks: 0, unresolvedHunks: 0),
            source: source, workingState: workingState,
            fullChurn: nil,
            precomputedOwnership: precomputedOwnership,
            precomputedContributors: precomputedContributors,
            hasCodeUnits: false), .withHistory)

        let parseStart = Date()
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
            let needsSave = snapshot.matchingPayload?.headSHA != head
                || !dirtyPaths.isEmpty
                || cachedFileUnits.count != fileEntries.count
            if needsSave || !computedDivergence.isEmpty {
                let commitsSnapshot = commits
                Task.detached(priority: .utility) {
                    if needsSave {
                        AnalysisCache.save(
                            headSHA: head,
                            commits: commitsSnapshot,
                            fileEntries: fileEntries,
                            root: validated
                        )
                    }
                    if !computedDivergence.isEmpty {
                        AnalysisCache.saveBranchDivergence(computedDivergence, root: validated)
                    }
                }
            }
        }

        // Join once over all parsed units off the main actor; RiskStore reuses this index.
        let parsedUnits = report.units
        let fullJoin = await Task.detached(priority: .userInitiated) { [parsedUnits, commits] in
            ChurnJoiner.join(units: parsedUnits, commits: commits)
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
            precomputedContributors: precomputedContributors,
            hasCodeUnits: true
        )
    }

    /// Hydrates source AST parsing and function-level churn on demand when switching from Standard to Advanced mode.
    static func loadCodeUnits(
        for analysis: RepositoryAnalysis,
        useCache: Bool = true,
        progress: @escaping @Sendable (LoadingProgress) -> Void = { _ in }
    ) async throws -> RepositoryAnalysis {
        let root = analysis.root
        let cachedFileUnits = useCache
            ? await Task.detached(priority: .userInitiated) { AnalysisCache.loadFileUnits(root: root) }.value
            : [:]
        let parsableTracked = analysis.info.inventory.files.filter { file in
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

        let parseStart = Date()
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
            let scanned = try await SourceScanner().scan(root: root, trackedPaths: dirtyPaths) { parsed, total in
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
        }
        let parseDuration = Date().timeIntervalSince(parseStart)

        let units = report.units
        let commits = analysis.commits
        let fullJoin = await Task.detached(priority: .userInitiated) { [units, commits] in
            ChurnJoiner.join(units: units, commits: commits)
        }.value

        if useCache {
            let head = analysis.commits.first?.sha ?? ""
            let unitsByPath = Dictionary(grouping: units, by: \.filePath)
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
            if !dirtyPaths.isEmpty || cachedFileUnits.count != fileEntries.count {
                Task.detached(priority: .utility) {
                    AnalysisCache.save(headSHA: head, commits: commits, fileEntries: fileEntries, root: root)
                }
            }
        }

        return RepositoryAnalysis(
            root: root,
            info: analysis.info,
            branches: analysis.branches,
            tags: analysis.tags,
            commits: commits,
            allUnits: units,
            filesParsed: report.filesParsed,
            filesFailed: report.filesFailed,
            generatedFiles: report.generatedFiles,
            historyDuration: analysis.historyDuration,
            parseDuration: parseDuration,
            factsDuration: analysis.factsDuration,
            attribution: AttributionStats(
                matchedHunks: fullJoin.matchedHunks,
                unmatchedHunks: fullJoin.unmatchedHunks,
                unresolvedHunks: fullJoin.unresolvedPaths
            ),
            source: analysis.source,
            workingState: analysis.workingState,
            fullChurn: fullJoin,
            precomputedOwnership: analysis.precomputedOwnership,
            precomputedContributors: analysis.precomputedContributors,
            hasCodeUnits: true
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
