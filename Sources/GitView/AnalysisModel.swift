import Foundation
import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

@MainActor
final class AnalysisModel: ObservableObject {
    enum State {
        case idle
        case loading(LoadingProgress)
        case loaded(RepositoryAnalysis)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Something happened to the repository while GitView was showing it: a commit from a
    /// terminal, a pull, a checkout. Set only when the analysis on screen is genuinely out
    /// of date — never for a change GitView made itself, and never for an edit to a file,
    /// which changes what `git status` says but not what the history is.
    struct OutsideChange: Identifiable, Equatable {
        let id = UUID()
        /// Plain language, already counted: "3 new commits", "Now on feature/login".
        let summary: String
        /// False when the old tip is gone (a rebase or a force-push upstream), which is
        /// worth saying out loud because the numbers on screen describe commits that no
        /// longer exist.
        let isFastForward: Bool
    }
    @Published private(set) var outsideChange: OutsideChange?
    @Published private(set) var isRefreshing = false
    /// Which parts of the current analysis have arrived. Everything except the first
    /// moments of a load is `.complete`; screens consult it so that a page whose data is
    /// still being read says so instead of drawing a confident empty state.
    @Published private(set) var readiness: Readiness = .complete
    /// The stage the current read is in, for as long as one is running. Survives the move
    /// from the loading screen to the usable app: once the first results are on screen the
    /// loading screen is gone, and without this there would be nothing left saying that
    /// history and parsing are still going.
    @Published private(set) var loadProgress: LoadingProgress?
    /// A refresh that failed. Kept separate from `state` so a failed refresh leaves the
    /// working analysis on screen instead of replacing it with an error page.
    @Published var refreshError: String?
    /// What a just-completed automatic refresh brought in, shown briefly so an update that
    /// happens on its own is still something you saw happen rather than a number that
    /// changed while you were looking away.
    @Published private(set) var refreshNote: String?

    private var watcher: RepositoryWatcher?
    private var refreshNoteTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// When the current load started, so the loading screen can say how long it has been.
    @Published private(set) var loadStarted: Date?
    /// The repository a failed load was for, so "Try Again" knows what to try.
    private var lastAttempted: URL?

    enum Screen: String, Hashable, CaseIterable {
        case overview, changes, commits, branches, releases, contributors, files, activity, hotspots, coupling, statistics
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .changes: return "Changes"
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
            case .changes: return "pencil.and.list.clipboard"
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

    /// The screens the sidebar offers, in order. Menu shortcuts are numbered from this same
    /// list, so ⌘4 always lands on the fourth item someone can see rather than the fourth
    /// case in the enum.
    static let repositoryScreens: [Screen] = [.overview, .changes, .commits, .branches,
                                              .releases, .contributors, .files, .activity]
    var analysisScreens: [Screen] { advanced ? [.hotspots, .coupling, .statistics] : [.hotspots, .coupling] }
    var visibleScreens: [Screen] { Self.repositoryScreens + analysisScreens }

    /// Goes to `screen` the way clicking the sidebar should: whatever is layered over the
    /// current screen closes on the way out.
    ///
    /// A diff, a file's history or a set of search results covers the whole content area,
    /// so leaving them open across a tab change meant clicking "Commits" and still looking
    /// at a diff. Deliberately a method rather than a `didSet` on `screen`: the screen is
    /// also restored internally while loading and refreshing, and that must not throw away
    /// the selection it is in the middle of restoring.
    func show(_ screen: Screen) {
        diffRequest = nil
        fileHistoryPath = nil
        if isSearching { clearSearch() }
        selectedUnitID = nil
        selectedCommitSHA = nil
        selectedPairID = nil
        selectedAuthor = nil
        self.screen = screen
    }

