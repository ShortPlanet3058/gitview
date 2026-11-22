import XCTest
import SQLite3
@testable import GitViewCore

final class AnalysisCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AnalysisCache.clear(root: root)
        try? FileManager.default.removeItem(at: root)
    }

    private func payload(head: String = "abc123", commits: Int = 3, units: Int = 2) -> AnalysisCache.Payload {
        AnalysisCache.Payload(
            headSHA: head,
            commits: (0..<commits).map { index in
                Commit(sha: "sha\(index)", author: "Ann", email: "ann@example.com",
                       date: Date(timeIntervalSince1970: TimeInterval(index)),
                       subject: "commit \(index)",
                       fileChanges: [FileChange(path: "A.swift", oldPath: nil,
                                                hunks: [Hunk(oldStart: index + 1, oldLineCount: 1,
                                                             newStart: index + 1, newLineCount: 2)])])
            },
            units: (0..<units).map { index in
                CodeUnit(filePath: "A.swift", name: "f\(index)", kind: .function,
                         lineRange: (index + 1)...(index + 10), complexity: index + 2,
                         nestingDepth: 1, lineCount: 10, language: "swift")
            },
            generatedFiles: ["vendor/x.c"])
    }

    func testRoundTripPreservesEverything() throws {
        let original = payload()
        XCTAssertTrue(AnalysisCache.save(original, root: root))
        let loaded = try XCTUnwrap(AnalysisCache.load(root: root))

        XCTAssertEqual(loaded.headSHA, original.headSHA)
        XCTAssertEqual(loaded.commits, original.commits)
        XCTAssertEqual(loaded.units, original.units)
        XCTAssertEqual(loaded.generatedFiles, ["vendor/x.c"])
        // Unit identity must survive, or selection and churn keys break on reload.
        XCTAssertEqual(loaded.units.map(\.id), original.units.map(\.id))
        XCTAssertEqual(loaded.units.first?.language, "swift")
        XCTAssertEqual(loaded.commits.first?.subject, "commit 0")
        XCTAssertEqual(loaded.commits.first?.email, "ann@example.com")
    }

    func testMissingCacheIsNotAnError() {
        XCTAssertNil(AnalysisCache.load(root: root))
        XCTAssertTrue(AnalysisCache.loadFileUnits(root: root).isEmpty)
    }

    func testCorruptCacheIsIgnoredAndSelfHealsOnSave() throws {
        try FileManager.default.createDirectory(at: AnalysisCache.directory, withIntermediateDirectories: true)
        try Data("not a cache".utf8).write(to: AnalysisCache.url(for: root))
        XCTAssertNil(AnalysisCache.load(root: root))
        XCTAssertTrue(AnalysisCache.save(payload(), root: root))
        XCTAssertNotNil(AnalysisCache.load(root: root))
    }

    func testStaleFormatVersionIsRejected() throws {
        // Write a real SQLite DB whose format_version predates the current schema/version.
        XCTAssertTrue(AnalysisCache.save(payload(), root: root))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(AnalysisCache.url(for: root).path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value = '0' WHERE key = 'format_version';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertNil(AnalysisCache.load(root: root))
        XCTAssertTrue(AnalysisCache.loadFileUnits(root: root).isEmpty)
    }

    func testDifferentRepositoriesGetDifferentFiles() {
        let other = root.appendingPathComponent("other")
        XCTAssertNotEqual(AnalysisCache.url(for: root), AnalysisCache.url(for: other))
    }

    func testClearRemovesIt() {
        AnalysisCache.save(payload(), root: root)
        XCTAssertNotNil(AnalysisCache.load(root: root))
        AnalysisCache.clear(root: root)
        XCTAssertNil(AnalysisCache.load(root: root))
    }

    func testIncrementalFileUnitsReuseAndPruneDeletedFiles() throws {
        let unitA = CodeUnit(filePath: "A.swift", name: "a()", kind: .function,
                             lineRange: 1...10, complexity: 2, nestingDepth: 1, lineCount: 10, language: "swift")
        let unitB = CodeUnit(filePath: "Deleted.swift", name: "b()", kind: .function,
                             lineRange: 1...5, complexity: 1, nestingDepth: 0, lineCount: 5, language: "swift")
        let entryA = AnalysisCache.CachedFileUnits(
            path: "A.swift", bytes: 120, modified: 1_700_000_000, isGenerated: false, units: [unitA]
        )
        let entryB = AnalysisCache.CachedFileUnits(
            path: "Deleted.swift", bytes: 80, modified: 1_700_000_000, isGenerated: false, units: [unitB]
        )
        XCTAssertTrue(AnalysisCache.save(headSHA: "head1", commits: [], fileEntries: [entryA, entryB], root: root))

        let loaded1 = AnalysisCache.loadFileUnits(root: root)
        XCTAssertEqual(loaded1.count, 2)
        XCTAssertEqual(loaded1["A.swift"]?.bytes, 120)
        XCTAssertEqual(loaded1["A.swift"]?.units, [unitA])

        // Re-save without Deleted.swift: it must be pruned.
        XCTAssertTrue(AnalysisCache.save(headSHA: "head2", commits: [], fileEntries: [entryA], root: root))
        let loaded2 = AnalysisCache.loadFileUnits(root: root)
        XCTAssertEqual(Set(loaded2.keys), ["A.swift"])
    }

    func testCommitPoolRetainsCommitsAcrossBranchSwitch() throws {
        let c1 = Commit(sha: "sha_base", author: "Ann", date: Date(timeIntervalSince1970: 1),
                        subject: "base", fileChanges: [])
        let cA = Commit(sha: "sha_branch_a", author: "Ann", date: Date(timeIntervalSince1970: 2),
                        subject: "branch a", fileChanges: [])
        let cB = Commit(sha: "sha_branch_b", author: "Bob", date: Date(timeIntervalSince1970: 3),
                        subject: "branch b", fileChanges: [])

        XCTAssertTrue(AnalysisCache.save(headSHA: "sha_branch_a", commits: [cA, c1], fileEntries: [], root: root))
        XCTAssertTrue(AnalysisCache.save(headSHA: "sha_branch_b", commits: [cB, c1], fileEntries: [], root: root))

        // Branch A's head and commits are still retrievable after saving Branch B!
        let restoredA = try XCTUnwrap(AnalysisCache.load(root: root, matchingHead: "sha_branch_a"))
        XCTAssertEqual(restoredA.commits.map(\.sha), ["sha_branch_a", "sha_base"])

        // Arbitrary SHA ordering query works across the pooled commits, returns nil if any SHA is missing.
        XCTAssertEqual(
            AnalysisCache.loadCommits(orderedSHAs: ["sha_branch_b", "sha_branch_a", "sha_base"], root: root)?.map(\.sha),
            ["sha_branch_b", "sha_branch_a", "sha_base"]
        )
        XCTAssertNil(AnalysisCache.loadCommits(orderedSHAs: ["sha_base", "missing_sha"], root: root))
    }

    func testCompressionActuallyShrinksRepetitiveData() throws {
        // History and repeated units are highly compact on disk; if this ever stops holding,
        // the cache is wasting space.
        let large = payload(commits: 2000, units: 2000)
        XCTAssertTrue(AnalysisCache.save(large, root: root))
        let onDisk = AnalysisCache.sizeOnDisk(for: root)
        let raw = try JSONEncoder().encode(large).count
        XCTAssertLessThan(Int(onDisk), raw / 3, "sqlite \(onDisk) vs raw \(raw)")
    }
}
