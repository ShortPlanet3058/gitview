import Foundation
import Observation
import GitViewCore
import GitViewGit

/// Immediate in-memory corpus search paired with debounced git grep / pickaxe searches.
@MainActor
@Observable
public final class SearchStore {
    public var globalSearch: String = "" {
        didSet { runSearch() }
    }

    public private(set) var searchResults: SearchResults?
    public private(set) var codeMatches: [CodeMatch] = []
    public private(set) var historyMatches: [Commit] = []
    public private(set) var deepSearchInFlight = false

    public var isSearching: Bool { !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    @ObservationIgnored private var deepSearchTask: Task<Void, Never>?
    @ObservationIgnored private var repositoryRoot: URL?
    @ObservationIgnored private var corpus: SearchCorpus?

    public init() {}

    public func updateContext(
        root: URL,
        commits: [Commit],
        filePaths: [String],
        units: [CodeUnit],
        contributors: [Contributor],
        branches: [String],
        tags: [String]
    ) {
        self.repositoryRoot = root
        self.corpus = SearchCorpus(
            commits: commits,
            filePaths: filePaths,
            units: units,
            contributors: contributors,
            branches: branches,
            tags: tags
        )
        if isSearching { runSearch() }
    }

    public func reset() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        repositoryRoot = nil
        corpus = nil
        globalSearch = ""
        searchResults = nil
        codeMatches = []
        historyMatches = []
        deepSearchInFlight = false
    }

    public func clear() {
        globalSearch = ""
    }

    private func runSearch() {
        deepSearchTask?.cancel()
        let query = globalSearch.trimmingCharacters(in: .whitespaces)
        guard let root = repositoryRoot, let corpus, !query.isEmpty else {
            searchResults = nil
            codeMatches = []
            historyMatches = []
            deepSearchInFlight = false
            return
        }

        searchResults = SearchEngine.search(query, in: corpus)

        let parsed = SearchQuery.parse(query)
        guard parsed.author == nil, parsed.text.count >= 3 else {
            codeMatches = []
            historyMatches = []
            deepSearchInFlight = false
            return
        }

        let term = parsed.text
        deepSearchInFlight = true
        deepSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let repository = GitRepository(url: root)
            let code = (try? repository.grep(term, limit: 60)) ?? []
            let history = (try? repository.commitsChanging(term, limit: 25)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.globalSearch.trimmingCharacters(in: .whitespaces) == query else { return }
                self.codeMatches = code
                self.historyMatches = history
                self.deepSearchInFlight = false
            }
        }
    }
}
