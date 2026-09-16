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
        case overview, commits, branches, releases, contributors, files, activity, hotspots, coupling, statistics
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .commits: return "Commits"
            case .branches: return "Branches"
            case .releases: return "Releases"
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
            case .releases: return "tag"
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
    /// Vendored and machine-generated code is excluded by default: nobody in this
    /// repository is going to refactor it, and generated parsers are large enough to
    /// dominate the hotspot list (swift-nio's bundled llhttp scores 1298).
    @Published var excludeGenerated: Bool = UserDefaults.standard.object(forKey: "excludeGenerated") as? Bool ?? true {
        didSet { UserDefaults.standard.set(excludeGenerated, forKey: "excludeGenerated"); rebuild() }
    }
    /// Extra path fragments to ignore, for vendored code that carries no marker.
    @Published var ignoredPaths: String = UserDefaults.standard.string(forKey: "ignoredPaths") ?? "" {
        didSet { UserDefaults.standard.set(ignoredPaths, forKey: "ignoredPaths"); rebuild() }
    }
    @Published private(set) var excludedUnitCount = 0
    @Published var kindFilter: KindFilter = .all { didSet { rebuild() } }
    @Published var minimumCommits = 1 { didSet { rebuild() } }
    @Published var searchText = "" { didSet { rebuild() } }

    @Published private(set) var rows: [RiskRow] = []
    @Published private(set) var rowsByID: [UUID: RiskRow] = [:]
    @Published private(set) var levelCounts: [RiskLevel: Int] = [:]
    @Published private(set) var health: RepositoryHealth?
    /// What changed since the last time this repository was opened.
    @Published private(set) var catchUp: CatchUp?
    /// Who has changed what, built once from history — independent of the risk filters.
    @Published private(set) var ownership: OwnershipIndex?
    /// The contributor whose detail panel is open.
    @Published var selectedAuthor: String?
    // Comparing two points: the release question and the "what changed between" question
    // are the same one.
    @Published var compareFrom: String = ""
    @Published var compareTo: String = "HEAD"
    @Published private(set) var comparison: ComparisonResult?
    @Published private(set) var comparisonInFlight = false

    /// Line-level ownership, computed on demand because it costs a process per file.
    @Published private(set) var blame: [String: BlameOwnership] = [:]
    @Published private(set) var blameInFlight: Set<String> = []
    /// Who "you" are. Taken from git config, overridable because the config name and the
    /// name in the history do not always agree.
    @Published var identityName: String = UserDefaults.standard.string(forKey: "identityName") ?? "" {
        didSet {
            UserDefaults.standard.set(identityName, forKey: "identityName")
            rebuildCatchUp()
        }
    }
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
    /// The commit whose detail panel is open, if any.
    @Published var selectedCommitSHA: String?

    var selectedCommit: Commit? {
        guard let sha = selectedCommitSHA else { return nil }
        return analysis?.commits.first { $0.sha == sha }
    }

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
    /// Commit prefix from `--select-commit`, resolved once history is loaded.
    var pendingCommitSelection: String?
    /// Path prefix from `--select-file`, consumed by the Files screen.
    @Published var pendingFileSelection: String?
    var pendingAuthorSelection: String?
    var pendingCompare: String?
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

    init() {
        applyLaunchArguments()
    }

    /// `GitView --repo <path> [--screen <name>] [--mode standard|advanced] [--view list|graph]
    /// [--select <unit>] [--select-pair <name>]`.
    ///
    /// Applied here rather than from a view's `onAppear`, because a window opened in the
    /// background may never appear and the arguments would silently do nothing.
    ///
    /// Every flag takes a value on purpose: AppKit pairs `-key value` from argv, so a
    /// valueless flag followed by a key/value pair leaves a token it treats as a document
    /// to open — and SwiftUI then withholds the WindowGroup's default window entirely.
    private func applyLaunchArguments() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        pendingSelection = value("--select")
        pendingPairSelection = value("--select-pair")
        pendingCommitSelection = value("--select-commit")
        // Pending rather than direct: `open` clears every selection, and it runs after this.
        pendingAuthorSelection = value("--select-author")
        pendingCompare = value("--compare")   // "from..to"
        pendingFileSelection = value("--select-file")
        if let name = value("--screen"), let screen = Screen(rawValue: name) { self.screen = screen }
        if let mode = value("--mode") { advanced = mode == "advanced" }
        if let view = value("--view") { couplingViewMode = view == "graph" ? .graph : .list }
        DebugScreenshot.scheduleIfRequested(model: self)
        if let path = value("--repo").map({ ($0 as NSString).expandingTildeInPath }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                open(url: URL(fileURLWithPath: path))
            }
        }
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
        selectedCommitSHA = nil
        selectedAuthor = nil
        ownership = nil
        blame = [:]
        blameInFlight = []
        histories = [:]
        loadingHistories = []

        Task {
            do {
                let started = Date()
                let analysis = try await AnalysisService.load(root: url)
                // Printed so a run can be timed from the outside without guessing from
                // wall clock, which a screenshot delay would dominate.
                FileHandle.standardError.write(Data(
                    String(format: "gitview: analysis %@ — history %.2fs, parse %.2fs, facts %.2fs, total %.2fs\n",
                           analysis.source.summary, analysis.historyDuration, analysis.parseDuration,
                           analysis.factsDuration, Date().timeIntervalSince(started)).utf8))
                self.unitsByID = Dictionary(uniqueKeysWithValues: analysis.allUnits.map { ($0.id, $0) })
                self.contributors = ContributorStats.compute(commits: analysis.commits)
                self.rebuildCatchUp(for: analysis)
                if let wanted = self.pendingAuthorSelection {
                    self.pendingAuthorSelection = nil
                    self.selectedAuthor = self.contributors.first {
                        $0.name == wanted || $0.name.localizedCaseInsensitiveContains(wanted)
                    }?.name
                }
                self.ownership = OwnershipBuilder.build(
                    commits: analysis.commits,
                    currentPaths: Set(analysis.info.inventory.files.map(\.path)))
                if let prefix = self.pendingCommitSelection {
                    self.pendingCommitSelection = nil
                    self.selectedCommitSHA = analysis.commits.first {
                        $0.sha.hasPrefix(prefix) || $0.subject.localizedCaseInsensitiveContains(prefix)
                    }?.sha
                }
                self.state = .loaded(analysis)
                self.rebuild()
                // After `state` is set: runComparison reads `analysis`, which is nil until then.
                if let spec = self.pendingCompare {
                    self.pendingCompare = nil
                    let parts = spec.components(separatedBy: "..")
                    if parts.count == 2 {
                        self.compareFrom = parts[0]
                        self.compareTo = parts[1]
                        self.runComparison()
                    }
                }
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

        let before = analysis.allUnits.count
        var units = analysis.allUnits
        if excludeTests {
            units = units.filter { !PathClassifier.isTest(path: $0.filePath) }
        }
        if excludeGenerated {
            units = units.filter { !analysis.generatedFiles.contains($0.filePath) }
        }
        let fragments = ignoredPaths.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !fragments.isEmpty {
            units = units.filter { unit in !fragments.contains { unit.filePath.contains($0) } }
        }
        excludedUnitCount = before - units.count
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

    /// Recomputes the catch-up from the current identity and the recorded last visit.
    func rebuildCatchUp(for analysis: RepositoryAnalysis? = nil) {
        guard let analysis = analysis ?? self.analysis else { return }
        let visit = VisitLog.lastVisit(to: analysis.root)
        catchUp = CatchUpBuilder.build(commits: analysis.commits, lastVisit: visit,
                                       identity: identity(for: analysis), now: Date())
        // On a first ever visit, record a baseline straight away so the next open can say
        // what happened in between. Later visits are only marked when the person says so.
        if visit == nil, let head = analysis.commits.first?.sha {
            VisitLog.record(headSHA: head, to: analysis.root)
        }
    }

    /// Names to treat as "you": an explicit override if set, otherwise git config, keeping
    /// only names that actually appear in this history so a typo cannot silently match none.
    private func identity(for analysis: RepositoryAnalysis) -> Identity {
        let known = Set(contributors.map(\.name))
        if !identityName.isEmpty { return Identity(names: [identityName]) }
        let configured = analysis.info.configuredUserNames.filter { known.contains($0) }
        return Identity(names: configured)
    }

    /// Marks everything currently shown as seen, so the next visit starts from here.
    func markCatchUpSeen() {
        guard let analysis, let head = analysis.commits.first?.sha else { return }
        VisitLog.record(headSHA: head, to: analysis.root)
        rebuildCatchUp()
    }

    /// Commits between two tags, derived from the history already in memory rather than
    /// with a `rev-list` per tag — 188 tags would otherwise cost a process each.
    func commitsBetweenTags() -> [String: Int] {
        guard let analysis else { return [:] }
        var indexBySHA: [String: Int] = [:]
        for (index, commit) in analysis.commits.enumerated() { indexBySHA[commit.sha] = index }
        var result: [String: Int] = [:]
        let reachable = analysis.tags.compactMap { tag -> (String, Int)? in
            indexBySHA[tag.commitSHA].map { (tag.name, $0) }
        }
        // Tags are newest first, so the *next* one in the list is the previous release.
        for (offset, entry) in reachable.enumerated() {
            let previousIndex = offset + 1 < reachable.count ? reachable[offset + 1].1 : analysis.commits.count
            result[entry.0] = max(previousIndex - entry.1, 0)
        }
        return result
    }

    /// Commits on HEAD that no tag contains yet.
    var unreleasedCount: Int? {
        guard let analysis, let latest = analysis.tags.first else { return nil }
        guard let index = analysis.commits.firstIndex(where: { $0.sha == latest.commitSHA }) else { return nil }
        return index
    }

    func runComparison() {
        guard let analysis, !compareFrom.isEmpty, !comparisonInFlight else { return }
        let root = analysis.root
        let from = compareFrom, to = compareTo
        comparisonInFlight = true
        Task.detached(priority: .userInitiated) {
            let repository = GitRepository(url: root)
            let commits = (try? repository.commits(from: from, to: to)) ?? []
            let deltas = (try? repository.fileDeltas(from: from, to: to)) ?? []
            let result = ComparisonResult(from: from, to: to, commits: commits, deltas: deltas)
            await MainActor.run {
                self.comparison = result
                self.comparisonInFlight = false
            }
        }
    }

    /// Computes line-level ownership for one file, once. About a quarter of a second, so it
    /// is only ever done for the file being looked at.
    func loadBlame(for path: String) {
        guard let analysis, blame[path] == nil, !blameInFlight.contains(path) else { return }
        blameInFlight.insert(path)
        let root = analysis.root
        Task.detached(priority: .userInitiated) {
            let result = try? GitRepository(url: root).blame(path: path)
            await MainActor.run {
                if let result { self.blame[path] = result }
                self.blameInFlight.remove(path)
            }
        }
    }

    /// Re-reads `git status`. Cheap, so it runs whenever the app comes forward.
    func refreshWorkingState() {
        guard case .loaded(var analysis) = state else { return }
        let root = analysis.root
        Task.detached(priority: .utility) {
            let fresh = (try? GitRepository(url: root).workingState()) ?? .clean
            await MainActor.run {
                guard case .loaded(var current) = self.state, current.root == root else { return }
                current.workingState = fresh
                self.state = .loaded(current)
            }
        }
        _ = analysis
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
