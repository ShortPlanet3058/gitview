import XCTest
@testable import GitViewParse

final class SourceScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanWithTrackedPathsIgnoresUntrackedBuildAndVenvFiles() async throws {
        let src = root.appendingPathComponent("src")
        let venv = root.appendingPathComponent("venv/lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try "def tracked():\n    return 1\n".write(
            to: src.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        try "def untracked():\n    return 2\n".write(
            to: venv.appendingPathComponent("pkg.py"), atomically: true, encoding: .utf8)

        let report = try await SourceScanner().scan(root: root, trackedPaths: ["src/app.py", "missing.py"])
        XCTAssertEqual(report.filesParsed, 1)
        XCTAssertEqual(report.units.map(\.name), ["tracked"])
        XCTAssertEqual(report.units.map(\.filePath), ["src/app.py"])
    }

    func testDirectoryWalkSkipsVenvAndTargetDirectories() async throws {
        let src = root.appendingPathComponent("src")
        let target = root.appendingPathComponent("target/debug")
        let venv = root.appendingPathComponent("venv")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)

        try "fn main() {}\n".write(to: src.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        try "fn generated() {}\n".write(to: target.appendingPathComponent("gen.rs"), atomically: true, encoding: .utf8)
        try "def site(): pass\n".write(to: venv.appendingPathComponent("site.py"), atomically: true, encoding: .utf8)

        let report = try await SourceScanner().scan(root: root)
        XCTAssertEqual(report.filesParsed, 1)
        XCTAssertEqual(report.units.map(\.filePath), ["src/main.rs"])
    }
}
