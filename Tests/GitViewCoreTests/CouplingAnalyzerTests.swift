import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func unit(_ name: String, path: String, line: Int, kind: CodeUnit.Kind = .function) -> CodeUnit {
    CodeUnit(filePath: path, name: name, kind: kind, lineRange: line...(line + 5),
             complexity: 2, nestingDepth: 0, lineCount: 6)
}

/// A commit touching one line inside each given (path, line).
private func commit(_ sha: String, daysAgo: Double, touching: [(String, Int)]) -> Commit {
    let byPath = Dictionary(grouping: touching, by: \.0)
    return Commit(sha: sha, author: "dev", date: now.addingTimeInterval(-daysAgo * 86_400),
                  fileChanges: byPath.map { path, hits in
                      FileChange(path: path, oldPath: nil, hunks: hits.map { Hunk(newStart: $0.1 + 1, newLineCount: 1) })
                  })
}

final class CouplingAnalyzerTests: XCTestCase {
    let a = unit("a", path: "Sources/Core/A.swift", line: 10)
    let b = unit("b", path: "Sources/Core/A.swift", line: 100)
    let c = unit("c", path: "Sources/Net/C.swift", line: 10)

    private func analyze(_ commits: [Commit], units: [CodeUnit]? = nil,
                         analyzer: CouplingAnalyzer = CouplingAnalyzer(minSharedCommits: 1)) -> CouplingIndex {
        let all = units ?? [a, b, c]
        let churn = ChurnJoiner.join(units: all, commits: commits)
        return analyzer.analyze(units: all, churn: churn, now: now)
    }

    private func pair(_ index: CouplingIndex, _ x: CodeUnit, _ y: CodeUnit) -> CouplingPair? {
        index.pairs.first { Set([$0.a, $0.b]) == Set([x.id, y.id]) }
    }