    /// Leaves whatever is layered over the current screen, innermost first: a diff opened
    /// from a file's history returns to that history, not all the way out to the screen
    /// behind it. Returns false when there is nothing to leave.
    @discardableResult
    func goBack() -> Bool {
        if diffRequest != nil { diffRequest = nil; return true }
        if fileHistoryPath != nil { fileHistoryPath = nil; return true }
        if isSearching { clearSearch(); return true }
        if selectedUnitID != nil || selectedCommitSHA != nil || selectedPairID != nil || selectedAuthor != nil {
            selectedUnitID = nil; selectedCommitSHA = nil; selectedPairID = nil; selectedAuthor = nil
            return true
        }
        return false
    }

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
    // Writing. Every mutating call refreshes the working copy afterwards, and anything
    // that cannot be undone goes through a confirmation that names what will be lost.
    @Published var commitSubject = ""
    @Published var commitBody = ""
    @Published var stashMessage = ""
    @Published private(set) var writeInFlight = false
    @Published var writeError: String?
    @Published var confirmation: DestructiveConfirmation?
    @Published private(set) var pushPlan: GitRepository.PushPlan?

    // One file's life. Kept separate from the diff so that closing a diff returns here
    // rather than all the way out.
    @Published var fileHistoryPath: String? { didSet { loadFileHistory() } }
    @Published private(set) var fileHistory: [FileHistoryEntry] = []
    @Published private(set) var fileHistoryInFlight = false
    /// Cap on how far back a single file's history is read.
    static let fileHistoryLimit = 400
    /// True when the file has more history than was read, so the view can say so instead of
    /// presenting the cap as the total.
    var fileHistoryTruncated: Bool { fileHistory.count >= Self.fileHistoryLimit }

    // Viewing one file's diff. The request says what to diff; the result is loaded async.
    @Published var diffRequest: DiffRequest? { didSet { loadDiff() } }
    @Published private(set) var loadedDiff: FileDiff?
    @Published private(set) var diffInFlight = false
    /// Lines of context around each change, adjustable from the viewer.
    @Published var diffContext: Int = 3 { didSet { loadDiff() } }

    // Search. In-memory results are recomputed on every keystroke because they are just
    // array scans; the two git-backed searches are debounced behind them.
    @Published var globalSearch: String = "" {
        didSet { runSearch() }
    }
    @Published private(set) var searchResults: SearchResults?
    @Published private(set) var codeMatches: [CodeMatch] = []
    @Published private(set) var historyMatches: [Commit] = []
    @Published private(set) var deepSearchInFlight = false
    @Published var focusSearchRequest = 0
    private var deepSearchTask: Task<Void, Never>?

    /// True when there is something layered over the current screen to leave.
    var canGoBack: Bool {
        diffRequest != nil || fileHistoryPath != nil || isSearching
            || selectedUnitID != nil || selectedCommitSHA != nil
            || selectedPairID != nil || selectedAuthor != nil
    }

    /// True once a repository is on screen, so menu items that act on one can be disabled
    /// rather than silently doing nothing.
    var hasRepository: Bool { if case .loaded = state { return true }; return false }

    var isSearching: Bool { !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty }

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
    var pendingSearch: String?
    var pendingDiff: String?
    /// Debug only: navigate to this screen once everything else has been applied. Exists so
    /// that "changing tabs closes what is open" can be checked from a screenshot run rather
    /// than asserted — the app target has no tests of its own.
    var pendingThenShow: String?
    var pendingFileHistory: String?
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
        pendingSearch = value("--search")
        pendingDiff = value("--diff")          // "<sha>:<path>" or "working:<path>"
        pendingThenShow = value("--then-show")
        pendingFileHistory = value("--file-history")
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
        } else if !arguments.contains("--no-reopen"), let last = RecentRepositories.last() {
            // Reopening where you left off is the overwhelmingly common intent: almost
            // nobody opens a repository tool to look at nothing. The welcome screen is
            // still there on a first run, and `--no-reopen` gets it back for a screenshot.
            open(url: last)
        }
    }

    var selectedUnit: CodeUnit? { selectedUnitID.flatMap { unitsByID[$0] } }
    var selectedRow: RiskRow? { selectedUnitID.flatMap { rowsByID[$0] } }
    var selectedPair: CouplingRow? { selectedPairID.flatMap { couplingRowsByID[$0] } }

