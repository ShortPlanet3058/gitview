import Foundation
import Observation
import GitViewCore
import GitViewGit

@MainActor
private enum LaunchController {
    static var consumedLaunchArguments = false
}

/// Top-level per-window session coordinating repository analysis and its focused `@Observable` stores.
@MainActor
@Observable
public final class WorkspaceSession {
    enum State {
        case idle
        case loading(LoadingProgress)
        case loaded(RepositoryAnalysis)
        case failed(String)
    }

    struct OutsideChange: Identifiable, Equatable {
        let id = UUID()
        let summary: String
        let isFastForward: Bool
    }

    let preferences: AppPreferences
    let navigation: NavigationStore
    let risk: RiskStore
    let workingCopy: WorkingCopyStore
    let search: SearchStore
    let inspector: InspectorStore

    private(set) var state: State = .idle
    private(set) var outsideChange: OutsideChange?
    private(set) var isRefreshing = false
    private(set) var readiness: Readiness = .complete
    private(set) var loadProgress: LoadingProgress?
    var refreshError: String?
    private(set) var refreshNote: String?
    private(set) var loadStarted: Date?

    private(set) var catchUp: CatchUp?
    private(set) var ownership: OwnershipIndex?
    private(set) var contributors: [Contributor] = []
    private(set) var unitsByID: [UUID: CodeUnit] = [:]
    private(set) var recentActivityBuckets: [ActivityBucket] = []

    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var refreshNoteTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempted: URL?
    @ObservationIgnored private var preferenceObserverID: UUID?

    public init(preferences: AppPreferences = .shared, consumeLaunchArgumentsIfAvailable: Bool = false) {
        self.preferences = preferences
        self.navigation = NavigationStore()
        self.risk = RiskStore(preferences: preferences)
        self.workingCopy = WorkingCopyStore()
        self.search = SearchStore()
        self.inspector = InspectorStore()

        wireCallbacks()

        if consumeLaunchArgumentsIfAvailable && !LaunchController.consumedLaunchArguments {
            LaunchController.consumedLaunchArguments = true
            applyLaunchArguments()
        }
    }

    private func wireCallbacks() {
        workingCopy.rootProvider = { [weak self] in
            self?.analysis?.root
        }
        workingCopy.onWorkingStateRefreshed = { [weak self] root, fresh in
            guard let self, case .loaded(var current) = self.state, current.root == root else { return }
            current.workingState = fresh
            self.state = .loaded(current)
        }
        workingCopy.onHistoryMutated = { [weak self] in
            self?.refresh()
        }

        risk.onRowsChanged = { [weak self] built, byID in
            guard let self else { return }
            if let selected = self.navigation.selectedUnitID, byID[selected] == nil {
                self.navigation.selectedUnitID = nil
            }
            if let fragment = self.navigation.pendingSelection {
                self.navigation.pendingSelection = nil
                self.navigation.selectedUnitID = built.first { $0.name == fragment }?.id
                    ?? built.first { $0.name.hasSuffix("." + fragment) }?.id
                    ?? built.first { $0.name.localizedCaseInsensitiveContains(fragment) }?.id
            }
        }

        risk.onCouplingChanged = { [weak self] built, byID in
            guard let self else { return }
            if let selected = self.navigation.selectedPairID, byID[selected] == nil {
                self.navigation.selectedPairID = nil
            }
            if let fragment = self.navigation.pendingPairSelection {
                self.navigation.pendingPairSelection = nil
                self.navigation.selectedPairID = built.first {
                    $0.nameA.contains(fragment) || $0.nameB.contains(fragment)
                }?.id ?? built.first?.id
            }
        }

        preferenceObserverID = preferences.addObserver { [weak self] kind in
            guard let self else { return }
            switch kind {
            case .riskModel:
                self.risk.rebuildInBackground()
            case .coupling:
                self.risk.rebuildCouplingInBackground()
            case .identity:
                self.rebuildCatchUp()
            case .environment:
                break
            }
        }
    }

    // MARK: - Convenience accessors

    var analysis: RepositoryAnalysis? {
        if case .loaded(let analysis) = state { return analysis }
        return nil
    }

