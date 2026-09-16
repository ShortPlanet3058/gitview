import XCTest
@testable import GitViewCore

final class RecentRepositoriesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "gitview-recent-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStartsEmpty() {
        XCTAssertEqual(RecentRepositories.all(defaults: defaults), [])
        XCTAssertNil(RecentRepositories.last(defaults: defaults))
    }

    func testMostRecentComesFirst() throws {
        let a = try makeDirectory("a"), b = try makeDirectory("b")
        RecentRepositories.remember(a, defaults: defaults)
        RecentRepositories.remember(b, defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults).map(\.lastPathComponent), ["b", "a"])
        XCTAssertEqual(RecentRepositories.last(defaults: defaults)?.lastPathComponent, "b")
    }

    /// Reopening something already in the list moves it up rather than adding it twice.
    func testRememberingAgainPromotesRatherThanDuplicates() throws {
        let a = try makeDirectory("a"), b = try makeDirectory("b")
        RecentRepositories.remember(a, defaults: defaults)
        RecentRepositories.remember(b, defaults: defaults)
        RecentRepositories.remember(a, defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults).map(\.lastPathComponent), ["a", "b"])
    }

    func testKeepsOnlyTheMostRecentTen() throws {
        for index in 0..<15 {
            RecentRepositories.remember(try makeDirectory("r\(index)"), defaults: defaults)
        }
        let all = RecentRepositories.all(defaults: defaults)
        XCTAssertEqual(all.count, RecentRepositories.limit)
        XCTAssertEqual(all.first?.lastPathComponent, "r14")
        XCTAssertEqual(all.last?.lastPathComponent, "r5")
    }

    /// A repository that has since been deleted or moved must not be offered: the menu
    /// entry would open, fail, and leave the person looking at an error for something they
    /// did not do wrong.
    func testForgetsDirectoriesThatNoLongerExist() throws {
        let kept = try makeDirectory("kept"), removed = try makeDirectory("removed")
        RecentRepositories.remember(kept, defaults: defaults)
        RecentRepositories.remember(removed, defaults: defaults)
        try FileManager.default.removeItem(at: removed)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults).map(\.lastPathComponent), ["kept"])
    }

    /// A file is not a repository; only directories survive the read.
    func testIgnoresPathsThatAreFiles() throws {
        let file = root.appendingPathComponent("notadirectory.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        RecentRepositories.remember(file, defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults), [])
    }

    /// /tmp is a symlink to /private/tmp on macOS, so the same folder reached two ways has
    /// to land on one entry rather than filling the menu with apparent duplicates.
    func testTheSameDirectoryByTwoPathsIsOneEntry() throws {
        let direct = try makeDirectory("same")
        let viaSymlink = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(direct.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: ""))
        RecentRepositories.remember(direct, defaults: defaults)
        RecentRepositories.remember(viaSymlink, defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults).count, 1)
    }

    func testForgetRemovesOne() throws {
        let a = try makeDirectory("a"), b = try makeDirectory("b")
        RecentRepositories.remember(a, defaults: defaults)
        RecentRepositories.remember(b, defaults: defaults)
        RecentRepositories.forget(a, defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults).map(\.lastPathComponent), ["b"])
    }

    func testClearRemovesEverything() throws {
        RecentRepositories.remember(try makeDirectory("a"), defaults: defaults)
        RecentRepositories.clear(defaults: defaults)
        XCTAssertEqual(RecentRepositories.all(defaults: defaults), [])
    }
}
