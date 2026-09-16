import XCTest
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
                Commit(sha: "sha\(index)", author: "Ann", date: Date(timeIntervalSince1970: TimeInterval(index)),
                       subject: "commit \(index)",
                       fileChanges: [FileChange(path: "A.swift", oldPath: nil,
                                                hunks: [Hunk(newStart: index + 1, newLineCount: 2)])])
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
    }

    func testMissingCacheIsNotAnError() {
        XCTAssertNil(AnalysisCache.load(root: root))
    }

    func testCorruptCacheIsIgnoredRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: AnalysisCache.directory, withIntermediateDirectories: true)
        try Data("not a cache".utf8).write(to: AnalysisCache.url(for: root))
        XCTAssertNil(AnalysisCache.load(root: root))
    }

    func testStaleFormatVersionIsRejected() throws {
        // A cache written by an older build must never resurrect numbers computed under
        // different rules.
        let json = """
        {"formatVersion": 0, "headSHA": "x", "createdAt": 0, "commits": [], "units": [], "generatedFiles": []}
        """
        try FileManager.default.createDirectory(at: AnalysisCache.directory, withIntermediateDirectories: true)
        let compressed = try (Data(json.utf8) as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: AnalysisCache.url(for: root))
        XCTAssertNil(AnalysisCache.load(root: root))
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

    func testCompressionActuallyShrinksRepetitiveData() throws {
        // History is highly repetitive; if this ever stops holding, the cache is wasting disk.
        let large = payload(commits: 2000, units: 2000)
        XCTAssertTrue(AnalysisCache.save(large, root: root))
        let onDisk = try Data(contentsOf: AnalysisCache.url(for: root)).count
        let raw = try JSONEncoder().encode(large).count
        XCTAssertLessThan(onDisk, raw / 3, "compressed \(onDisk) vs raw \(raw)")
    }
}