    func open(url: URL, preservingSelection: Bool = false) {
        let keptScreen = screen
        RecentRepositories.remember(url)
        startWatching(url)
        outsideChange = nil
        refreshError = nil
        lastAttempted = url
        loadStarted = Date()
        readiness = .factsOnly
        loadTask?.cancel()
        state = .loading(LoadingProgress(stage: "Checking the repository"))
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
        diffRequest = nil
        fileHistoryPath = nil
        ownership = nil
        blame = [:]
        blameInFlight = []
        histories = [:]
        loadingHistories = []

        loadTask = Task {
            do {
                let analysis = try await Self.loadReportingTiming(root: url) { progress in
                    Task { @MainActor in
                        // A late callback must not overwrite a finished analysis or a
                        // cancellation, so both the strip and the screen check first.
                        guard self.loadTask != nil else { return }
                        self.loadProgress = progress
                        if case .loading = self.state { self.state = .loading(progress) }
                    }
                } partial: { analysis, readiness in
                    Task { @MainActor in self.adoptPartial(analysis, readiness: readiness) }
                }
                guard !Task.isCancelled else { return }
                self.adopt(analysis, keptScreen: keptScreen, preservingSelection: preservingSelection)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed("\(error)")
            }
            self.loadStarted = nil
        }
    }

    /// Puts a half-finished analysis on screen so the app can be used while the rest is
    /// still being read.
    ///
    /// Guarded on the load still being the current one: a partial result arriving after a
    /// cancellation, a different repository, or the finished analysis itself must never
    /// overwrite what is on screen with something less complete.
    private func adoptPartial(_ analysis: RepositoryAnalysis, readiness: Readiness) {
        guard loadTask != nil, !Task.isCancelled,
              lastAttempted?.standardizedFileURL == analysis.root.standardizedFileURL,
              readiness != .complete, self.readiness != .complete || !hasRepository else { return }
        // Never go backwards: a slow `.factsOnly` callback must not replace history that
        // has already landed.
        if self.readiness.hasHistory && !readiness.hasHistory { return }

        self.readiness = readiness
        state = .loaded(analysis)
        if readiness.hasHistory {
            unitsByID = [:]
            contributors = ContributorStats.compute(commits: analysis.commits)
            rebuildCatchUp(for: analysis)
            ownership = OwnershipBuilder.build(
                commits: analysis.commits,
                currentPaths: Set(analysis.info.inventory.files.map(\.path)))
        }
        rebuild()
        refreshPushPlan()
    }

