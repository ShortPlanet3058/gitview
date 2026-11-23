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

        XCTAssertEqual(events, [.riskModel, .coupling, .identity, .environment, .environment])

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.halfLifeDays, 180)
        XCTAssertEqual(reloaded.minSharedCommits, 5)
        XCTAssertEqual(reloaded.identityEmail, "dev@example.com")
        XCTAssertEqual(reloaded.preferredEditor, .cursor)
        XCTAssertEqual(reloaded.preferredTerminal, .ghostty)
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
}