    func testPairCountsCommitsTouchingBoth() {
        let commits = [
            commit("1", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("2", daysAgo: 2, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("3", daysAgo: 3, touching: [("Sources/Core/A.swift", 10)]),
        ]
        let index = analyze(commits)
        XCTAssertEqual(pair(index, a, c)?.sharedCommits, 2)
        XCTAssertNil(pair(index, a, b), "b was never touched")
        XCTAssertEqual(index.pairingCommits, 2)
    }

    func testPairIsSymmetricAndAppearsOnce() {
        let commits = [commit("1", daysAgo: 1, touching: [("Sources/Net/C.swift", 10), ("Sources/Core/A.swift", 10)])]
        let index = analyze(commits)
        XCTAssertEqual(index.pairs.count, 1)
        XCTAssertNotNil(pair(index, a, c))
        XCTAssertNotNil(pair(index, c, a))
    }

    func testStrengthIsShareOfTheLessChangedUnit() {
        let commits = [
            commit("1", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("2", daysAgo: 2, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("3", daysAgo: 3, touching: [("Sources/Core/A.swift", 10)]),
            commit("4", daysAgo: 4, touching: [("Sources/Core/A.swift", 10)]),
        ]
        XCTAssertEqual(pair(analyze(commits), a, c)?.strength, 1.0)
    }

    func testCrossFileAndCrossDirectoryFlags() {
        let commits = [commit("1", daysAgo: 1, touching: [
            ("Sources/Core/A.swift", 10), ("Sources/Core/A.swift", 100), ("Sources/Net/C.swift", 10),
        ])]
        let index = analyze(commits)
        let ab = pair(index, a, b)!
        XCTAssertFalse(ab.crossFile); XCTAssertFalse(ab.crossDirectory)
        let ac = pair(index, a, c)!
        XCTAssertTrue(ac.crossFile); XCTAssertTrue(ac.crossDirectory)
    }

    func testSameDirectoryDifferentFileIsCrossFileOnly() {
        let d = unit("d", path: "Sources/Core/D.swift", line: 10)
        let commits = [commit("1", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Core/D.swift", 10)])]
        let ad = pair(analyze(commits, units: [a, d]), a, d)!
        XCTAssertTrue(ad.crossFile); XCTAssertFalse(ad.crossDirectory)
    }

    func testSweepCommitsAreSkipped() {
        let many = (0..<6).map { unit("u\($0)", path: "S/F\($0).swift", line: 10) }
        let sweep = commit("sweep", daysAgo: 1, touching: many.map { ($0.filePath, 10) })
        let index = analyze([sweep], units: many, analyzer: CouplingAnalyzer(maxUnitsPerCommit: 5, minSharedCommits: 1))
        XCTAssertEqual(index.pairs.count, 0)
        XCTAssertEqual(index.skippedCommits, 1)
        XCTAssertEqual(index.sweepCommits.count, 1)
        XCTAssertEqual(index.pairingCommits, 0)
    }

    func testSharedCommitsLookupExcludesSweepsSoCountsAgree() {
        // A sweep touches a and c (and many others). It must not appear in the pair's
        // shared commits, or the detail would list more commits than were counted.
        let many = (0..<6).map { unit("u\($0)", path: "S/F\($0).swift", line: 10) }
        let all = [a, c] + many
        let commits = [
            commit("real", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("sweep", daysAgo: 2, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]
                                                    + many.map { ($0.filePath, 10) }),
        ]
        let churn = ChurnJoiner.join(units: all, commits: commits)
        let index = CouplingAnalyzer(maxUnitsPerCommit: 5, minSharedCommits: 1).analyze(units: all, churn: churn, now: now)
        let ac = pair(index, a, c)!
        XCTAssertEqual(ac.sharedCommits, 1)
        XCTAssertEqual(index.sharedCommits(of: ac, in: churn).map(\.sha), ["real"])
        XCTAssertEqual(index.sweepSharedCommits(of: ac, in: churn).map(\.sha), ["sweep"])
    }

    func testTypeDeclarationsDoNotPairWithTheirMethods() {
        let type = CodeUnit(filePath: "Sources/Core/A.swift", name: "T", kind: .class, lineRange: 1...200,
                            complexity: 1, nestingDepth: 0, lineCount: 200)
        let commits = [commit("1", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Core/A.swift", 100)])]
        let index = analyze(commits, units: [type, a, b])
        XCTAssertEqual(index.pairs.count, 1)
        XCTAssertNotNil(pair(index, a, b))
    }

    func testMinSharedCommitsFilters() {
        let commits = [commit("1", daysAgo: 1, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)])]
        XCTAssertEqual(analyze(commits, analyzer: CouplingAnalyzer(minSharedCommits: 2)).pairs.count, 0)
        XCTAssertEqual(analyze(commits, analyzer: CouplingAnalyzer(minSharedCommits: 1)).pairs.count, 1)
    }

    func testWeightDecaysAndLastSharedIsNewest() {
        let commits = [
            commit("new", daysAgo: 0, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("old", daysAgo: 365, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
        ]
        let p = pair(analyze(commits), a, c)!
        XCTAssertEqual(p.sharedCommits, 2)
        XCTAssertEqual(p.weight, 1.5, accuracy: 1e-9, "1.0 for today + 0.5 for one half-life ago")
        XCTAssertEqual(p.lastShared, now)
    }

    func testSharedCommitsLookupReturnsNewestFirst() {
        let commits = [
            commit("new", daysAgo: 0, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
            commit("mid", daysAgo: 5, touching: [("Sources/Core/A.swift", 10)]),
            commit("old", daysAgo: 9, touching: [("Sources/Core/A.swift", 10), ("Sources/Net/C.swift", 10)]),
        ]
        let churn = ChurnJoiner.join(units: [a, b, c], commits: commits)
        let index = CouplingAnalyzer(minSharedCommits: 1).analyze(units: [a, b, c], churn: churn, now: now)
        XCTAssertEqual(index.sharedCommits(of: pair(index, a, c)!, in: churn).map(\.sha), ["new", "old"])
    }

    func testDirectoryHelper() {
        XCTAssertEqual(CouplingAnalyzer.directory(of: "Sources/Core/A.swift"), "Sources/Core")
        XCTAssertEqual(CouplingAnalyzer.directory(of: "A.swift"), "")
    }
}
