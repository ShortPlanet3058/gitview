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
        didSet { rebuildCoupling() }
    }

    var couplingViewMode: CouplingViewMode = .list

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
    @ObservationIgnored private var graphLayoutGeneration = 0

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func resetForOpen() {
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
    }

    func update(analysis: RepositoryAnalysis, unitsByID: [UUID: CodeUnit], isComplete: Bool) {
        self.latestAnalysis = analysis
        self.latestUnitsByID = unitsByID
        self.latestIsComplete = isComplete
        rebuildFromCached()
    }

    func rebuildFromCached() {
        guard let analysis = latestAnalysis else { return }
        fullRebuildCount += 1

        let before = analysis.allUnits.count
        var units = analysis.allUnits
        if preferences.excludeTests {
            units = units.filter { !PathClassifier.isTest(path: $0.filePath) }
        }
        if preferences.excludeGenerated {
            units = units.filter { !analysis.generatedFiles.contains($0.filePath) }
        }
        let fragments = preferences.ignoredPaths
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !fragments.isEmpty {
            units = units.filter { unit in !fragments.contains { unit.filePath.contains($0) } }
        }
        excludedUnitCount = before - units.count
        units = units.filter { kindFilter.matches($0.kind) }

        let index = ChurnJoiner.join(units: units, commits: analysis.commits)
        let now = Date()
        let model = RiskModel(halfLife: preferences.halfLifeDays * 86_400)
        var ranked = model.rank(units: units, churn: index, now: now)
        ranked = ranked.filter { $0.commitCount >= preferences.minimumCommits }

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

        let windowDays = preferences.halfLifeDays * 2
        let windowStart = now.addingTimeInterval(-windowDays * 86_400)
        let windowLabel = RiskExplanation.windowLabel(days: windowDays)
        recentWindowLabel = windowLabel

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
        levelCounts = Dictionary(grouping: built, by: \.level).mapValues(\.count)

        guard latestIsComplete else {
            health = nil
            fileTree = FileTree(files: analysis.info.inventory.files, rows: [])
            return
        }

        let ninetyDays = now.addingTimeInterval(-90 * 86_400)
        let isStale = { (b: BranchInfo) in !b.isDefault && !b.isMerged && b.date < ninetyDays }
        health = RepositoryHealth.assess(.init(
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

        allRankedRows = built
        allRankedRowsByID = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        fileTree = FileTree(files: analysis.info.inventory.files, rows: built)
        churn = index

        applySearchFilter()
        rebuildCoupling()
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
        let analyzer = CouplingAnalyzer(
            maxUnitsPerCommit: 50,
            minSharedCommits: preferences.minSharedCommits,
            halfLife: preferences.halfLifeDays * 86_400
        )
        let unitsInJoin = allRankedRows.map(\.id).compactMap { latestUnitsByID[$0] }
        let index = analyzer.analyze(units: unitsInJoin, churn: churn, now: Date())
        coupling = index

        let built: [CouplingRow] = index.pairs.filter(couplingScope.matches).compactMap { pair in
            guard let a = latestUnitsByID[pair.a], let b = latestUnitsByID[pair.b] else { return nil }
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
        couplingRows = built
        couplingRowsByID = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        onCouplingChanged?(built, couplingRowsByID)
        rebuildGraph()
    }

    private func rebuildGraph() {
        guard let churn else {
            graph = nil
            graphPositions = [:]
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
