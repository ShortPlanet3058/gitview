import XCTest
@testable import GitViewParse
import GitViewCore

final class UnitHistoryServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func unit(path: String = "A.swift") -> CodeUnit {
        CodeUnit(filePath: path, name: "f", kind: .function, lineRange: 1...3,
                 complexity: 3, nestingDepth: 0, lineCount: 3)
    }

    private func commit(_ sha: String, day: Int, path: String, oldPath: String? = nil) -> Commit {
        Commit(sha: sha, author: "dev", date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
               subject: "subject \(sha)",
               fileChanges: [FileChange(path: path, oldPath: oldPath, hunks: [Hunk(newStart: 2, newLineCount: 1)])])
    }

    func testHeadFirstThenOnePointPerRevisionWithMissingFlagged() async {
        let f = unit()
        let commits = [commit("bbb", day: 2, path: "A.swift"), commit("aaa", day: 1, path: "A.swift")]
        let churn = ChurnJoiner.join(units: [f], commits: commits)

        let service = UnitHistoryService { sha, _ in
            switch sha {
            case "bbb": return "func f() {\n  if a { }\n  if b { }\n}\n"   // cx 3
            case "aaa": return "func g() { }\n"                          // f did not exist yet
            default: XCTFail("unexpected sha \(sha)"); return ""
            }
        }
        let points = await service.complexityHistory(for: f, churn: churn, now: now)

        XCTAssertEqual(points.map(\.sha), ["HEAD", "bbb", "aaa"])
        XCTAssertTrue(points[0].isHead)
        XCTAssertEqual(points[0].complexity, 3)
        XCTAssertEqual(points[0].date, now)
        XCTAssertEqual(points[1].complexity, 3)
        XCTAssertEqual(points[1].subject, "subject bbb")
        XCTAssertNil(points[2].complexity, "unit absent at this revision must be nil, not 0")
    }

    func testFollowsRenameToHistoricalPath() async {
        let f = unit(path: "New.swift")
        let commits = [
            commit("ren", day: 2, path: "New.swift", oldPath: "Old.swift"),
            commit("old", day: 1, path: "Old.swift"),
        ]
        let churn = ChurnJoiner.join(units: [f], commits: commits)

        let requested = Requested()
        let service = UnitHistoryService { sha, path in
            requested.record(sha, path)
            return "func f() { }\n"
        }
        let points = await service.complexityHistory(for: f, churn: churn, now: now)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(requested.path(for: "ren"), "New.swift")
        XCTAssertEqual(requested.path(for: "old"), "Old.swift", "must ask for the file by its name at that revision")
        XCTAssertEqual(points[1].path, "New.swift")
        XCTAssertEqual(points[2].path, "Old.swift")
    }

    func testProviderFailureBecomesMissingPointNotCrash() async {
        let f = unit()
        let churn = ChurnJoiner.join(units: [f], commits: [commit("bad", day: 1, path: "A.swift")])
        struct Boom: Error {}
        let service = UnitHistoryService { _, _ in throw Boom() }
        let points = await service.complexityHistory(for: f, churn: churn, now: now)
        XCTAssertEqual(points.count, 2)
        XCTAssertNil(points[1].complexity)
    }

    func testOverloadsPickTheNearestByLine() async {
        // Two `f`s exist historically; the current unit starts at line 1, so the first wins.
        let f = unit()
        let churn = ChurnJoiner.join(units: [f], commits: [commit("ovl", day: 1, path: "A.swift")])
        let service = UnitHistoryService { _, _ in
            "func f() { if a { } }\n\n\n\n\n\n\n\nfunc f(_ x: Int) { if a { } if b { } if c { } }\n"
        }
        let points = await service.complexityHistory(for: f, churn: churn, now: now)
        XCTAssertEqual(points[1].complexity, 2)
    }

    func testBoundedConcurrencyProcessesEveryRevision() async {
        let f = unit()
        let commits = (0..<25).map { commit(String(format: "%040x", $0), day: $0 + 1, path: "A.swift") }
        let churn = ChurnJoiner.join(units: [f], commits: commits)
        let service = UnitHistoryService(maxConcurrency: 3) { _, _ in "func f() { }\n" }
        let points = await service.complexityHistory(for: f, churn: churn, now: now)
        XCTAssertEqual(points.count, 26)
        XCTAssertEqual(Set(points.dropFirst().map(\.sha)).count, 25, "every revision exactly once")
    }
}

/// Thread-safe recorder for what the provider was asked for.
private final class Requested: @unchecked Sendable {
    private var paths: [String: String] = [:]
    private let lock = NSLock()
    func record(_ sha: String, _ path: String) { lock.lock(); paths[sha] = path; lock.unlock() }
    func path(for sha: String) -> String? { lock.lock(); defer { lock.unlock() }; return paths[sha] }
}