    /// Stops waiting for the current analysis.
    ///
    /// Git and the parser run in processes and tasks that do not stop mid-syscall, so this
    /// does not kill work already in flight — it stops GitView waiting for it and discards
    /// the result. The honest description is "stop waiting", which is what the button says.
    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadStarted = nil
        loadProgress = nil
        // A partly-read repository is left on screen rather than thrown away: the branches
        // and the working copy are real, and going back to the welcome screen would
        // discard work already done. Only a load with nothing to show yet returns there.
        if !hasRepository { state = .idle }
    }

    /// Re-attempts the repository whose load failed.
    func retryLastOpen() {
        guard let lastAttempted else { return }
        open(url: lastAttempted)
    }

    /// Re-reads the repository *without* clearing the screen first.
    ///
    /// `open` blanks everything and shows the loading screen, which is right when you are
    /// moving to a different project and wrong when you are standing still: a refresh that
    /// empties the window and fills it again a second later reads as a glitch, and loses
    /// your place. Here the old analysis stays up, fully usable, until the new one is ready
    /// to take its place. A refresh that fails leaves the old data alone and says so, rather
    /// than throwing away a perfectly good view of the repository.
    func refresh() {
        guard case .loaded(let current) = state, !isRefreshing else { return }
        let root = current.root
        let keptScreen = screen
        isRefreshing = true
        refreshError = nil
        loadStarted = Date()
        let note = outsideChange?.summary
        Task {
            do {
                // A refresh reports its stages too: it is the same read, and after a
                // "Stop" it is the read that finishes what was left.
                let analysis = try await Self.loadReportingTiming(root: root) { progress in
                    Task { @MainActor in
                        guard self.isRefreshing else { return }
                        self.loadProgress = progress
                    }
                }
                self.adopt(analysis, keptScreen: keptScreen, preservingSelection: true)
                if let note { self.flash(note) }
            } catch {
                self.refreshError = "\(error)"
            }
            self.isRefreshing = false
            self.loadProgress = nil
            self.loadStarted = nil
            self.outsideChange = nil
        }
    }

    /// Shows `note` for a few seconds and then takes it away.
    private func flash(_ note: String) {
        refreshNoteTask?.cancel()
        refreshNote = note
        refreshNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.refreshNote = nil
        }
    }

    /// Loads and prints the stage timings to stderr, so a run can be timed from outside
    /// without a screenshot delay dominating the wall clock.
    private static func loadReportingTiming(
        root: URL,
        progress: @escaping @Sendable (LoadingProgress) -> Void = { _ in },
        partial: @escaping @Sendable (RepositoryAnalysis, Readiness) -> Void = { _, _ in }
    ) async throws -> RepositoryAnalysis {
        let started = Date()
        let analysis = try await AnalysisService.load(root: root, progress: progress, partial: partial)
        FileHandle.standardError.write(Data(
            String(format: "gitview: analysis %@ — history %.2fs, parse %.2fs, facts %.2fs, total %.2fs\n",
                   analysis.source.summary, analysis.historyDuration, analysis.parseDuration,
                   analysis.factsDuration, Date().timeIntervalSince(started)).utf8))
        return analysis
    }

    /// Takes a freshly read analysis as the one on screen. Shared by opening and refreshing,
    /// so a refresh cannot drift out of step with an open.
    private func adopt(_ analysis: RepositoryAnalysis, keptScreen: Screen, preservingSelection: Bool) {
        readiness = .complete
        loadProgress = nil
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
        if preservingSelection { self.screen = keptScreen }
        self.rebuild()
        self.refreshPushPlan()
        if let term = self.pendingSearch { self.pendingSearch = nil; self.globalSearch = term }
        if let path = self.pendingFileHistory {
            self.pendingFileHistory = nil
            self.showFileHistory(path)
        }
        if let spec = self.pendingDiff {
            self.pendingDiff = nil
            if let colon = spec.firstIndex(of: ":") {
                let ref = String(spec[spec.startIndex..<colon])
                let path = String(spec[spec.index(after: colon)...])
                if ref == "working" {
                    self.showDiff(.workingTree(staged: false), path: path, title: "Uncommitted changes")
                } else {
                    self.selectedCommitSHA = ref
                    self.showDiff(.commit(sha: ref), path: path, title: ref)
                }
            }
        }
        if let name = pendingThenShow, let screen = Screen(rawValue: name) {
            pendingThenShow = nil
            show(screen)
        }
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
        // Health is a judgement over the whole repository, so a partial analysis cannot
        // produce one: scored before history arrives it reports "no commits" and "0 active
        // contributors" and hands out a low score for a repository that is merely still
        // being read. No score at all is the honest output until everything is in.
        guard readiness == .complete else { health = nil; return }
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

    private func loadFileHistory() {
        guard let analysis, let path = fileHistoryPath else {
            fileHistory = []; fileHistoryInFlight = false; return
        }
        fileHistoryInFlight = true
        fileHistory = []
        let root = analysis.root
        // Read on this actor; the detached task cannot touch main-actor state.
        let limit = Self.fileHistoryLimit
        Task.detached(priority: .userInitiated) {
            let entries = (try? GitRepository(url: root).fileHistory(path: path, limit: limit)) ?? []
            await MainActor.run {
                guard self.fileHistoryPath == path else { return }
                self.fileHistory = entries
                self.fileHistoryInFlight = false
            }
        }
    }

    func showFileHistory(_ path: String) {
        diffRequest = nil
        fileHistoryPath = path
    }

    func closeFileHistory() { fileHistoryPath = nil }

    private func loadDiff() {
        guard let analysis, let request = diffRequest else {
            loadedDiff = nil; diffInFlight = false; return
        }
        diffInFlight = true
        let root = analysis.root
        let context = diffContext
        Task.detached(priority: .userInitiated) {
            let diff = try? GitRepository(url: root).diff(request.source, path: request.path, context: context)
            await MainActor.run {
                guard self.diffRequest == request else { return }   // superseded by a newer click
                self.loadedDiff = diff
                self.diffInFlight = false
            }
        }
    }

    func showDiff(_ source: DiffSource, path: String, title: String) {
        diffRequest = DiffRequest(source: source, path: path, title: title)
    }

    func closeDiff() { diffRequest = nil }

    private func runSearch() {
        deepSearchTask?.cancel()
        let query = globalSearch.trimmingCharacters(in: .whitespaces)
        guard let analysis, !query.isEmpty else {
            searchResults = nil; codeMatches = []; historyMatches = []; deepSearchInFlight = false
            return
        }

        let corpus = SearchCorpus(
            commits: analysis.commits,
            filePaths: analysis.info.inventory.files.map(\.path),
            units: analysis.allUnits,
            contributors: contributors,
            branches: analysis.branches.map(\.name),
            tags: analysis.tags.map(\.name))
        searchResults = SearchEngine.search(query, in: corpus)

        // git grep and the pickaxe each cost a process, so they wait for a pause in typing.
        let parsed = SearchQuery.parse(query)
        guard parsed.author == nil, parsed.text.count >= 3 else {
            codeMatches = []; historyMatches = []; deepSearchInFlight = false
            return
        }
        let term = parsed.text
        let root = analysis.root
        deepSearchInFlight = true
        deepSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let repository = GitRepository(url: root)
            let code = (try? repository.grep(term, limit: 60)) ?? []
            let history = (try? repository.commitsChanging(term, limit: 25)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.globalSearch.trimmingCharacters(in: .whitespaces) == query else { return }
                self.codeMatches = code
                self.historyMatches = history
                self.deepSearchInFlight = false
            }
        }
    }

    func clearSearch() { globalSearch = "" }

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

    /// Runs a mutating git command, then refreshes what it could have changed.
    ///
    /// `reloadHistory` is for operations that move HEAD: the commit list, catch-up and
    /// everything derived from them are stale afterwards. The analysis cache makes that
    /// reload incremental, so it costs a fraction of a fresh read.
    private func perform(_ label: String, reloadHistory: Bool = false,
                         _ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let analysis, !writeInFlight else { return }
        writeInFlight = true
        writeError = nil
        let root = analysis.root
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try work(GitRepository(url: root)); return nil } catch { return "\(error)" }
            }.value
            self.writeError = failure
            self.writeInFlight = false
            if failure == nil, reloadHistory {
                // `refresh`, not `open`: committing should not blank the window and rebuild
                // it from a loading screen. The watcher will also see this write, but by
                // the time it asks, HEAD already matches what is on screen, so it does
                // nothing — the two paths cannot both reload.
                self.refresh()
            } else {
                self.refreshWorkingState()
                self.refreshPushPlan()
            }
        }
    }

    func stage(_ paths: [String]) { perform("stage") { try $0.stage(paths: paths) } }
    func stageAll() { perform("stage all") { try $0.stageAll() } }
    func unstage(_ paths: [String]) { perform("unstage") { try $0.unstage(paths: paths) } }

    func commitStaged() {
        let subject = commitSubject, body = commitBody
        perform("commit", reloadHistory: true) { _ = try $0.commit(subject: subject, body: body) }
        commitSubject = ""
        commitBody = ""
    }

    func stashEverything(includeUntracked: Bool) {
        let message = stashMessage
        perform("stash") { try $0.stashPush(message: message, includeUntracked: includeUntracked) }
        stashMessage = ""
    }

    func applyStash(_ ref: String, removing: Bool) {
        perform("stash apply") { try $0.stashApply(ref, removing: removing) }
    }

    func refreshPushPlan() {
        guard let analysis else { return }
        let root = analysis.root
        Task.detached(priority: .utility) {
            let plan = try? GitRepository(url: root).pushPlan()
            await MainActor.run { self.pushPlan = plan }
        }
    }

    func push() {
        guard let plan = pushPlan else { return }
        perform("push", reloadHistory: true) {
            try $0.push(remote: plan.remote, branch: plan.branch, setUpstream: !plan.hasUpstream)
        }
    }

    // MARK: Destructive, always confirmed

    func confirmDiscard(_ file: WorkingState.FileStatus) {
        confirmation = DestructiveConfirmation(
            title: "Discard changes to \((file.path as NSString).lastPathComponent)?",
            message: "The edits in your working copy will be gone. Nothing in git has a copy of them, "
                   + "so this cannot be undone. Stashing keeps them and you can bring them back later.",
            confirmLabel: "Discard",
            alternativeLabel: "Stash instead",
            perform: { [weak self] in
                self?.perform("discard") { try $0.discardChanges(paths: [file.path]) }
            },
            alternative: { [weak self] in
                self?.perform("stash") {
                    try $0.stashPush(message: "Set aside \(file.path)", includeUntracked: false)
                }
            })
    }

    func confirmDelete(_ file: WorkingState.FileStatus) {
        confirmation = DestructiveConfirmation(
            title: "Delete \((file.path as NSString).lastPathComponent)?",
            message: "This file has never been committed, so git has no copy of it. Deleting it removes "
                   + "it from disk permanently.",
            confirmLabel: "Delete",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("delete") { try $0.deleteUntracked(paths: [file.path]) }
            },
            alternative: nil)
    }

    func confirmDropStash(_ stash: WorkingState.Stash) {
        confirmation = DestructiveConfirmation(
            title: "Drop \(stash.ref)?",
            message: "“\(stash.message)” will be discarded. A dropped stash is very hard to recover.",
            confirmLabel: "Drop",
            alternativeLabel: nil,
            perform: { [weak self] in
                self?.perform("stash drop") { try $0.stashDrop(stash.ref) }
            },
            alternative: nil)
    }

    /// Re-reads `git status`. Cheap, so it runs whenever the app comes forward.
    // MARK: - Staying current

    /// Watches `root` from now on, replacing any previous watch.
    private func startWatching(_ root: URL) {
        watcher?.stop()
        watcher = RepositoryWatcher(root: root) { [weak self] in
            Task { @MainActor in self?.repositoryMayHaveMoved() }
        }
    }

    /// The watcher knows only that a file under `.git` changed — which is true of a commit,
    /// a checkout and a plain `git status` alike. Ask git what actually differs, cheaply,
    /// and do nothing at all unless the history on screen is genuinely behind.
    private func repositoryMayHaveMoved() {
        guard case .loaded(let analysis) = state, !isRefreshing, !writeInFlight else { return }
        // The working copy and the push plan are cheap and never disruptive, so they are
        // always brought up to date; the question below is only about history.
        refreshWorkingState()
        refreshPushPlan()

        guard let knownHead = analysis.commits.first?.sha else { return }
        let root = analysis.root
        let knownBranch = analysis.workingState.branch
        Task.detached(priority: .utility) {
            let repository = GitRepository(url: root)
            guard let head = try? repository.headSHA(), head != knownHead else { return }
            let fastForward = repository.isAncestor(knownHead, of: head)
            let added = fastForward ? repository.commitCount(from: knownHead, to: head) : 0
            let branch = (try? repository.workingState().branch) ?? knownBranch
            await MainActor.run {
                self.noteOutsideChange(branch: branch, knownBranch: knownBranch,
                                       added: added, isFastForward: fastForward)
            }
        }
    }

    private func noteOutsideChange(branch: String?, knownBranch: String?,
                                   added: Int, isFastForward: Bool) {
        guard case .loaded = state, !isRefreshing else { return }
        let summary: String
        if let branch, branch != knownBranch {
            summary = "Now on \(branch)"
        } else if !isFastForward {
            summary = "History was rewritten"
        } else if added > 0 {
            summary = added == 1 ? "1 new commit" : "\(added) new commits"
        } else {
            summary = "The history moved"
        }
        outsideChange = OutsideChange(summary: summary, isFastForward: isFastForward)
        // Bring it in straight away unless that would pull something out from under the
        // user. Reading a diff, a file's history or a set of search results means they are
        // looking at a specific thing; swapping the data underneath would lose their place,
        // so the banner waits for them instead.
        if !isMidFlow { refresh() }
    }

    /// True when the user is inside something that a silent reload would interrupt.
    private var isMidFlow: Bool {
        diffRequest != nil || fileHistoryPath != nil || isSearching
            || confirmation != nil || showSettings || comparisonInFlight
    }

    func dismissOutsideChange() { outsideChange = nil }

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

/// A change that cannot be undone, described in the terms the person needs to decide.
struct DestructiveConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    /// A safer path that keeps the work, offered where one exists.
    let alternativeLabel: String?
    let perform: () -> Void
    let alternative: (() -> Void)?
}
