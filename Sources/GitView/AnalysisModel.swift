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

    // Model parameters. Changing any of these re-derives the ranking without touching git.
    @Published var halfLifeDays: Double = 365 { didSet { rebuild() } }
    @Published var excludeTests = true { didSet { rebuild() } }
    @Published var kindFilter: KindFilter = .all { didSet { rebuild() } }
    @Published var minimumCommits = 1 { didSet { rebuild() } }
    @Published var searchText = "" { didSet { rebuild() } }

    @Published private(set) var rows: [RiskRow] = []
    @Published private(set) var rowsByID: [UUID: RiskRow] = [:]
    @Published private(set) var churn: ChurnIndex?
    private(set) var unitsByID: [UUID: CodeUnit] = [:]

    // Selection and the per-unit detail data derived on demand.
    @Published var selectedUnitID: UUID?
    @Published private(set) var histories: [UUID: [UnitComplexityPoint]] = [:]
    @Published private(set) var loadingHistories: Set<UUID> = []
    /// Name fragment from `--select`, applied once the first ranking is built.
    var pendingSelection: String?
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

    func open(url: URL) {
        state = .loading("Reading history…")
        rows = []
        rowsByID = [:]
        churn = nil
        selectedUnitID = nil
        histories = [:]
        loadingHistories = []

        Task {
            do {
                let analysis = try await AnalysisService.load(root: url)
                self.unitsByID = Dictionary(uniqueKeysWithValues: analysis.allUnits.map { ($0.id, $0) })
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
        let model = RiskModel(halfLife: halfLifeDays * 86_400)
        var ranked = model.rank(units: units, churn: index, now: Date())
        ranked = ranked.filter { $0.commitCount >= minimumCommits }

        totalRanked = ranked.count
        var built = ranked.map(RiskRow.init)

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
