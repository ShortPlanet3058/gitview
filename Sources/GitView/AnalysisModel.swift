import Foundation
import SwiftUI
import GitViewCore

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
    @Published private(set) var churn: ChurnIndex?
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

    func open(url: URL) {
        state = .loading("Reading history…")
        rows = []
        churn = nil

        Task {
            do {
                let analysis = try await AnalysisService.load(root: url)
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
        churn = index
    }
}