    var hasRepository: Bool {
        if case .loaded = state { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var visibleScreens: [NavigationStore.Screen] {
        navigation.visibleScreens(advanced: preferences.advanced)
    }

    var analysisScreens: [NavigationStore.Screen] {
        navigation.analysisScreens(advanced: preferences.advanced)
    }

    var selectedUnit: CodeUnit? { navigation.selectedUnitID.flatMap { unitsByID[$0] } }
    var selectedRow: RiskRow? { navigation.selectedUnitID.flatMap { risk.rowsByID[$0] } }
    var selectedPair: CouplingRow? { navigation.selectedPairID.flatMap { risk.couplingRowsByID[$0] } }

    var selectedCommit: Commit? {
        guard let sha = navigation.selectedCommitSHA else { return nil }
        if let existing = analysis?.commits.first(where: { $0.sha == sha }) {
            return existing
        }
        guard let detail = inspector.commitDetails[sha] else { return nil }
        return Commit(
            sha: detail.sha,
            parents: detail.parents,
            author: detail.authorName,
            email: detail.authorEmail,
            date: detail.authorDate,
            subject: detail.subject,
            fileChanges: detail.deltas.map { FileChange(path: $0.path, hunks: []) }
        )
    }

    var canGoBack: Bool {
        inspector.diffRequest != nil
            || inspector.fileHistoryPath != nil
            || search.isSearching
            || navigation.hasDetailSelection
    }

    func show(_ screen: NavigationStore.Screen) {
        inspector.diffRequest = nil
        inspector.fileHistoryPath = nil
        if search.isSearching { search.clear() }
        navigation.clearDetailSelections()
        navigation.screen = screen
    }

    @discardableResult
    func goBack() -> Bool {
        if inspector.diffRequest != nil { inspector.diffRequest = nil; return true }
        if inspector.fileHistoryPath != nil { inspector.fileHistoryPath = nil; return true }
        if search.isSearching { search.clear(); return true }
        if navigation.hasDetailSelection {
            navigation.clearDetailSelections()
            return true
        }
        return false
    }

    // MARK: - Opening, Loading & Refreshing

    private func applyLaunchArguments() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        navigation.pendingSelection = value("--select")
        navigation.pendingPairSelection = value("--select-pair")
        navigation.pendingCommitSelection = value("--select-commit")
        navigation.pendingAuthorSelection = value("--select-author")
        navigation.pendingCompare = value("--compare")
        navigation.pendingSearch = value("--search")
        navigation.pendingDiff = value("--diff")
        navigation.pendingThenShow = value("--then-show")
        navigation.pendingFileHistory = value("--file-history")
        navigation.pendingFileSelection = value("--select-file")
        if let name = value("--screen"), let screen = NavigationStore.Screen(rawValue: name) {
            navigation.screen = screen
        }
        if let mode = value("--mode") { preferences.advanced = mode == "advanced" }
        if let view = value("--view") { risk.couplingViewMode = view == "graph" ? .graph : .list }
        DebugScreenshot.scheduleIfRequested(session: self)
        if let path = value("--repo").map({ ($0 as NSString).expandingTildeInPath }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                open(url: URL(fileURLWithPath: path))
            }
        } else if !arguments.contains("--no-reopen"), let last = RecentRepositories.last() {
            open(url: last)
        }
    }

