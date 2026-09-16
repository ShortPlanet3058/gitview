import Foundation

/// Turns a range of commits into something you can paste into a release.
///
/// Two grouping strategies, in order. Conventional Commits (`fix:`, `feat:`) when a project
/// uses them; otherwise the leading verb, because "Add …", "Fix …", "Bump …" is how most
/// repositories that have never heard of the convention actually write their subjects.
/// swift-nio is a mixture of both, which is the normal case.
public enum ReleaseNotes {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String { sha }
        public let subject: String
        public let sha: String
        public let author: String
        public let date: Date
    }

    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let entries: [Entry]
    }

    /// Conventional Commits types mapped to headings, in the order they should appear.
    static let conventional: [(prefix: String, title: String)] = [
        ("feat", "Features"), ("fix", "Fixes"), ("perf", "Performance"),
        ("refactor", "Refactoring"), ("docs", "Documentation"), ("test", "Tests"),
        ("build", "Build"), ("ci", "CI"), ("style", "Style"), ("chore", "Chores"),
        ("revert", "Reverts"),
    ]

    /// Leading verbs, for the majority of repositories that do not use a convention.
    static let verbs: [(verb: String, title: String)] = [
        ("add", "Added"), ("introduce", "Added"), ("implement", "Added"),
        ("fix", "Fixed"), ("correct", "Fixed"), ("resolve", "Fixed"),
        ("remove", "Removed"), ("delete", "Removed"), ("drop", "Removed"),
        ("update", "Updated"), ("bump", "Updated"), ("upgrade", "Updated"),
        ("improve", "Improved"), ("optimise", "Improved"), ("optimize", "Improved"),
        ("speed", "Improved"), ("make", "Changed"), ("change", "Changed"), ("rename", "Changed"),
    ]

    /// The heading a subject belongs under, or nil for the catch-all.
    static func heading(for subject: String) -> String? {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        // `type:` or `type(scope):`
        if let colon = trimmed.firstIndex(of: ":") {
            var type = String(trimmed[trimmed.startIndex..<colon]).lowercased()
            if let paren = type.firstIndex(of: "(") { type = String(type[type.startIndex..<paren]) }
            type = type.trimmingCharacters(in: CharacterSet(charactersIn: "!"))
            if let match = conventional.first(where: { $0.prefix == type }) { return match.title }
        }
        let firstWord = trimmed.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        let stem = firstWord.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if let match = verbs.first(where: { stem == $0.verb || stem == $0.verb + "s" || stem == $0.verb + "ed" }) {
            return match.title
        }
        return nil
    }

    /// Merge commits carry no change of their own and read as noise in notes.
    static func isNoise(_ commit: Commit) -> Bool {
        let subject = commit.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty || subject.hasPrefix("Merge ") || subject.hasPrefix("Merge\n")
    }

    public static func sections(for commits: [Commit]) -> [Section] {
        var byTitle: [String: [Entry]] = [:]
        for commit in commits where !isNoise(commit) {
            let entry = Entry(subject: commit.subject, sha: commit.sha,
                              author: commit.author, date: commit.date)
            byTitle[heading(for: commit.subject) ?? "Other changes", default: []].append(entry)
        }
        // A stable, meaningful order: known headings in their declared order, then the rest.
        let order = conventional.map(\.title) + verbs.map(\.title) + ["Other changes"]
        var seen = Set<String>()
        let ranked = order.filter { seen.insert($0).inserted }
        return ranked.compactMap { title in
            guard let entries = byTitle[title], !entries.isEmpty else { return nil }
            return Section(title: title, entries: entries)
        }
    }

    /// Markdown ready to paste into a release or a changelog.
    public static func markdown(title: String, commits: [Commit], now: Date = Date()) -> String {
        var lines = ["## \(title)", ""]
        let counted = commits.filter { !isNoise($0) }
        guard !counted.isEmpty else {
            lines.append("_No changes._")
            return lines.joined(separator: "\n")
        }

        for section in sections(for: commits) {
            lines.append("### \(section.title)")
            for entry in section.entries {
                lines.append("- \(entry.subject) (`\(entry.sha.prefix(7))`)")
            }
            lines.append("")
        }

        let authors = Set(counted.map(\.author)).sorted()
        lines.append("### Contributors")
        lines.append(authors.map { "@\($0)" }.joined(separator: ", "))
        lines.append("")
        lines.append("_\(counted.count) \(counted.count == 1 ? "commit" : "commits") "
                     + "by \(authors.count) \(authors.count == 1 ? "person" : "people")._")
        return lines.joined(separator: "\n")
    }
}
