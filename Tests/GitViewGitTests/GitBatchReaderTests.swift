import XCTest
@testable import GitViewGit

final class GitBatchReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitViewBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        try GitProcess.capture(arguments: args, in: root)
    }

    func testReadsBlobsAcrossCommitsAndHandlesMissingPaths() throws {
        let fileURL = root.appendingPathComponent("hello.swift")
        try "let greeting = \"café v1\"\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try git(["add", "hello.swift"])
        try git(["commit", "-q", "-m", "v1"])
        let sha1 = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let spacedURL = root.appendingPathComponent("with space.txt")
        try "no trailing newline".write(to: spacedURL, atomically: true, encoding: .utf8)
        try "let greeting = \"café v2\"\nline 2\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "v2"])
        let sha2 = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let reader = try GitBatchReader(directory: root)
        defer { reader.close() }

        XCTAssertEqual(try reader.blob(sha: sha1, path: "hello.swift"), "let greeting = \"café v1\"\n")
        XCTAssertNil(try reader.blob(sha: sha1, path: "with space.txt"))
        XCTAssertEqual(try reader.blob(sha: sha2, path: "with space.txt"), "no trailing newline")
        XCTAssertEqual(try reader.blob(sha: sha2, path: "hello.swift"), "let greeting = \"café v2\"\nline 2\n")
        XCTAssertNil(try reader.blob(sha: sha2, path: "missing.swift"))
        // Directories resolve to trees, not blobs.
        XCTAssertNil(try reader.blob(sha: sha2, path: ""))
    }

    func testConcurrentReadsRemainAligned() async throws {
        var shas: [(sha: String, expected: String)] = []
        let fileURL = root.appendingPathComponent("Counter.swift")
        for i in 1...12 {
            let content = "func f\(i)() -> Int { return \(i * 17) }\n"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try git(["add", "Counter.swift"])
            try git(["commit", "-q", "-m", "rev \(i)"])
            let sha = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            shas.append((sha, content))
        }

        let reader = try GitBatchReader(directory: root)
        defer { reader.close() }

        let mismatched = try await withThrowingTaskGroup(of: Bool.self) { group in
            for entry in shas {
                group.addTask {
                    let actual = try reader.blob(sha: entry.sha, path: "Counter.swift")
                    return actual != entry.expected
                }
            }
            var anyMismatch = false
            for try await flag in group where flag { anyMismatch = true }
            return anyMismatch
        }
        XCTAssertFalse(mismatched)
    }
}
