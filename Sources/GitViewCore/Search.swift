import Foundation

/// Everything searchable that is already in memory.
public struct SearchCorpus: Sendable {
    public let commits: [Commit]
    public let filePaths: [String]
    public let units: [CodeUnit]
    public let contributors: [Contributor]
    public let branches: [String]
    public let tags: [String]

    public init(commits: [Commit] = [], filePaths: [String] = [], units: [CodeUnit] = [],
                contributors: [Contributor] = [], branches: [String] = [], tags: [String] = []) {
        self.commits = commits; self.filePaths = filePaths; self.units = units
        self.contributors = contributors; self.branches = branches; self.tags = tags
    }
}

public struct SearchResults: Sendable {
    public let query: String
    public let commits: [Commit]
    public let files: [String]
    public let units: [CodeUnit]
    public let people: [Contributor]
    public let branches: [String]
    public let tags: [String]
    /// True when the query named a field that matched nothing, so the UI can say which.
    public let scope: SearchQuery.Scope

    public var total: Int {
        commits.count + files.count + units.count + people.count + branches.count + tags.count
    }
    public var isEmpty: Bool { total == 0 }

    public static func empty(query: String = "") -> SearchResults {
        SearchResults(query: query, commits: [], files: [], units: [], people: [],
                      branches: [], tags: [], scope: .everything)
    }
}

/// A typed query. `author:weiss sockets` narrows to one person; a bare term searches
/// everything. Keeping the grammar this small means nobody has to learn it.
public struct SearchQuery: Sendable {
    public enum Scope: Sendable, Equatable {
        case everything, commits, files, units, people
    }

    public let text: String
    public let author: String?
    public let scope: Scope

    public var isEmpty: Bool { text.isEmpty && author == nil }

    public static func parse(_ raw: String) -> SearchQuery {
        var scope = Scope.everything
        var author: String?
        var terms: [String] = []

        for token in raw.split(separator: " ") {
            let piece = String(token)
            let lower = piece.lowercased()
            if lower.hasPrefix("author:") {
                let value = String(piece.dropFirst("author:".count))
                if !value.isEmpty { author = value }
            } else if lower.hasPrefix("in:") {
                switch String(lower.dropFirst("in:".count)) {
                case "commits": scope = .commits
                case "files": scope = .files
                case "functions", "units", "code": scope = .units
                case "people", "authors": scope = .people
                default: break
                }
            } else {
                terms.append(piece)
            }
        }
        return SearchQuery(text: terms.joined(separator: " "), author: author, scope: scope)
    }
}

public enum SearchEngine {
    /// Ranks a candidate against a lowercased needle. Higher is better; nil means no match.
    static func score(_ haystack: String, _ needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let lower = haystack.lowercased()
        guard let range = lower.range(of: needle) else { return nil }
        if lower == needle { return 100 }
        if range.lowerBound == lower.startIndex { return 60 }
        // Starting a word is worth more than landing in the middle of one.
        let before = lower[lower.index(before: range.lowerBound)]
        if !before.isLetter && !before.isNumber { return 35 }
        return 10
    }

    /// `author:weiss` should find Johannes Weiss; `author:ann` should *not* find him
    /// through the middle of "Johannes". So a name matches only at a word boundary, not
    /// anywhere inside a word.
    static func matchesAuthor(_ name: String, _ query: String) -> Bool {
        (score(name, query.lowercased()) ?? 0) >= 35
    }

    /// A hex-looking query is probably a commit id.
    ///
    /// Plenty of ordinary words are valid hex — "added", "decade", "facade" — so this only
    /// *adds* a sha-prefix match; the same query still searches text as usual.
    static func looksLikeSHA(_ text: String) -> Bool {
        text.count >= 4 && text.count <= 40 && text.allSatisfy(\.isHexDigit)
    }

    public static func search(_ raw: String, in corpus: SearchCorpus,
                              limitPerSection: Int = 25) -> SearchResults {
        let query = SearchQuery.parse(raw)
        guard !query.isEmpty else { return .empty(query: raw) }
        let needle = query.text.lowercased()
        let wants = { (scope: SearchQuery.Scope) in query.scope == .everything || query.scope == scope }

        // Commits: subject, author, or a sha prefix.
        var commits: [(Commit, Int)] = []
        if wants(.commits) {
            let shaQuery = looksLikeSHA(needle) ? needle : nil
            for commit in corpus.commits {
                if let author = query.author, !matchesAuthor(commit.author, author) { continue }
                var best: Int?
                if let shaQuery, commit.sha.lowercased().hasPrefix(shaQuery) { best = 120 }
                if needle.isEmpty {
                    best = max(best ?? 0, 5)   // author-only query: every commit by them
                } else {
                    if let s = score(commit.subject, needle) { best = max(best ?? 0, s) }
                    if let s = score(commit.author, needle) { best = max(best ?? 0, s / 2) }
                }
                if let best { commits.append((commit, best)) }
            }
        }

        func rank<T>(_ items: [(T, Int)], by tie: (T, T) -> Bool) -> [T] {
            items.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : tie($0.0, $1.0) }
                .prefix(limitPerSection).map(\.0)
        }

        // Everything else only matches on text, so an author-scoped query skips them.
        let textOnly = query.author == nil && !needle.isEmpty

        var files: [(String, Int)] = []
        if wants(.files) && textOnly {
            files = corpus.filePaths.compactMap { path in score(path, needle).map { (path, $0) } }
        }
        var units: [(CodeUnit, Int)] = []
        if wants(.units) && textOnly {
            units = corpus.units.compactMap { unit in score(unit.name, needle).map { (unit, $0) } }
        }
        var people: [(Contributor, Int)] = []
        if wants(.people) && textOnly {
            people = corpus.contributors.compactMap { person in score(person.name, needle).map { (person, $0) } }
        }
        var branches: [(String, Int)] = []
        var tags: [(String, Int)] = []
        if query.scope == .everything && textOnly {
            branches = corpus.branches.compactMap { name in score(name, needle).map { (name, $0) } }
            tags = corpus.tags.compactMap { name in score(name, needle).map { (name, $0) } }
        }

        return SearchResults(
            query: raw,
            // Commits are already newest first, so an equal score keeps that order.
            commits: rank(commits) { a, b in a.date > b.date },
            files: rank(files) { $0.count < $1.count },
            units: rank(units) { $0.complexity > $1.complexity },
            people: rank(people) { $0.commits > $1.commits },
            branches: rank(branches) { $0.count < $1.count },
            tags: rank(tags) { $0.count < $1.count },
            scope: query.scope)
    }
}
