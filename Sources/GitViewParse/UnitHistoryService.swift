import Foundation
import GitViewCore

/// A unit's complexity at one revision.
public struct UnitComplexityPoint: Identifiable, Hashable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let date: Date
    public let author: String
    public let subject: String
    /// Path of the file at this revision (differs from today's after renames).
    public let path: String
    /// Nil when no unit with this name and kind existed in the file at this revision.
    ///
    /// That is usually the step-3 imprecision made visible: the hunk that attributed this
    /// commit had drifted onto different code, so the commit never touched this unit at all.
    public let complexity: Int?
    public let lineCount: Int?

    public var isHead: Bool { sha == UnitHistoryService.headSHA }
}

/// Re-parses a unit's file at every revision that touched it to recover complexity over time.
///
/// File contents come through an injected provider rather than a git dependency, so this
/// module stays free of process handling and can be tested with in-memory sources.
public struct UnitHistoryService: Sendable {
    public typealias ContentProvider = @Sendable (_ sha: String, _ path: String) throws -> String

    public static let headSHA = "HEAD"

    private let provider: ContentProvider
    private let maxConcurrency: Int

    /// - Parameter maxConcurrency: how many revisions to fetch and parse at once. Each fetch
    ///   is typically a blocking `git show`, so this is kept small to avoid tying up the
    ///   cooperative thread pool.
    public init(maxConcurrency: Int = 4, provider: @escaping ContentProvider) {
        self.provider = provider
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Points newest first, ending with the working tree as `HEAD` at `now`.
    public func complexityHistory(
        for unit: CodeUnit,
        churn: ChurnIndex,
        now: Date = Date()
    ) async -> [UnitComplexityPoint] {
        // The unit's own language, not Swift: a repository can mix several.
        let ext = (unit.filePath as NSString).pathExtension.lowercased()
        guard let support = LanguageRegistry.shared.language(forExtension: ext),
              let extractor = try? UnitExtractor(support: support) else { return [] }

        let jobs: [(commit: Commit, path: String)] = churn.commits(for: unit).compactMap { commit in
            churn.historicalPath(of: unit, in: commit).map { (commit, $0) }
        }

        var results = [UnitComplexityPoint?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, UnitComplexityPoint).self) { group in
            var next = 0
            func enqueue(_ group: inout TaskGroup<(Int, UnitComplexityPoint)>) {
                guard next < jobs.count else { return }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    (index, self.point(for: unit, at: job.commit, path: job.path, extractor: extractor))
                }
            }
            for _ in 0..<maxConcurrency { enqueue(&group) }
            while let (index, point) = await group.next() {
                results[index] = point
                enqueue(&group)
            }
        }

        let head = UnitComplexityPoint(
            sha: Self.headSHA, date: now, author: "", subject: "Working tree",
            path: unit.filePath, complexity: unit.complexity, lineCount: unit.lineCount
        )
        return [head] + results.compactMap { $0 }
    }

    private func point(
        for unit: CodeUnit, at commit: Commit, path: String, extractor: UnitExtractor
    ) -> UnitComplexityPoint {
        var match: CodeUnit?
        if let source = try? provider(commit.sha, path),
           let units = try? extractor.extract(source: source, filePath: path) {
            // Overloads share a name; take the one nearest the unit's current position,
            // which is the best guess without tracking the body across revisions.
            let candidates: [CodeUnit] = units.filter { $0.name == unit.name && $0.kind == unit.kind }
            let target: Int = unit.lineRange.lowerBound
            match = candidates.min { a, b in
                let da: Int = abs(a.lineRange.lowerBound - target)
                let db: Int = abs(b.lineRange.lowerBound - target)
                return da < db
            }
        }
        return UnitComplexityPoint(
            sha: commit.sha, date: commit.date, author: commit.author, subject: commit.subject,
            path: path, complexity: match?.complexity, lineCount: match?.lineCount
        )
    }
}
