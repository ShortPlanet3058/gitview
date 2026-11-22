import XCTest
@testable import GitViewGit

final class GitProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitViewProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try GitProcess.capture(arguments: ["init", "-q"], in: root)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: GitProcess.gitExecutablePreferenceKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testCaptureWritesStdinAndReadsOutput() throws {
        let payload = "hello from stdin\nline two\n"
        let sha = try GitProcess.capture(
            arguments: ["hash-object", "-w", "--stdin"],
            stdin: Data(payload.utf8),
            in: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let roundTripped = try GitProcess.capture(arguments: ["cat-file", "-p", sha], in: root)
        XCTAssertEqual(roundTripped, payload)
    }

    func testGitPathIgnoresInvalidUserOverrideAndResolvesValidGit() {
        UserDefaults.standard.set("/nonexistent/git-binary", forKey: GitProcess.gitExecutablePreferenceKey)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: GitProcess.gitPath))
        XCTAssertNotEqual(GitProcess.gitPath, "/nonexistent/git-binary")

        let current = GitProcess.gitPath
        UserDefaults.standard.set(current, forKey: GitProcess.gitExecutablePreferenceKey)
        XCTAssertEqual(GitProcess.gitPath, current)
    }

    func testAsyncCancellationTerminatesRunningGitCommandPromptly() async throws {
        let dir = root!
        let task = Task {
            try await GitProcess.captureAsync(
                arguments: ["-c", "alias.slow=!sleep 10", "slow"],
                in: dir
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelStarted = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 2.0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
