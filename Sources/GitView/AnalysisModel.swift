import Foundation
import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

@MainActor
final class AnalysisModel: ObservableObject {
    enum State {
        case idle
        case loading(String)
        case loaded(RepositoryAnalysis)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    enum Screen: String, Hashable, CaseIterable {
        case overview, commits, branches, contributors, files, activity, hotspots, coupling, statistics
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .commits: return "Commits"
            case .branches: return "Branches"
            case .contributors: return "Contributors"
            case .files: return "Files"
            case .activity: return "Activity"
            case .hotspots: return "Hotspots"
            case .coupling: return "Change together"
            case .statistics: return "Statistics"
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .commits: return "clock.arrow.circlepath"
            case .branches: return "arrow.triangle.branch"
            case .contributors: return "person.2"
            case .files: return "doc.text"
            case .activity: return "chart.bar"
            case .hotspots: return "flame"
            case .coupling: return "link"
            case .statistics: return "function"
            }
        }
    }
    @Published var screen: Screen = .overview
    @Published var showSettings = false

    /// Progressive disclosure: off shows plain-language cards; on adds every metric, the
    /// sortable table, the half-life slider and model notes. Persisted across launches.
    @Published var advanced: Bool = UserDefaults.standard.bool(forKey: "advancedMode") {
        didSet { UserDefaults.standard.set(advanced, forKey: "advancedMode") }
    }

    // Model parameters. Changing any of these re-derives the ranking without touching git.
    @Published var halfLifeDays: Double = 365 { didSet { rebuild() } }
    @Published var excludeTests = true { didSet { rebuild() } }
    @Published var kindFilter: KindFilter = .all { didSet { rebuild() } }
    @Published var minimumCommits = 1 { didSet { rebuild() } }
    @Published var searchText = "" { didSet { rebuild() } }

    @Published private(set) var rows: [RiskRow] = []
    @Published private(set) var rowsByID: [UUID: RiskRow] = [:]
    @Published private(set) var levelCounts: [RiskLevel: Int] = [:]
    @Published private(set) var health: RepositoryHealth?
    /// Derived once per load; independent of the risk model's parameters.
    @Published private(set) var contributors: [Contributor] = []
    /// Prose for the window "recent changes" are counted in: two half-lives, so it tracks
    /// the model. "the last 2 years" at the default 365-day half-life.
    @Published private(set) var recentWindowLabel = "the last 2 years"
    /// Summed risk per directory (top two path components), highest first.
    @Published private(set) var directoryRisk: [(directory: String, score: Double, units: Int)] = []

    // Coupling
    @Published var couplingScope: CouplingScope = .crossDirectory { didSet { rebuildCoupling() } }
    @Published var minSharedCommits = 3 { didSet { rebuildCoupling() } }
    @Published private(set) var coupling: CouplingIndex?
    @Published private(set) var couplingRows: [CouplingRow] = []
    @Published private(set) var couplingRowsByID: [String: CouplingRow] = [:]
    @Published var selectedPairID: String?

    enum CouplingViewMode: String, CaseIterable { case list = "List", graph = "Graph" }
    @Published var couplingViewMode: CouplingViewMode = .list
    @Published private(set) var graph: CouplingGraph?
    /// Layout positions in abstract units; the view fits them to its size.
    @Published private(set) var graphPositions: [UUID: CGPoint] = [:]
    @Published private(set) var graphLayoutInProgress = false
    private var graphLayoutGeneration = 0
    static let graphEdgeCap = 200

    enum CouplingScope: String, CaseIterable, Identifiable {
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
    @Published private(set) var churn: ChurnIndex?
    private(set) var unitsByID: [UUID: CodeUnit] = [:]

    // Selection and the per-unit detail data derived on demand.
    @Published var selectedUnitID: UUID?
    @Published private(set) var histories: [UUID: [UnitComplexityPoint]] = [:]
    @Published private(set) var loadingHistories: Set<UUID> = []
    /// Name fragment from `--select`, applied once the first ranking is built.
    var pendingSelection: String?
    var pendingPairSelection: String?
    /// Rows before the search filter, so the sidebar can report how much is being hidden.
    @Published private(set) var matchedCount = 0
    @Published private(set) var totalRanked = 0

    enum KindFilter: String, CaseIterable, Identifiable {
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

    var analysis: RepositoryAnalysis? {
        if case .loaded(let analysis) = state { return analysis }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var selectedUnit: CodeUnit? { selectedUnitID.flatMap { unitsByID[$0] } }
    var selectedRow: RiskRow? { selectedUnitID.flatMap { rowsByID[$0] } }
    var selectedPair: CouplingRow? { selectedPairID.flatMap { couplingRowsByID[$0] } }

    func open(url: URL) {
        state = .loading("Reading history…")
        rows = []
        rowsByID = [:]
        churn = nil
        coupling = nil
        couplingRows = []
        couplingRowsByID = [:]
        selectedPairID = nil
        selectedUnitID = nil
        histories = [:]
        loadingHistories = []

        Task {
            do {
                let analysis = try await AnalysisService.load(root: url)
                self.unitsByID = Dictionary(uniqueKeysWithValues: analysis.allUnits.map { ($0.id, $0) })
                self.contributors = ContributorStats.compute(commits: analysis.commits)
                self.state = .loaded(analysis)
                self.rebuild()
            } catch {
                self.state = .failed("\(error)")
            }
        }
    }

    /// Re-derives the ranking from the cached analysis.
    ///
    /// The join is ~0.03s and ranking a few thousand units is milliseconds, so this is
    /// cheap enough to run synchronously as the half-life slider moves.
    private func rebuild() {
        guard let analysis else { return }

        var units = analysis.allUnits
        if excludeTests {
            units = units.filter { !PathClassifier.isTest(path: $0.filePath) }
        }
        units = units.filter { kindFilter.matches($0.kind) }

        // The join must see the filtered set: a unit excluded here must not keep a slot.
        let index = ChurnJoiner.join(units: units, commits: analysis.commits)
        let now = Date()
        let model = RiskModel(halfLife: halfLifeDays * 86_400)
        var ranked = model.rank(units: units, churn: index, now: now)
        ranked = ranked.filter { $0.commitCount >= minimumCommits }

        totalRanked = ranked.count
        let levels = RiskLevel.assign(to: ranked)

        // Complexity percentile: share of ranked units strictly less complex.
        let complexities = ranked.map(\.unit.complexity).sorted()
        func percentile(_ complexity: Int) -> Double {
            guard !complexities.isEmpty else { return 0 }
            var low = 0, high = complexities.count
            while low < high { let mid = (low + high) / 2; if complexities[mid] < complexity { low = mid + 1 } else { high = mid } }
            return Double(low) / Double(complexities.count)
        }
        let windowDays = halfLifeDays * 2
        let windowStart = now.addingTimeInterval(-windowDays * 86_400)
        let windowLabel = RiskExplanation.windowLabel(days: windowDays)
        recentWindowLabel = windowLabel

        // Health is assessed over its own fixed window so that moving the half-life slider
        // re-ranks functions without changing the repository's health score.
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
            built.append(RiskRow(risked,
                                 level: levels[risked.unit.id] ?? .low,
                                 recentCommits: dates.lazy.filter { $0 >= windowStart }.count,
                                 complexityPercentile: percentile(risked.unit.complexity),
                                 window: windowLabel,
                                 now: now))
        }
        levelCounts = Dictionary(grouping: built, by: \.level).mapValues(\.count)

        var byDirectory: [String: (score: Double, units: Int)] = [:]
        for row in built where row.level != .low {
            let parts = row.filePath.split(separator: "/")
            let key = parts.count > 2 ? parts.prefix(2).joined(separator: "/") : row.directory
            byDirectory[key, default: (0, 0)].score += row.score
            byDirectory[key, default: (0, 0)].units += 1
        }
        directoryRisk = byDirectory.map { ($0.key, $0.value.score, $0.value.units) }
            .sorted { $0.1 > $1.1 }

        // Health: the four repository checks plus GitView's own "complex code under change".
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
            now: now))

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            built = built.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.filePath.localizedCaseInsensitiveContains(query)
            }
        }
        matchedCount = built.count
        rows = built
        rowsByID = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        churn = index

        // A unit filtered out of the table has no row (and no churn in this join) to show.
        if let selected = selectedUnitID, rowsByID[selected] == nil {
            selectedUnitID = nil
        }
        if let fragment = pendingSelection {
            pendingSelection = nil
            selectedUnitID = built.first { $0.name == fragment }?.id
                ?? built.first { $0.name.hasSuffix("." + fragment) }?.id
                ?? built.first { $0.name.localizedCaseInsensitiveContains(fragment) }?.id
        }
        rebuildCoupling()
    }

    /// Coupling is derived from the same join; it only needs recomputing when the join
    /// or its own parameters change.
    private func rebuildCoupling() {
        guard let churn, analysis != nil else { return }
        let analyzer = CouplingAnalyzer(maxUnitsPerCommit: 50, minSharedCommits: minSharedCommits,
                                        halfLife: halfLifeDays * 86_400)
        let unitsInJoin = rows.map(\.id).compactMap { unitsByID[$0] }
        let index = analyzer.analyze(units: unitsInJoin, churn: churn, now: Date())
        coupling = index

        let built: [CouplingRow] = index.pairs.filter(couplingScope.matches).compactMap { pair in
            guard let a = unitsByID[pair.a], let b = unitsByID[pair.b] else { return nil }
            let commitsA = churn.commitCount(for: a), commitsB = churn.commitCount(for: b)
            let anchor = commitsA <= commitsB ? a : b
            return CouplingRow(id: pair.id, pair: pair,
                               nameA: a.name, locationA: "\(a.filePath):\(a.lineRange.lowerBound)",
                               nameB: b.name, locationB: "\(b.filePath):\(b.lineRange.lowerBound)",
                               anchorName: anchor.name, anchorCommits: min(commitsA, commitsB))
        }
        couplingRows = built
        couplingRowsByID = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        if let selected = selectedPairID, couplingRowsByID[selected] == nil { selectedPairID = nil }
        if let fragment = pendingPairSelection {
            pendingPairSelection = nil
            selectedPairID = built.first { $0.nameA.contains(fragment) || $0.nameB.contains(fragment) }?.id ?? built.first?.id
        }
        rebuildGraph()
    }

    /// Builds the graph from the pairs currently shown and lays it out off the main actor.
    /// Layout is a few hundred O(n²) iterations — tens of milliseconds for 200 nodes, but
    /// not something to do on the main thread while a slider is moving.
    private func rebuildGraph() {
        guard let churn else { graph = nil; graphPositions = [:]; return }
        let built = CouplingGraph(
            pairs: couplingRows.map(\.pair),
            maxEdges: Self.graphEdgeCap,
            unit: { self.unitsByID[$0] },
            size: { id in Double(self.unitsByID[id].map { churn.commitCount(for: $0) } ?? 1) }
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
                // A newer rebuild may have started meanwhile; only the latest result counts.
                guard generation == self.graphLayoutGeneration else { return }
                self.graphPositions = positions
                self.graphLayoutInProgress = false
            }
        }
    }

    /// Starts the per-revision re-parse for a unit, once. Results are cached for the
    /// lifetime of the loaded repository; the half-life and filters do not affect them.
    func ensureHistory(for unit: CodeUnit) {
        guard let analysis, let churn,
              histories[unit.id] == nil, !loadingHistories.contains(unit.id) else { return }
        loadingHistories.insert(unit.id)
        let root = analysis.root
        Task {
            let service = UnitHistoryService { sha, path in
                try GitProcess.capture(arguments: ["show", "\(sha):\(path)"], in: root)
            }
            let points = await service.complexityHistory(for: unit, churn: churn)
            self.histories[unit.id] = points
            self.loadingHistories.remove(unit.id)
        }
    }
}
