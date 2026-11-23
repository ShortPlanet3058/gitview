import Foundation
import CoreGraphics
import Observation
import GitViewCore
import GitViewGit

/// Owns the risk ranking, health score, memoized file tree, and coupling graph.
///
/// Decouples UI search filtering (`searchText`) from the expensive `ChurnJoiner` +
/// `RiskModel` + `CouplingAnalyzer` + `ForceDirectedLayout` rebuild so typing into the
/// Hotspots search box runs an O(N) filter pass instead of re-joining git history.
@MainActor
@Observable
final class RiskStore {
    enum KindFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case functions = "Functions"
        case methods = "Methods"
        var id: String { rawValue }

        func matches(_ kind: CodeUnit.Kind) -> Bool {
            switch self {
            case .all: return true
            case .functions: return kind == .function
            case .methods: return kind == .method
            }
        }
    }

    enum CouplingViewMode: String, CaseIterable, Sendable {
        case list = "List"
        case graph = "Graph"
    }

    enum CouplingScope: String, CaseIterable, Identifiable, Sendable {
        case crossDirectory = "Across folders"
        case crossFile = "Across files"
        case all = "All"
        var id: String { rawValue }

        func matches(_ pair: CouplingPair) -> Bool {
            switch self {
            case .crossDirectory: return pair.crossDirectory
            case .crossFile: return pair.crossFile
            case .all: return true
            }
        }
    }

    static let graphEdgeCap = 200

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var latestAnalysis: RepositoryAnalysis?
    @ObservationIgnored private var latestUnitsByID: [UUID: CodeUnit] = [:]
    @ObservationIgnored private var latestIsComplete = false

    @ObservationIgnored var onRowsChanged: ((_ rows: [RiskRow], _ rowsByID: [UUID: RiskRow]) -> Void)?
    @ObservationIgnored var onCouplingChanged: ((_ pairs: [CouplingRow], _ byID: [String: CouplingRow]) -> Void)?

    /// Instrumentation counters for automated verification that `searchText` does not trigger `rebuild`.
    @ObservationIgnored private(set) var fullRebuildCount = 0
    @ObservationIgnored private(set) var searchFilterCount = 0

    var kindFilter: KindFilter = .all {
        didSet { rebuildFromCached() }
    }

    var searchText: String = "" {
        didSet { applySearchFilter() }
    }

    var couplingScope: CouplingScope = .crossDirectory {
        didSet {
            if latestAnalysis != nil, churn != nil {
                rebuildCouplingInBackground()
            }
        }
    }

    var couplingViewMode: CouplingViewMode = .list {
        didSet {
            if couplingViewMode == .graph {
                ensureGraphLayoutIfNeeded()
            }
        }
    }

    private(set) var excludedUnitCount = 0
    private(set) var allRankedRows: [RiskRow] = []
    private(set) var allRankedRowsByID: [UUID: RiskRow] = [:]
    private(set) var rows: [RiskRow] = []
    private(set) var rowsByID: [UUID: RiskRow] = [:]
    private(set) var levelCounts: [RiskLevel: Int] = [:]
    private(set) var health: RepositoryHealth?
    private(set) var churn: ChurnIndex?
    private(set) var recentWindowLabel = "the last 2 years"
    private(set) var fileTree: FileTree?

    private(set) var coupling: CouplingIndex?
    private(set) var couplingRows: [CouplingRow] = []
    private(set) var couplingRowsByID: [String: CouplingRow] = [:]
    private(set) var graph: CouplingGraph?
    private(set) var graphPositions: [UUID: CGPoint] = [:]
    private(set) var graphLayoutInProgress = false
    private(set) var analysisRebuildInProgress = false
    @ObservationIgnored private var graphLayoutGeneration = 0
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var backgroundRebuildTask: Task<Void, Never>?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func resetForOpen() {
        backgroundRebuildTask?.cancel()
        backgroundRebuildTask = nil
        rebuildGeneration += 1
        graphLayoutGeneration += 1
        latestAnalysis = nil
        latestUnitsByID = [:]
        latestIsComplete = false
        allRankedRows = []
        allRankedRowsByID = [:]
        rows = []
        rowsByID = [:]
        levelCounts = [:]
        excludedUnitCount = 0
        health = nil
        churn = nil
        fileTree = nil
        coupling = nil
        couplingRows = []
        couplingRowsByID = [:]
        graph = nil
        graphPositions = [:]
        graphLayoutInProgress = false
        analysisRebuildInProgress = false
    }

    func update(analysis: RepositoryAnalysis, unitsByID: [UUID: CodeUnit], isComplete: Bool) {
        backgroundRebuildTask?.cancel()
        backgroundRebuildTask = nil
        rebuildGeneration += 1
        analysisRebuildInProgress = false
        self.latestAnalysis = analysis
        self.latestUnitsByID = unitsByID
        self.latestIsComplete = isComplete
        rebuildFromCached()
    }

    /// Runs risk ranking, health, file tree, and coupling calculations off `@MainActor`.
    func updateInBackground(analysis: RepositoryAnalysis, unitsByID: [UUID: CodeUnit], isComplete: Bool) {
        self.latestAnalysis = analysis
        self.latestUnitsByID = unitsByID
        self.latestIsComplete = isComplete
        rebuildInBackground()
    }

    private struct ConfigSnapshot: Sendable {
        let halfLifeDays: Double
        let excludeTests: Bool
        let excludeGenerated: Bool
        let ignoredPaths: String
        let minimumCommits: Int
        let minSharedCommits: Int
        let kindFilter: KindFilter
        let couplingScope: CouplingScope
    }

    private func configSnapshot() -> ConfigSnapshot {
        ConfigSnapshot(
            halfLifeDays: preferences.halfLifeDays,
            excludeTests: preferences.excludeTests,
            excludeGenerated: preferences.excludeGenerated,
            ignoredPaths: preferences.ignoredPaths,
            minimumCommits: preferences.minimumCommits,
            minSharedCommits: preferences.minSharedCommits,
            kindFilter: kindFilter,
            couplingScope: couplingScope
        )
    }

    private struct RankingOutput: Sendable {
        let excludedUnitCount: Int
        let recentWindowLabel: String
        let levelCounts: [RiskLevel: Int]
        let health: RepositoryHealth?
        let allRankedRows: [RiskRow]
        let allRankedRowsByID: [UUID: RiskRow]
        let fileTree: FileTree?
        let churn: ChurnIndex
    }

    private struct CouplingOutput: Sendable {
        let coupling: CouplingIndex
        let couplingRows: [CouplingRow]
        let couplingRowsByID: [String: CouplingRow]
    }

    func rebuildFromCached() {
        guard let analysis = latestAnalysis else { return }
        fullRebuildCount += 1
        let output = Self.computeRanking(analysis: analysis, config: configSnapshot(), isComplete: latestIsComplete)
        applyRankingOutput(output, isComplete: latestIsComplete)
        if latestIsComplete {
            rebuildCoupling()
        }
    }

    /// Recomputes risk ranking, health, FileTree, and coupling off the main actor.
    func rebuildInBackground() {
        guard let analysis = latestAnalysis else { return }
        fullRebuildCount += 1
        let config = configSnapshot()
        let unitsSnapshot = latestUnitsByID
        let complete = latestIsComplete
        backgroundRebuildTask?.cancel()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        analysisRebuildInProgress = true

        backgroundRebuildTask = Task {
            let ranked = await Task.detached(priority: .userInitiated) {
                Self.computeRanking(analysis: analysis, config: config, isComplete: complete)
            }.value
            guard !Task.isCancelled, generation == self.rebuildGeneration else { return }
            let coupled: CouplingOutput? = complete ? await Task.detached(priority: .userInitiated) {
                Self.computeCoupling(
                    units: unitsSnapshot,
                    rankedIDs: ranked.allRankedRows.map(\.id),
                    churn: ranked.churn,
                    config: config
                )
            }.value : nil
            guard !Task.isCancelled, generation == self.rebuildGeneration else { return }
            self.analysisRebuildInProgress = false
            self.applyRankingOutput(ranked, isComplete: complete)
            if let coupled {
                self.applyCouplingOutput(coupled)
            }
        }
    }

    func rebuildCouplingInBackground() {
        guard let churn, latestAnalysis != nil else { return }
        let config = configSnapshot()
        let unitsSnapshot = latestUnitsByID
        let rankedIDs = allRankedRows.map(\.id)
        backgroundRebuildTask?.cancel()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        analysisRebuildInProgress = true

        backgroundRebuildTask = Task {
            let coupled = await Task.detached(priority: .userInitiated) {
                Self.computeCoupling(units: unitsSnapshot, rankedIDs: rankedIDs, churn: churn, config: config)
            }.value
            guard !Task.isCancelled, generation == self.rebuildGeneration else { return }
            self.analysisRebuildInProgress = false
            self.applyCouplingOutput(coupled)
        }
    }

    private func applyRankingOutput(_ output: RankingOutput, isComplete: Bool) {
        excludedUnitCount = output.excludedUnitCount
        recentWindowLabel = output.recentWindowLabel
        levelCounts = output.levelCounts
        guard isComplete else {
            health = nil
            fileTree = output.fileTree
            return
        }
        health = output.health
        allRankedRows = output.allRankedRows
        allRankedRowsByID = output.allRankedRowsByID
        fileTree = output.fileTree
        churn = output.churn
        applySearchFilter()
    }

    private func applyCouplingOutput(_ output: CouplingOutput) {
        coupling = output.coupling
        couplingRows = output.couplingRows
        couplingRowsByID = output.couplingRowsByID
        graph = nil
        graphPositions = [:]
        graphLayoutInProgress = false
        graphLayoutGeneration += 1
        onCouplingChanged?(output.couplingRows, output.couplingRowsByID)
        if couplingViewMode == .graph {
            ensureGraphLayoutIfNeeded()
        }
    }

    nonisolated private static func computeRanking(analysis: RepositoryAnalysis,
                                               config: ConfigSnapshot,
                                               isComplete: Bool) -> RankingOutput {
        let before = analysis.allUnits.count
        var units = analysis.allUnits
        if config.excludeTests {
            units = units.filter { !PathClassifier.isTest(path: $0.filePath) }
        }
        if config.excludeGenerated {
            units = units.filter { !analysis.generatedFiles.contains($0.filePath) }
        }
        let fragments = config.ignoredPaths
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !fragments.isEmpty {
            units = units.filter { unit in !fragments.contains { unit.filePath.contains($0) } }
        }
        let excludedCount = before - units.count
        units = units.filter { config.kindFilter.matches($0.kind) }

        let index = analysis.fullChurn ?? ChurnJoiner.join(units: analysis.allUnits, commits: analysis.commits)
        let now = Date()
        let model = RiskModel(halfLife: config.halfLifeDays * 86_400)
        var ranked = model.rank(units: units, churn: index, now: now)
        ranked = ranked.filter { $0.commitCount >= config.minimumCommits }

        let levels = RiskLevel.assign(to: ranked)
        let complexities = ranked.map(\.unit.complexity).sorted()
        func percentile(_ complexity: Int) -> Double {
            guard !complexities.isEmpty else { return 0 }
            var low = 0, high = complexities.count
            while low < high {
                let mid = (low + high) / 2
                if complexities[mid] < complexity { low = mid + 1 } else { high = mid }
            }
            return Double(low) / Double(complexities.count)
        }

        let windowDays = config.halfLifeDays * 2
        let windowStart = now.addingTimeInterval(-windowDays * 86_400)
        let windowLabel = RiskExplanation.windowLabel(days: windowDays)

        let healthStart = now.addingTimeInterval(-RepositoryHealth.assessmentWindow)
        var complexTouches = 0, allTouches = 0, complexFunctions = 0

        var built: [RiskRow] = []
        built.reserveCapacity(ranked.count)
        for risked in ranked {
            let dates = index.commits(for: risked.unit).map(\.date)
            let healthTouches = dates.lazy.filter { $0 >= healthStart }.count
            if healthTouches > 0 {
                allTouches += healthTouches
                if risked.unit.complexity >= RepositoryHealth.complexThreshold {
                    complexTouches += healthTouches
                    complexFunctions += 1
                }
            }
            built.append(RiskRow(
                risked,
                level: levels[risked.unit.id] ?? .low,
                recentCommits: dates.lazy.filter { $0 >= windowStart }.count,
                complexityPercentile: percentile(risked.unit.complexity),
                window: windowLabel,
                now: now
            ))
        }
        let counts = Dictionary(grouping: built, by: \.level).mapValues(\.count)

        guard isComplete else {
            let partialTree = FileTree(files: analysis.info.inventory.files, rows: [])
            return RankingOutput(
                excludedUnitCount: excludedCount,
                recentWindowLabel: windowLabel,
                levelCounts: counts,
                health: nil,
                allRankedRows: [],
                allRankedRowsByID: [:],
                fileTree: partialTree,
                churn: index
            )
        }

        let ninetyDays = now.addingTimeInterval(-90 * 86_400)
        let isStale = { (b: BranchInfo) in !b.isDefault && !b.isMerged && b.date < ninetyDays }
        let healthValue = RepositoryHealth.assess(.init(
            lastCommit: analysis.commits.map(\.date).max(),
            activeAuthors: ContributorStats.activeAuthors(commits: analysis.commits, since: ninetyDays, excludingBots: true),
            staleLocalBranches: analysis.branches.filter { !$0.isRemote && isStale($0) }.count,
            localBranches: analysis.branches.filter { !$0.isRemote }.count,
            staleRemoteBranches: analysis.branches.filter { $0.isRemote && isStale($0) }.count,
            largeFiles: analysis.info.inventory.largeFiles.count,
            complexChurnShare: allTouches == 0 ? nil : Double(complexTouches) / Double(allTouches),
            complexFunctionsChanged: complexFunctions,
            now: now
        ))

        let rowsByID = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        let tree = FileTree(files: analysis.info.inventory.files, rows: built)
        return RankingOutput(
            excludedUnitCount: excludedCount,
            recentWindowLabel: windowLabel,
            levelCounts: counts,
            health: healthValue,
            allRankedRows: built,
            allRankedRowsByID: rowsByID,
            fileTree: tree,
            churn: index
        )
    }

    nonisolated private static func computeCoupling(units: [UUID: CodeUnit],
                                                rankedIDs: [UUID],
                                                churn: ChurnIndex,
                                                config: ConfigSnapshot) -> CouplingOutput {
        let analyzer = CouplingAnalyzer(
            maxUnitsPerCommit: 50,
            minSharedCommits: config.minSharedCommits,
            halfLife: config.halfLifeDays * 86_400
        )
        let unitsInJoin = rankedIDs.compactMap { units[$0] }
        let index = analyzer.analyze(units: unitsInJoin, churn: churn, now: Date())

        let built: [CouplingRow] = index.pairs.filter(config.couplingScope.matches).compactMap { pair in
            guard let a = units[pair.a], let b = units[pair.b] else { return nil }
            let commitsA = churn.commitCount(for: a), commitsB = churn.commitCount(for: b)
            let anchor = commitsA <= commitsB ? a : b
            return CouplingRow(
                id: pair.id,
                pair: pair,
                nameA: a.name,
                locationA: "\(a.filePath):\(a.lineRange.lowerBound)",
                nameB: b.name,
                locationB: "\(b.filePath):\(b.lineRange.lowerBound)",
                anchorName: anchor.name,
                anchorCommits: min(commitsA, commitsB)
            )
        }
        return CouplingOutput(
            coupling: index,
            couplingRows: built,
            couplingRowsByID: Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        )
    }

    /// Filters `allRankedRows` by `searchText` in O(N) without touching git history or layouts.
    func applySearchFilter() {
        searchFilterCount += 1
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered: [RiskRow]
        if query.isEmpty {
            filtered = allRankedRows
        } else {
            filtered = allRankedRows.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.filePath.localizedCaseInsensitiveContains(query)
            }
        }
        rows = filtered
        rowsByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        onRowsChanged?(filtered, rowsByID)
    }

    func rebuildCoupling() {
        guard let churn, latestAnalysis != nil else { return }
        let output = Self.computeCoupling(
            units: latestUnitsByID,
            rankedIDs: allRankedRows.map(\.id),
            churn: churn,
            config: configSnapshot()
        )
        applyCouplingOutput(output)
    }

    /// Lazily builds `CouplingGraph` and runs `ForceDirectedLayout` only when graph mode is viewed.
    func ensureGraphLayoutIfNeeded() {
        guard graph == nil, !graphLayoutInProgress else { return }
        rebuildGraph()
    }

    private func rebuildGraph() {
        guard let churn else {
            graph = nil
            graphPositions = [:]
            graphLayoutInProgress = false
            return
        }
        let unitsSnapshot = latestUnitsByID
        let built = CouplingGraph(
            pairs: couplingRows.map(\.pair),
            maxEdges: Self.graphEdgeCap,
            unit: { unitsSnapshot[$0] },
            size: { id in Double(unitsSnapshot[id].map { churn.commitCount(for: $0) } ?? 1) }
        )
        graph = built
        graphLayoutGeneration += 1
        let generation = graphLayoutGeneration
        graphLayoutInProgress = true
        Task.detached(priority: .userInitiated) { [built] in
            var layout = ForceDirectedLayout(graph: built)
            layout.settle(maxIterations: 300)
            let positions = layout.positions.mapValues { CGPoint(x: $0.x, y: $0.y) }
            await MainActor.run { [positions] in
                guard generation == self.graphLayoutGeneration else { return }
                self.graphPositions = positions
                self.graphLayoutInProgress = false
            }
        }
    }
}
