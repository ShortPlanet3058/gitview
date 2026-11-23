import Foundation
import Observation
import GitViewCore
import GitViewGit

/// Active screen, selections, and branch/tag comparison state for one workspace window.
@MainActor
@Observable
public final class NavigationStore {
    public enum Screen: String, Hashable, CaseIterable, Sendable {
        case overview, changes, commits, branches, releases, contributors, files, activity, hotspots, coupling, statistics

        public var title: String {
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

        public func displayTitle(advanced: Bool) -> String {
            switch self {
            case .commits: return advanced ? "Commits" : "History"
            case .contributors: return advanced ? "Contributors" : "People"
            default: return title
            }
        }

        public var symbol: String {
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

    public static let standardScreens: [Screen] = [
        .overview, .changes, .commits, .branches, .files, .contributors
    ]

    public static let workspaceScreens: [Screen] = [.overview, .changes, .files]
    public static let historyScreens: [Screen] = [.commits, .branches, .releases, .contributors, .activity]
    public static let analysisOnlyScreens: [Screen] = [.hotspots, .coupling, .statistics]

    public static let repositoryScreens: [Screen] = standardScreens

    public func analysisScreens(advanced: Bool) -> [Screen] {
        advanced ? Self.analysisOnlyScreens : []
    }

    public func visibleScreens(advanced: Bool) -> [Screen] {
        advanced
            ? (Self.workspaceScreens + Self.historyScreens + Self.analysisOnlyScreens)
            : Self.standardScreens
    }

    public func ensureVisibleScreen(advanced: Bool) {
        let visible = visibleScreens(advanced: advanced)
        if !visible.contains(screen) {
            screen = .overview
            clearDetailSelections()
        }
    }

    public var screen: Screen = .overview
    public var selectedUnitID: UUID?
    public var selectedCommitSHA: String?
    public var selectedPairID: String?
    public var selectedAuthor: String?
    public var selectedFilePath: String?

    /// Pending selections supplied via CLI launch flags and applied once data loads.
    public var pendingSelection: String?
    public var pendingPairSelection: String?
    public var pendingCommitSelection: String?
    public var pendingFileSelection: String?
    public var pendingFileLine: Int?
    public var pendingAuthorSelection: String?
    public var pendingCompare: String?
    public var pendingSearch: String?
    public var pendingDiff: String?
    public var pendingThenShow: String?
    public var pendingFileHistory: String?

    public var focusSearchRequest: Int = 0
    public var focusLocalFindRequest: Int = 0
    public var focusGoToLineRequest: Int = 0
    public var isCommandPalettePresented: Bool = false
    public var isShortcutsSheetPresented: Bool = false
    public var isCloneSheetPresented: Bool = false
    public var isInitSheetPresented: Bool = false
    public var isReflogSheetPresented: Bool = false
    public var isManageRepoSheetPresented: Bool = false
    public var isCommandLogSheetPresented: Bool = false

    // Comparing two points: releases or arbitrary refs.
    public var compareFrom: String = ""
    public var compareTo: String = "HEAD"
    var comparison: ComparisonResult?
    public private(set) var comparisonInFlight = false

    public init() {}

    public var hasDetailSelection: Bool {
        selectedUnitID != nil || selectedCommitSHA != nil || selectedPairID != nil || selectedAuthor != nil
    }

    public func clearDetailSelections() {
        selectedUnitID = nil
        selectedCommitSHA = nil
        selectedPairID = nil
        selectedAuthor = nil
    }

    public func clearForOpen() {
        clearDetailSelections()
        selectedFilePath = nil
        isCommandPalettePresented = false
        isShortcutsSheetPresented = false
        comparison = nil
        comparisonInFlight = false
    }

    public func runComparison(in root: URL) {
        guard !compareFrom.isEmpty, !comparisonInFlight else { return }
        let from = compareFrom
        let to = compareTo
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

    public static func stepSelection<ID: Equatable>(in ids: [ID], current: ID?, delta: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        let target = min(max(0, index + delta), ids.count - 1)
        return ids[target]
    }
}
