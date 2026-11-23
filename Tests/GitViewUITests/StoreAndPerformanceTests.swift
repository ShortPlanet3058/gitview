import XCTest
@testable import GitViewUI
import GitViewCore
@testable import GitViewGit

final class StoreAndPerformanceTests: XCTestCase {
    private func makeDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "fr.liriscom.gitview.tests.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func makeAnalysis(units: [CodeUnit], files: [FileInventory.TrackedFile]) -> RepositoryAnalysis {
        let commits = [
            Commit(
                sha: "sha1",
                author: "Alice",
                date: Date(),
                subject: "Edit functions",
                fileChanges: units.map { unit in
                    FileChange(
                        path: unit.filePath,
                        hunks: [Hunk(oldStart: unit.lineRange.lowerBound, oldLineCount: 1,
                                     newStart: unit.lineRange.lowerBound, newLineCount: 2)]
                    )
                }
            )
        ]
        let inventory = FileInventory(
            fileCount: files.count,
            totalBytes: files.reduce(0) { $0 + $1.bytes },
            files: files,
            bytesByCategory: [:],
            bytesByLanguage: [:],
            filesByLanguage: [:],
            languages: [],
            largeFiles: [],
            lastModified: nil
        )
        let info = RepositoryInfo(
            root: URL(fileURLWithPath: "/tmp/repo"),
            currentBranch: "main",
            defaultBranch: "main",
            remoteURL: nil,
            remoteWebURL: nil,
            packedBytes: nil,
            readmeSummary: nil,
            configuredUserNames: ["Alice"],
            unreleased: nil,
            inventory: inventory
        )
        return RepositoryAnalysis(
            root: URL(fileURLWithPath: "/tmp/repo"),
            info: info,
            branches: [],
            tags: [],
            commits: commits,
            allUnits: units,
            filesParsed: files.count,
            filesFailed: [],
            generatedFiles: [],
            historyDuration: 0,
            parseDuration: 0,
            factsDuration: 0,
            attribution: AttributionStats(matchedHunks: units.count, unmatchedHunks: 0, unresolvedHunks: 0),
            source: .fresh,
            workingState: .clean
        )
    }

    @MainActor
    func testRiskStoreSearchTextFiltersWithoutReRunningExpensiveJoin() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        let store = RiskStore(preferences: prefs)
        let unitA = CodeUnit(filePath: "Sources/Alpha.swift", name: "parseHeader()", kind: .function,
                             lineRange: 1...20, complexity: 6, nestingDepth: 2, lineCount: 20, language: "swift")
        let unitB = CodeUnit(filePath: "Sources/Beta.swift", name: "renderGraph()", kind: .function,
                             lineRange: 1...15, complexity: 4, nestingDepth: 1, lineCount: 15, language: "swift")
        let files = [
            FileInventory.TrackedFile(path: "Sources/Alpha.swift", bytes: 400, modified: nil),
            FileInventory.TrackedFile(path: "Sources/Beta.swift", bytes: 300, modified: nil),
        ]
        let analysis = makeAnalysis(units: [unitA, unitB], files: files)
        store.update(analysis: analysis, unitsByID: [unitA.id: unitA, unitB.id: unitB], isComplete: true)

        XCTAssertEqual(store.fullRebuildCount, 1)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.allRankedRows.count, 2)
        let filtersAfterInitialBuild = store.searchFilterCount

        // Typing into searchText must run O(N) filter pass only, never fullRebuildCount += 1.
        store.searchText = "parseHeader"
        XCTAssertEqual(store.fullRebuildCount, 1)
        XCTAssertEqual(store.searchFilterCount, filtersAfterInitialBuild + 1)
        XCTAssertEqual(store.rows.map(\.name), ["parseHeader()"])
        XCTAssertEqual(store.allRankedRows.count, 2)

        store.searchText = ""
        XCTAssertEqual(store.fullRebuildCount, 1)
        XCTAssertEqual(store.rows.count, 2)

        // Structural filter change DOES rebuild ranking.
        store.kindFilter = .functions
        XCTAssertEqual(store.fullRebuildCount, 2)
    }

    @MainActor
    func testFileTreeBottomUpFilterAndAggregates() throws {
        let now = Date()
        let files = [
            FileInventory.TrackedFile(path: "Sources/Core/Engine.swift", bytes: 1000, modified: now),
            FileInventory.TrackedFile(path: "Sources/Core/Cache.swift", bytes: 500, modified: now),
            FileInventory.TrackedFile(path: "Tests/CoreTests.swift", bytes: 250, modified: now),
        ]
        let unit = CodeUnit(filePath: "Sources/Core/Engine.swift", name: "hot()", kind: .function,
                            lineRange: 1...30, complexity: 12, nestingDepth: 3, lineCount: 30, language: "swift")
        let commit = Commit(
            sha: "sha1", author: "Alice", date: now, subject: "Hot edit",
            fileChanges: [FileChange(path: "Sources/Core/Engine.swift", hunks: [Hunk(oldStart: 1, oldLineCount: 1, newStart: 1, newLineCount: 2)])]
        )
        let ranked = try XCTUnwrap(
            RiskModel().rank(units: [unit], churn: ChurnJoiner.join(units: [unit], commits: [commit]), now: now).first
        )
        let row = RiskRow(ranked, level: .critical, recentCommits: 1, complexityPercentile: 1.0, window: "2 years", now: now)

        let tree = FileTree(files: files, rows: [row])
        XCTAssertEqual(tree.root.fileCount, 3)
        XCTAssertEqual(tree.root.bytes, 1750)
        XCTAssertEqual(tree.node(at: "Sources")?.fileCount, 2)
        XCTAssertEqual(tree.node(at: "Sources/Core")?.bytes, 1500)
        XCTAssertEqual(tree.node(at: "Sources/Core")?.hotspots, 1)

        // Collapsed root shows only top-level folders when filter is empty.
        XCTAssertEqual(tree.visibleNodes(expanded: [], filter: "").map(\.path), ["Sources", "Tests"])

        // Filter auto-expands ancestor folders without including unrelated siblings.
        let matching = tree.visibleNodes(expanded: [], filter: "Cache")
        XCTAssertEqual(matching.map(\.path), ["Sources", "Sources/Core", "Sources/Core/Cache.swift"])
    }

    @MainActor
    func testWorkspaceSessionNavigationAndGoBackPrecedence() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        let session = WorkspaceSession(preferences: prefs, consumeLaunchArgumentsIfAvailable: false)

        session.navigation.selectedUnitID = UUID()
        session.inspector.fileHistoryPath = "Sources/A.swift"
        session.inspector.diffRequest = DiffRequest(source: .workingTree(staged: false), path: "Sources/A.swift", title: "Changes")
        XCTAssertTrue(session.canGoBack)

        // Innermost first: diff -> file history -> selection.
        XCTAssertTrue(session.goBack())
        XCTAssertNil(session.inspector.diffRequest)
        XCTAssertEqual(session.inspector.fileHistoryPath, "Sources/A.swift")

        XCTAssertTrue(session.goBack())
        XCTAssertNil(session.inspector.fileHistoryPath)
        XCTAssertNotNil(session.navigation.selectedUnitID)

        // Switching screen clears overlays and selections.
        session.inspector.diffRequest = DiffRequest(source: .workingTree(staged: false), path: "B.swift", title: "Changes")
        session.show(.commits)
        XCTAssertEqual(session.navigation.screen, .commits)
        XCTAssertNil(session.inspector.diffRequest)
        XCTAssertNil(session.navigation.selectedUnitID)
    }

    @MainActor
    func testAppPreferencesPersistsAndNotifiesObservers() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        var events: [AppPreferences.ChangeKind] = []
        let token = prefs.addObserver { events.append($0) }
        defer { prefs.removeObserver(token) }

        prefs.halfLifeDays = 180
        prefs.minSharedCommits = 5
        prefs.identityEmail = "dev@example.com"
        prefs.preferredEditor = .cursor
        prefs.preferredTerminal = .ghostty
        prefs.diffLayoutMode = .sideBySide
        prefs.diffIgnoreWhitespace = true

        XCTAssertEqual(events, [
            .riskModel, .coupling, .identity, .environment, .environment, .environment, .environment
        ])

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.halfLifeDays, 180)
        XCTAssertEqual(reloaded.minSharedCommits, 5)
        XCTAssertEqual(reloaded.identityEmail, "dev@example.com")
        XCTAssertEqual(reloaded.preferredEditor, .cursor)
        XCTAssertEqual(reloaded.preferredTerminal, .ghostty)
        XCTAssertEqual(reloaded.diffLayoutMode, .sideBySide)
        XCTAssertTrue(reloaded.diffIgnoreWhitespace)
    }

    @MainActor
    func testRiskStoreReusesPrecomputedChurnAndBackgroundRebuild() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        let store = RiskStore(preferences: prefs)
        let unit = CodeUnit(filePath: "Sources/Engine.swift", name: "run()", kind: .function,
                            lineRange: 1...25, complexity: 8, nestingDepth: 2, lineCount: 25, language: "swift")
        let files = [FileInventory.TrackedFile(path: "Sources/Engine.swift", bytes: 500, modified: nil)]
        var analysis = makeAnalysis(units: [unit], files: files)
        let precomputed = ChurnJoiner.join(units: [unit], commits: analysis.commits)
        analysis.fullChurn = precomputed

        store.update(analysis: analysis, unitsByID: [unit.id: unit], isComplete: true)
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.churn?.commitCount(for: unit), 1)

        prefs.halfLifeDays = 90
        store.rebuildInBackground()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertGreaterThanOrEqual(store.fullRebuildCount, 2)
    }

    func testCommandPaletteMatcherRanksExactPrefixSubstringAndFuzzy() {
        let items = [
            "Open Repository…",
            "Changes",
            "Change together",
            "Sources/GitView/ChangesScreen.swift",
            "Refresh Repository",
        ]
        let exact = CommandPaletteMatcher.rank(query: "Changes", items: items, title: { $0 })
        XCTAssertEqual(exact.first, "Changes")

        let boundary = CommandPaletteMatcher.rank(query: "ChangesScreen", items: items, title: { $0 })
        XCTAssertEqual(boundary.first, "Sources/GitView/ChangesScreen.swift")

        let fuzzy = CommandPaletteMatcher.rank(query: "oep", items: items, title: { $0 })
        XCTAssertTrue(fuzzy.contains("Open Repository…"))

        let unmatched = CommandPaletteMatcher.rank(query: "zzzzz", items: items, title: { $0 })
        XCTAssertTrue(unmatched.isEmpty)
    }

    func testConvexHullComputesOuterBoundaryAndExcludesInteriorPoints() {
        XCTAssertTrue(ConvexHull.compute([]).isEmpty)
        XCTAssertEqual(ConvexHull.compute([CGPoint(x: 1, y: 1)]), [CGPoint(x: 1, y: 1)])

        let squareWithInterior: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 10),
            CGPoint(x: 0, y: 10),
            CGPoint(x: 5, y: 5),
            CGPoint(x: 2, y: 7),
            CGPoint(x: 5, y: 0),
        ]
        let hull = ConvexHull.compute(squareWithInterior)
        XCTAssertEqual(hull.count, 4)
        XCTAssertFalse(hull.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(hull.contains(CGPoint(x: 2, y: 7)))
        XCTAssertTrue(hull.contains(CGPoint(x: 0, y: 0)))
        XCTAssertTrue(hull.contains(CGPoint(x: 10, y: 10)))
    }

    @MainActor
    func testRiskStoreUpdateInBackgroundPopulatesRowsAndDefersGraphLayout() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        prefs.minSharedCommits = 2
        let store = RiskStore(preferences: prefs)
        let unitA = CodeUnit(filePath: "Sources/A/One.swift", name: "one()", kind: .function,
                             lineRange: 1...10, complexity: 5, nestingDepth: 1, lineCount: 10, language: "swift")
        let unitB = CodeUnit(filePath: "Sources/B/Two.swift", name: "two()", kind: .function,
                             lineRange: 1...10, complexity: 7, nestingDepth: 2, lineCount: 10, language: "swift")
        let now = Date()
        let commits = [0, 1].map { idx in
            Commit(
                sha: "sha\(idx)",
                author: "Alice",
                date: now.addingTimeInterval(TimeInterval(-idx * 3600)),
                subject: "Shared edit \(idx)",
                fileChanges: [
                    FileChange(path: unitA.filePath, hunks: [Hunk(oldStart: 1, oldLineCount: 1, newStart: 1, newLineCount: 2)]),
                    FileChange(path: unitB.filePath, hunks: [Hunk(oldStart: 1, oldLineCount: 1, newStart: 1, newLineCount: 2)]),
                ]
            )
        }
        let files = [
            FileInventory.TrackedFile(path: unitA.filePath, bytes: 200, modified: now),
            FileInventory.TrackedFile(path: unitB.filePath, bytes: 250, modified: now),
        ]
        var analysis = makeAnalysis(units: [unitA, unitB], files: files)
        analysis = RepositoryAnalysis(
            root: analysis.root,
            info: analysis.info,
            branches: analysis.branches,
            tags: analysis.tags,
            commits: commits,
            allUnits: [unitA, unitB],
            filesParsed: 2,
            filesFailed: [],
            generatedFiles: [],
            historyDuration: 0,
            parseDuration: 0,
            factsDuration: 0,
            attribution: AttributionStats(matchedHunks: 2, unmatchedHunks: 0, unresolvedHunks: 0),
            source: .cached,
            workingState: .clean
        )

        store.updateInBackground(analysis: analysis, unitsByID: [unitA.id: unitA, unitB.id: unitB], isComplete: true)
        XCTAssertTrue(store.analysisRebuildInProgress)

        let deadline = Date().addingTimeInterval(3.0)
        while store.analysisRebuildInProgress && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(store.analysisRebuildInProgress)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertNotNil(store.health)
        XCTAssertNotNil(store.fileTree)
        XCTAssertEqual(store.couplingRows.count, 1)

        // Graph layout must remain deferred while in list mode.
        XCTAssertNil(store.graph)
        XCTAssertFalse(store.graphLayoutInProgress)

        // Switching to graph mode triggers lazy graph build & layout.
        store.couplingViewMode = .graph
        XCTAssertNotNil(store.graph)
        let graphDeadline = Date().addingTimeInterval(3.0)
        while store.graphLayoutInProgress && Date() < graphDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(store.graphLayoutInProgress)
        XCTAssertEqual(store.graphPositions.count, 2)
    }

    @MainActor
    func testStandardAndAdvancedNavigationDifferentiationAndFallback() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        prefs.advanced = false
        let session = WorkspaceSession(preferences: prefs, consumeLaunchArgumentsIfAvailable: false)

        let standard = session.navigation.visibleScreens(advanced: false)
        XCTAssertEqual(standard, [.overview, .changes, .commits, .branches, .files, .contributors])
        XCTAssertEqual(NavigationStore.Screen.commits.displayTitle(advanced: false), "History")
        XCTAssertEqual(NavigationStore.Screen.commits.displayTitle(advanced: true), "Commits")
        XCTAssertEqual(NavigationStore.Screen.contributors.displayTitle(advanced: false), "People")
        XCTAssertEqual(NavigationStore.Screen.contributors.displayTitle(advanced: true), "Contributors")

        let advanced = session.navigation.visibleScreens(advanced: true)
        XCTAssertEqual(advanced.count, 11)
        XCTAssertTrue(advanced.contains(.hotspots))
        XCTAssertTrue(advanced.contains(.coupling))
        XCTAssertTrue(advanced.contains(.statistics))
        XCTAssertTrue(advanced.contains(.releases))
        XCTAssertTrue(advanced.contains(.activity))

        // Leaving Advanced mode while viewing an Advanced-only screen falls back cleanly to Overview.
        prefs.advanced = true
        session.show(.statistics)
        XCTAssertEqual(session.navigation.screen, .statistics)

        prefs.advanced = false
        XCTAssertEqual(session.navigation.screen, .overview)
    }

    @MainActor
    func testInspectorStoreInlineDiffAndExpandWorkflow() {
        let store = InspectorStore()
        XCTAssertNil(store.inlineDiffRequest)
        XCTAssertNil(store.diffRequest)

        store.showInlineDiff(.workingTree(staged: false), path: "Sources/A.swift", title: "Modified file")
        XCTAssertEqual(store.inlineDiffRequest?.path, "Sources/A.swift")
        XCTAssertNil(store.diffRequest)

        store.expandInlineDiff()
        XCTAssertEqual(store.diffRequest, store.inlineDiffRequest)

        store.clearInlineDiff()
        XCTAssertNil(store.inlineDiffRequest)
        XCTAssertEqual(store.diffRequest?.path, "Sources/A.swift")

        store.resetForOpen()
        XCTAssertNil(store.diffRequest)
        XCTAssertNil(store.inlineDiffRequest)
    }

    @MainActor
    func testWorkingCopyStorePreservesCommitMessageOnFailure() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-wc-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-q"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Test User"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "test@example.com"], in: tempRoot)
        try "one\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "a.txt"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-qm", "initial"], in: tempRoot)

        let store = WorkingCopyStore()
        store.rootProvider = { tempRoot }
        store.commitSubject = "Important feature message"
        store.commitBody = "Detailed context that must not vanish"

        // Nothing is staged, so git commit will fail.
        store.commitStaged()
        let deadline = Date().addingTimeInterval(3.0)
        while store.writeInFlight && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(store.writeInFlight)
        XCTAssertNotNil(store.writeError)
        XCTAssertEqual(store.commitSubject, "Important feature message")
        XCTAssertEqual(store.commitBody, "Detailed context that must not vanish")
    }

    func testAnalysisServiceDefersCodeUnitsInStandardModeAndHydratesOnDemand() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-lazy-ast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRoot)
        try "func computeValue() -> Int {\n    return 42\n}\n".write(
            to: tempRoot.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "App.swift"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-qm", "Add App"], in: tempRoot)

        let standard = try await AnalysisService.load(
            root: tempRoot,
            useCache: false,
            includeCodeAnalysis: false
        )
        XCTAssertFalse(standard.hasCodeUnits)
        XCTAssertTrue(standard.allUnits.isEmpty)
        XCTAssertEqual(standard.filesParsed, 0)
        XCTAssertEqual(standard.commits.count, 1)

        let hydrated = try await AnalysisService.loadCodeUnits(for: standard, useCache: false)
        XCTAssertTrue(hydrated.hasCodeUnits)
        XCTAssertFalse(hydrated.allUnits.isEmpty)
        XCTAssertEqual(hydrated.filesParsed, 1)
    }

    func testRepositoryWatcherIgnoresBuildAndGitPaths() {
        let root = "/tmp/sample-repo"
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/.git/index", relativeTo: root))
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/.build/debug/App", relativeTo: root))
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/node_modules/pkg/index.js", relativeTo: root))
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/App.xcodeproj/xcuserdata/finn.xcuserdatad/UserInterfaceState.xcuserstate", relativeTo: root))
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/.DS_Store", relativeTo: root))
        XCTAssertTrue(RepositoryWatcher.shouldIgnoreWorktreePath(root, relativeTo: root))

        XCTAssertFalse(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/Sources/App.swift", relativeTo: root))
        XCTAssertFalse(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/README.md", relativeTo: root))
        XCTAssertFalse(RepositoryWatcher.shouldIgnoreWorktreePath("\(root)/Sources/builder/Helpers.swift", relativeTo: root))
    }

    @MainActor
    func testAppPreferencesAppearanceModeAndCodeFontSizePersistence() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.appearanceMode, .system)
        XCTAssertEqual(prefs.codeFontSize, 11)

        prefs.appearanceMode = .dark
        prefs.increaseCodeFontSize()
        XCTAssertEqual(prefs.codeFontSize, 12)
        prefs.codeFontSize = 40 // clamped to max 18
        XCTAssertEqual(prefs.codeFontSize, 18)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.appearanceMode, .dark)
        XCTAssertEqual(reloaded.codeFontSize, 18)

        reloaded.codeFontSize = 3 // clamped to min 9
        XCTAssertEqual(reloaded.codeFontSize, 9)
        reloaded.resetCodeFontSize()
        XCTAssertEqual(reloaded.codeFontSize, 11)
    }

    @MainActor
    func testSearchStoreCompletesAsyncDeepSearch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-searchstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Bob"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "bob@example.com"], in: tempRoot)
        try "struct DeepSearchMarker {}\n".write(
            to: tempRoot.appendingPathComponent("Marker.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.capture(arguments: ["add", "Marker.swift"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-qm", "Add marker"], in: tempRoot)

        let store = SearchStore()
        store.updateContext(
            root: tempRoot,
            commits: [],
            filePaths: ["Marker.swift"],
            units: [],
            contributors: [],
            branches: ["main"],
            tags: []
        )
        store.globalSearch = "DeepSearchMarker"
        XCTAssertTrue(store.deepSearchInFlight)

        let deadline = Date().addingTimeInterval(4.0)
        while store.deepSearchInFlight && Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertFalse(store.deepSearchInFlight)
        XCTAssertEqual(store.codeMatches.map(\.path), ["Marker.swift"])
        XCTAssertEqual(store.historyMatches.map(\.subject), ["Add marker"])
    }

    func testDiffGapCalculatorComputesLeadingMiddleTrailingGapsAndSplitsCleanly() {
        let h1 = DiffHunk(
            oldStart: 10,
            newStart: 10,
            section: "func one()",
            lines: [
                DiffLine(id: 1, kind: .deletion, oldNumber: 10, newNumber: nil, text: "old10", missingTrailingNewline: false),
                DiffLine(id: 2, kind: .addition, oldNumber: nil, newNumber: 10, text: "new10", missingTrailingNewline: false),
                DiffLine(id: 3, kind: .addition, oldNumber: nil, newNumber: 11, text: "added11", missingTrailingNewline: false),
            ]
        )
        let h2 = DiffHunk(
            oldStart: 20,
            newStart: 21,
            section: "func two()",
            lines: [
                DiffLine(id: 4, kind: .context, oldNumber: 20, newNumber: 21, text: "line 21", missingTrailingNewline: false),
                DiffLine(id: 5, kind: .deletion, oldNumber: 21, newNumber: nil, text: "old21", missingTrailingNewline: false),
                DiffLine(id: 6, kind: .addition, oldNumber: nil, newNumber: 22, text: "new22", missingTrailingNewline: false),
            ]
        )
        let diff = FileDiff(
            path: "Sample.swift",
            oldPath: "Sample.swift",
            hunks: [h1, h2],
            isBinary: false,
            isNew: false,
            isDeleted: false,
            truncated: false
        )
        let fileLines = (1...30).map { "line \($0)" }
        let gaps = DiffGapCalculator.gaps(for: diff, totalNewLines: fileLines.count)

        XCTAssertEqual(gaps.count, 3)
        // Leading gap: new lines 1...9, oldOffset 0.
        XCTAssertEqual(gaps[0].index, 0)
        XCTAssertEqual(gaps[0].newLineRange, 1...9)
        XCTAssertEqual(gaps[0].oldOffset, 0)

        // Middle gap: new lines 12...20 (old 11...19 -> offset -1).
        XCTAssertEqual(gaps[1].index, 1)
        XCTAssertEqual(gaps[1].newLineRange, 12...20)
        XCTAssertEqual(gaps[1].oldOffset, -1)

        // Trailing gap: new lines 23...30 (old 22...29 -> offset -1).
        XCTAssertEqual(gaps[2].index, 2)
        XCTAssertEqual(gaps[2].newLineRange, 23...30)
        XCTAssertEqual(gaps[2].oldOffset, -1)

        let split = DiffGapCalculator.split(
            gap: gaps[1],
            expansion: GapExpansion(top: 2, bottom: 3, showAll: false),
            fileLines: fileLines
        )
        XCTAssertEqual(split.topLines.map(\.newNumber), [12, 13])
        XCTAssertEqual(split.topLines.map(\.oldNumber), [11, 12])
        XCTAssertEqual(split.remainingCount, 4)
        XCTAssertEqual(split.bottomLines.map(\.newNumber), [18, 19, 20])
        XCTAssertEqual(split.bottomLines.map(\.oldNumber), [17, 18, 19])
        XCTAssertTrue(split.topLines.allSatisfy { $0.id < 0 })
    }

    @MainActor
    func testNavigationStorePreservesSelectedFileAcrossScreensAndClearsOnOpen() {
        let nav = NavigationStore()
        nav.selectedFilePath = "Sources/GitView/AppShell.swift"
        nav.clearDetailSelections()
        XCTAssertEqual(nav.selectedFilePath, "Sources/GitView/AppShell.swift")

        nav.clearForOpen()
        XCTAssertNil(nav.selectedFilePath)
    }

    @MainActor
    func testAutoFetchPreferenceDraftsCoAuthorAndCommandLogStore() throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.autoFetchInterval, .off)
        prefs.autoFetchInterval = .fifteenMinutes
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.autoFetchInterval, .fifteenMinutes)

        let tempRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRepo, withIntermediateDirectories: true)
        defer {
            GitCommandRecorder.shared.clear(for: tempRepo)
            try? FileManager.default.removeItem(at: tempRepo)
        }
        _ = try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: tempRepo)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRepo)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRepo)
        try "hello\n".write(to: tempRepo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let store = WorkingCopyStore(defaults: defaults)
        store.rootProvider = { tempRepo }
        store.restoreDraft(for: tempRepo)
        store.commitSubject = "WIP subject"
        store.appendCoAuthor(name: "Bob", email: "bob@example.com")
        store.appendCoAuthor(name: "Bob Duplicate", email: "BOB@example.com")
        XCTAssertEqual(store.commitBody, "Co-authored-by: Bob <bob@example.com>")

        let restored = WorkingCopyStore(defaults: defaults)
        restored.restoreDraft(for: tempRepo)
        XCTAssertEqual(restored.commitSubject, "WIP subject")
        XCTAssertEqual(restored.commitBody, "Co-authored-by: Bob <bob@example.com>")

        restored.clearDraft()
        let cleared = WorkingCopyStore(defaults: defaults)
        cleared.restoreDraft(for: tempRepo)
        XCTAssertEqual(cleared.commitSubject, "")

        let repo = GitRepository(url: tempRepo)
        try repo.stage(paths: ["a.txt"])
        store.reloadCommandLog(for: tempRepo)
        XCTAssertFalse(store.commandLog.isEmpty)
        XCTAssertFalse(store.hasRecentFailure)
    }

    @MainActor
    func testWrapCodeLinesPreferenceDiffRangeSelectorAndCLILauncher() throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.wrapCodeLines)
        prefs.wrapCodeLines = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.wrapCodeLines)

        let ids = [10, 11, 12, 13, 14]
        let single = DiffLineRangeSelector.toggledSelection(
            current: [],
            lastClickedID: nil,
            clickedID: 11,
            selectableIDsInHunk: ids,
            shiftPressed: false
        )
        XCTAssertEqual(single, [11])

        let forwardRange = DiffLineRangeSelector.toggledSelection(
            current: single,
            lastClickedID: 11,
            clickedID: 13,
            selectableIDsInHunk: ids,
            shiftPressed: true
        )
        XCTAssertEqual(forwardRange, [11, 12, 13])

        let backwardRange = DiffLineRangeSelector.toggledSelection(
            current: [13],
            lastClickedID: 13,
            clickedID: 10,
            selectableIDsInHunk: ids,
            shiftPressed: true
        )
        XCTAssertEqual(backwardRange, [10, 11, 12, 13])

        // CLILauncher install / detect / uninstall safety in an isolated temporary directory
        let binDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: binDir) }

        let installed = try CLILauncher.install(into: binDir, appPath: "/Applications/GitView.app")
        XCTAssertEqual(installed.lastPathComponent, "gitview")
        XCTAssertEqual(CLILauncher.installedPath(searchDirectories: [binDir])?.standardizedFileURL,
                       installed.standardizedFileURL)
        let content = try String(contentsOf: installed, encoding: .utf8)
        XCTAssertTrue(content.contains(CLILauncher.marker))
        XCTAssertTrue(content.contains("/Applications/GitView.app"))

        try CLILauncher.uninstall(from: installed)
        XCTAssertNil(CLILauncher.installedPath(searchDirectories: [binDir]))

        let foreign = binDir.appendingPathComponent("gitview")
        try "#!/bin/sh\necho foreign\n".write(to: foreign, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CLILauncher.uninstall(from: foreign))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
}