    public func open(url: URL, preservingSelection: Bool = false) {
        let keptScreen = navigation.screen
        RecentRepositories.remember(url)
        startWatching(url)
        outsideChange = nil
        refreshError = nil
        lastAttempted = url
        loadStarted = Date()
        readiness = .factsOnly
        loadTask?.cancel()
        state = .loading(LoadingProgress(stage: "Checking the repository"))
        risk.resetForOpen()
        navigation.clearForOpen()
        inspector.resetForOpen()
        workingCopy.clear()
        search.reset()
        ownership = nil
        recentActivityBuckets = []

        loadTask = Task {
            do {
                let analysis = try await Self.loadReportingTiming(root: url) { progress in
                    Task { @MainActor in
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

    private func adoptPartial(_ analysis: RepositoryAnalysis, readiness: Readiness) {
        guard loadTask != nil, !Task.isCancelled,
              lastAttempted?.standardizedFileURL == analysis.root.standardizedFileURL,
              readiness != .complete, self.readiness != .complete || !hasRepository else { return }
        if self.readiness.hasHistory && !readiness.hasHistory { return }

        self.readiness = readiness
        state = .loaded(analysis)
        inspector.setRepositoryRoot(analysis.root)
        if readiness.hasHistory {
            unitsByID = [:]
            contributors = analysis.precomputedContributors ?? ContributorStats.compute(commits: analysis.commits)
            recentActivityBuckets = Self.computeRecentBuckets(from: analysis.commits)
            rebuildCatchUp(for: analysis)
            ownership = analysis.precomputedOwnership ?? OwnershipBuilder.build(
                commits: analysis.commits,
                currentPaths: Set(analysis.info.inventory.files.map(\.path))
            )
        }
        risk.update(analysis: analysis, unitsByID: unitsByID, isComplete: false)
        workingCopy.refreshPushPlan()
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadStarted = nil
        loadProgress = nil
        if !hasRepository { state = .idle }
    }

    func retryLastOpen() {
        guard let lastAttempted else { return }
        open(url: lastAttempted)
    }

    public func refresh() {
        guard case .loaded(let current) = state, !isRefreshing else { return }
        let root = current.root
        let keptScreen = navigation.screen
        isRefreshing = true
        refreshError = nil
        loadStarted = Date()
        let note = outsideChange?.summary
        Task {
            do {
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

    private func flash(_ note: String) {
        refreshNoteTask?.cancel()
        refreshNote = note
        refreshNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.refreshNote = nil
        }
    }

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

    private func adopt(_ analysis: RepositoryAnalysis, keptScreen: NavigationStore.Screen, preservingSelection: Bool) {
        readiness = .complete
        loadProgress = nil
        inspector.setRepositoryRoot(analysis.root)
        self.unitsByID = Dictionary(uniqueKeysWithValues: analysis.allUnits.map { ($0.id, $0) })
        self.contributors = analysis.precomputedContributors ?? ContributorStats.compute(commits: analysis.commits)
        self.recentActivityBuckets = Self.computeRecentBuckets(from: analysis.commits)
        self.rebuildCatchUp(for: analysis)
        if let wanted = navigation.pendingAuthorSelection {
            navigation.pendingAuthorSelection = nil
            navigation.selectedAuthor = contributors.first {
                $0.name == wanted || $0.name.localizedCaseInsensitiveContains(wanted)
            }?.name
        }
        self.ownership = analysis.precomputedOwnership ?? OwnershipBuilder.build(
            commits: analysis.commits,
            currentPaths: Set(analysis.info.inventory.files.map(\.path))
        )
        if let prefix = navigation.pendingCommitSelection {
            navigation.pendingCommitSelection = nil
            navigation.selectedCommitSHA = analysis.commits.first {
                $0.sha.hasPrefix(prefix) || $0.subject.localizedCaseInsensitiveContains(prefix)
            }?.sha
        }
        self.state = .loaded(analysis)
        if preservingSelection { navigation.screen = keptScreen }
        search.updateContext(
            root: analysis.root,
            commits: analysis.commits,
            filePaths: analysis.info.inventory.files.map(\.path),
            units: analysis.allUnits,
            contributors: contributors,
            branches: analysis.branches.map(\.name),
            tags: analysis.tags.map(\.name)
        )
        risk.update(analysis: analysis, unitsByID: unitsByID, isComplete: true)
        workingCopy.refreshPushPlan()

        if let term = navigation.pendingSearch {
            navigation.pendingSearch = nil
            search.globalSearch = term
        }
        if let path = navigation.pendingFileHistory {
            navigation.pendingFileHistory = nil
            inspector.showFileHistory(path)
        }
        if let spec = navigation.pendingDiff {
            navigation.pendingDiff = nil
            if let colon = spec.firstIndex(of: ":") {
                let ref = String(spec[spec.startIndex..<colon])
                let path = String(spec[spec.index(after: colon)...])
                if ref == "working" {
                    inspector.showDiff(.workingTree(staged: false), path: path, title: "Uncommitted changes")
                } else {
                    navigation.selectedCommitSHA = ref
                    inspector.showDiff(.commit(sha: ref), path: path, title: ref)
                }
            }
        }
        if let name = navigation.pendingThenShow, let target = NavigationStore.Screen(rawValue: name) {
            navigation.pendingThenShow = nil
            show(target)
        }
        if let spec = navigation.pendingCompare {
            navigation.pendingCompare = nil
            let parts = spec.components(separatedBy: "..")
            if parts.count == 2 {
                navigation.compareFrom = parts[0]
                navigation.compareTo = parts[1]
                navigation.runComparison(in: analysis.root)
            }
        }
    }

    // MARK: - Derived Helpers

    private static func computeRecentBuckets(from commits: [Commit]) -> [ActivityBucket] {
        let now = Date()
        return ActivitySeries.buckets(
            commits: commits,
            granularity: .week,
            from: now.addingTimeInterval(-182 * 86_400),
            to: now
        )
    }

    func rebuildCatchUp(for analysis: RepositoryAnalysis? = nil) {
        guard let analysis = analysis ?? self.analysis else { return }
        let visit = VisitLog.lastVisit(to: analysis.root)
        catchUp = CatchUpBuilder.build(
            commits: analysis.commits,
            lastVisit: visit,
            identity: identity(for: analysis),
            now: Date()
        )
        if visit == nil, let head = analysis.commits.first?.sha {
            VisitLog.record(headSHA: head, to: analysis.root)
        }
    }

    private func identity(for analysis: RepositoryAnalysis) -> Identity {
        let overrideName = preferences.identityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideEmail = preferences.identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overrideName.isEmpty || !overrideEmail.isEmpty {
            return Identity(
                names: overrideName.isEmpty ? [] : [overrideName],
                emails: overrideEmail.isEmpty ? [] : [overrideEmail]
            )
        }
        let knownNames = Set(contributors.map(\.name))
        let configuredNames = analysis.info.configuredUserNames.filter { knownNames.contains($0) }
        return Identity(names: configuredNames, emails: analysis.info.configuredUserEmails)
    }

    func markCatchUpSeen() {
        guard let analysis, let head = analysis.commits.first?.sha else { return }
        VisitLog.record(headSHA: head, to: analysis.root)
        rebuildCatchUp()
    }

    func commitsBetweenTags() -> [String: Int] {
        guard let analysis else { return [:] }
        var indexBySHA: [String: Int] = [:]
        for (index, commit) in analysis.commits.enumerated() { indexBySHA[commit.sha] = index }
        var result: [String: Int] = [:]
        let reachable = analysis.tags.compactMap { tag -> (String, Int)? in
            indexBySHA[tag.commitSHA].map { (tag.name, $0) }
        }
        .sorted { $0.1 < $1.1 }
        for (offset, entry) in reachable.enumerated() {
            let previousIndex = offset + 1 < reachable.count ? reachable[offset + 1].1 : analysis.commits.count
            result[entry.0] = max(previousIndex - entry.1, 0)
        }
        return result
    }

    var unreleasedCount: Int? {
        guard let analysis else { return nil }
        if let unreleased = analysis.info.unreleased { return unreleased.commitsSinceTag }
        guard let latest = analysis.tags.first,
              let index = analysis.commits.firstIndex(where: { $0.sha == latest.commitSHA }) else { return nil }
        return index
    }

    // MARK: - Staying Current

    private func startWatching(_ root: URL) {
        watcher?.stop()
        watcher = RepositoryWatcher(root: root) { [weak self] in
            Task { @MainActor in self?.repositoryMayHaveMoved() }
        }
    }

    private func repositoryMayHaveMoved() {
        guard case .loaded(let analysis) = state, !isRefreshing, !workingCopy.writeInFlight else { return }
        workingCopy.refreshWorkingState()
        workingCopy.refreshPushPlan()

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
                self.noteOutsideChange(
                    branch: branch,
                    knownBranch: knownBranch,
                    added: added,
                    isFastForward: fastForward
                )
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
        if !isMidFlow { refresh() }
    }

    private var isMidFlow: Bool {
        inspector.diffRequest != nil
            || inspector.fileHistoryPath != nil
            || search.isSearching
            || workingCopy.confirmation != nil
            || navigation.comparisonInFlight
    }

    func dismissOutsideChange() {
        outsideChange = nil
    }
}
